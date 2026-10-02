import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/storage/signed_urls.dart';
import '../../babies/application/baby_lifecycle_providers.dart';
import '../../babies/domain/baby.dart';
import '../../family/data/family_repository.dart';
import '../../family/domain/family_member.dart';
import '../../letters/data/letter_repository.dart';
import '../../media/data/image_processing.dart';
import '../../media/data/media_repository.dart';
import '../../memories/data/memory_repository.dart';
import '../../milestones/data/milestone_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import '../domain/book_render.dart';
import '../domain/book_snapshot.dart';
import '../pdf/book_pdf_builder.dart';

final bookGeneratorProvider = Provider<BookGenerator>((ref) => BookGenerator(ref));

class BookProgress {
  const BookProgress(this.stage, this.done, this.total);

  final String stage;
  final int done;
  final int total;

  double? get fraction => total == 0 ? null : done / total;
}

/// Orchestrates book generation:
///   load content → resolve pages → download & downscale photos (disk
///   cache, one at a time to keep memory low) → build the PDF on a
///   background isolate → save locally.
class BookGenerator {
  BookGenerator(this._ref);

  final Ref _ref;

  /// Loads ALL content of the baby; the composer decides what belongs to
  /// the first year, up to the server's effective close date (P-1).
  Future<BookSource> loadSource(Baby baby) async {
    final memoriesRepo = _ref.read(memoryRepositoryProvider);
    final lifecycle = await _ref.read(babyLifecycleProvider(baby.id).future);
    final results = await Future.wait([
      memoriesRepo.forBaby(baby.id),
      _ref.read(mediaRepositoryProvider).allForBaby(baby.id),
      _ref.read(milestoneRepositoryProvider).forBaby(baby.id),
      _ref.read(milestoneRepositoryProvider).types(baby.id),
      _ref.read(letterRepositoryProvider).forBaby(baby.id),
      memoriesRepo.favoriteIds(baby.id),
    ]);
    final types = results[3] as List;
    return BookSource(
      baby: baby,
      memories: (results[0] as List).cast(),
      media: (results[1] as List).cast(),
      milestones: (results[2] as List).cast(),
      milestoneTypes: {for (final t in types) t.id as String: t},
      letters: (results[4] as List).cast(),
      favoriteIds: results[5] as Set<String>,
      closeDate: lifecycle.effectiveCloseDate,
    );
  }

  /// With [strict] (official PDFs) a photo that cannot be prepared fails the
  /// render instead of leaving an empty frame in a paid product.
  Future<Map<String, Uint8List>> prepareImages(
    BookRenderData data,
    BookQuality quality, {
    void Function(BookProgress)? onProgress,
    bool strict = false,
  }) async {
    final photos = {for (final p in data.allPhotos) p.mediaId: p}.values.toList();
    final signer = _ref.read(signedUrlCacheProvider);
    await signer.prefetch(Buckets.babyMedia, photos.map((p) => p.path));
    final cacheDir = await Directory('${(await getTemporaryDirectory()).path}/book_images/${quality.key}')
        .create(recursive: true);
    final result = <String, Uint8List>{};
    final client = http.Client();
    try {
      for (var i = 0; i < photos.length; i++) {
        onProgress?.call(BookProgress('Fotoğraflar hazırlanıyor', i, photos.length));
        final p = photos[i];
        final cached = File('${cacheDir.path}/${p.mediaId}.jpg');
        if (await cached.exists()) {
          result[p.mediaId] = await cached.readAsBytes();
          continue;
        }
        try {
          final url = await signer.url(Buckets.babyMedia, p.path);
          final res = await client.get(Uri.parse(url));
          if (res.statusCode != 200) {
            if (strict) throw BookImageException(p.mediaId);
            continue;
          }
          final jpeg = await ImageProcessing.compressBytes(res.bodyBytes, quality.maxImagePx, quality.jpegQuality);
          await cached.writeAsBytes(jpeg, flush: true);
          result[p.mediaId] = jpeg;
        } catch (_) {
          // A missing photo must not break a preview: it renders as an empty
          // frame and the user can remove it in the editor.
        }
        if (strict && !result.containsKey(p.mediaId)) throw BookImageException(p.mediaId);
      }
    } finally {
      client.close();
    }
    onProgress?.call(BookProgress('Fotoğraflar hazırlanıyor', photos.length, photos.length));
    return result;
  }

  Future<BookFonts> _fonts() async {
    Future<Uint8List> f(String n) async => (await rootBundle.load('assets/fonts/$n')).buffer.asUint8List();
    return BookFonts(
      sansRegular: await f('Nunito-Regular.ttf'),
      sansBold: await f('Nunito-Bold.ttf'),
      serifRegular: await f('Lora-Regular.ttf'),
      serifSemiBold: await f('Lora-SemiBold.ttf'),
      serifItalic: await f('Lora-Italic.ttf'),
    );
  }

  /// Builds the PDF bytes on a background isolate.
  Future<(Uint8List, int)> build(
    BookProject project,
    BookSource source,
    List<FamilyMember> members,
    BookQuality quality, {
    void Function(BookProgress)? onProgress,
    bool strictImages = false,
  }) async {
    final data = const BookRenderResolver().resolve(project: project, source: source, members: members);
    final images = await prepareImages(data, quality, onProgress: onProgress, strict: strictImages);
    onProgress?.call(const BookProgress('Sayfalar dizgileniyor', 0, 0));
    final job = BookBuildJob(data: data, fonts: await _fonts(), images: images);
    final result = await Isolate.run(() => buildBookPdf(job));
    return (result.bytes, result.pageCount);
  }

  /// Draft preview from the live (read-only) archive; never an official
  /// artifact.
  Future<(File, int)> generate(
    BookProject project,
    Baby baby,
    BookQuality quality, {
    void Function(BookProgress)? onProgress,
  }) async {
    onProgress?.call(const BookProgress('İçerikler toplanıyor', 0, 0));
    final source = await loadSource(baby);
    final members = await _ref.read(familyRepositoryProvider).members(project.babyId);
    final (bytes, pages) = await build(project, source, members, quality, onProgress: onProgress);
    return (await saveLocally(_fileName(baby, quality), bytes), pages);
  }

  /// Official render: the sealed snapshot and the frozen manifest only, print
  /// quality, every photo required.
  Future<(Uint8List, int)> renderOfficial(BookRenderInputs inputs, {void Function(BookProgress)? onProgress}) => build(
    inputs.project,
    inputs.source,
    inputs.members,
    BookQuality.print,
    onProgress: onProgress,
    strictImages: true,
  );

  String _fileName(Baby baby, BookQuality q) {
    final safe = baby.firstName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9çğıöşü]+'), '-');
    return '$safe-ilk-yilim-${q.key}.pdf';
  }

  /// Local copy for viewing / sharing / printing on the device.
  Future<File> saveLocally(String fileName, Uint8List bytes) async {
    final dir = await Directory('${(await getApplicationDocumentsDirectory()).path}/books').create(recursive: true);
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}

/// A photo of an official book could not be downloaded or prepared.
class BookImageException implements Exception {
  const BookImageException(this.mediaId);

  final String mediaId;

  @override
  String toString() => 'BookImageException($mediaId)';
}
