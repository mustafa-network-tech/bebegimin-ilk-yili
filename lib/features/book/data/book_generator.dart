import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/storage/signed_urls.dart';
import '../../babies/domain/baby.dart';
import '../../family/data/family_repository.dart';
import '../../letters/data/letter_repository.dart';
import '../../media/data/image_processing.dart';
import '../../media/data/media_repository.dart';
import '../../memories/data/memory_repository.dart';
import '../../milestones/data/milestone_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import '../domain/book_render.dart';
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
  /// the first year.
  Future<BookSource> loadSource(Baby baby) async {
    final memoriesRepo = _ref.read(memoryRepositoryProvider);
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
    );
  }

  Future<BookRenderData> resolve(BookProject project, BookSource source) async {
    final members = await _ref.read(familyRepositoryProvider).members(project.babyId);
    return const BookRenderResolver().resolve(project: project, source: source, members: members);
  }

  Future<Map<String, Uint8List>> prepareImages(
    BookRenderData data,
    BookQuality quality, {
    void Function(BookProgress)? onProgress,
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
          if (res.statusCode != 200) continue;
          final jpeg = await ImageProcessing.compressBytes(res.bodyBytes, quality.maxImagePx, quality.jpegQuality);
          await cached.writeAsBytes(jpeg, flush: true);
          result[p.mediaId] = jpeg;
        } catch (_) {
          // A missing photo must not break the whole book: it renders as an
          // empty frame and the user can remove it in the editor.
        }
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

  /// Full pipeline; returns the PDF file in the app's documents folder.
  Future<(File, int)> generate(
    BookProject project,
    Baby baby,
    BookQuality quality, {
    void Function(BookProgress)? onProgress,
  }) async {
    onProgress?.call(const BookProgress('İçerikler toplanıyor', 0, 0));
    final source = await loadSource(baby);
    final data = await resolve(project, source);
    final images = await prepareImages(data, quality, onProgress: onProgress);
    onProgress?.call(const BookProgress('Sayfalar dizgileniyor', 0, 0));
    final job = BookBuildJob(data: data, fonts: await _fonts(), images: images);
    final result = await Isolate.run(() => buildBookPdf(job));
    final dir = await Directory('${(await getApplicationDocumentsDirectory()).path}/books').create(recursive: true);
    final file = File('${dir.path}/${_fileName(baby, quality)}');
    await file.writeAsBytes(result.bytes, flush: true);
    return (file, result.pageCount);
  }

  String _fileName(Baby baby, BookQuality q) {
    final safe = baby.firstName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9çğıöşü]+'), '-');
    return '$safe-ilk-yilim-${q.key}.pdf';
  }

  /// Local copy of a published export (for viewing / sharing offline).
  Future<File> saveExportLocally(BookExport export, Uint8List bytes) async {
    final dir = await Directory('${(await getApplicationDocumentsDirectory()).path}/books').create(recursive: true);
    final file = File('${dir.path}/${export.fileName}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
