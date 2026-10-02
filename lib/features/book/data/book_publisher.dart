import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../domain/book_snapshot.dart';
import 'book_generator.dart';
import 'book_repository.dart';

final bookPublisherProvider = Provider<BookPublisher>((ref) => BookPublisher(ref));

class BookPublishResult {
  const BookPublishResult({required this.file, required this.version, required this.pageCount});

  /// Local copy of exactly the bytes the server verified.
  final File file;
  final int version;
  final int pageCount;
}

/// Official book PDF (plan 2.8 / Phase 9). The engine stays on the device,
/// but the result only counts once the server has re-hashed the upload:
///   lease job → verify snapshot + manifest checksums → render from them →
///   artifact row → staging upload → server verify / move / publish.
class BookPublisher {
  BookPublisher(this._ref);

  final Ref _ref;
  static const _uuid = Uuid();
  static const heartbeatEvery = Duration(minutes: 4);

  Future<BookPublishResult> publish(String babyId, {void Function(BookProgress)? onProgress}) async {
    final repo = _ref.read(bookRepositoryProvider);
    final generator = _ref.read(bookGeneratorProvider);

    onProgress?.call(const BookProgress('Arşiv mühürleniyor', 0, 0));
    final lease = await repo.startRender(babyId, 'book-${_uuid.v4()}');
    final heartbeat = Timer.periodic(heartbeatEvery, (_) => unawaited(repo.heartbeat(lease.jobId).catchError((_) {})));
    var failureCode = 'render_failed';
    try {
      onProgress?.call(const BookProgress('İçerikler doğrulanıyor', 0, 0));
      final inputs = BookRenderInputs.fromPayload(await repo.payload(lease.jobId));

      failureCode = 'image_failed';
      final (bytes, pages) = await generator.renderOfficial(
        inputs,
        onProgress: (p) {
          if (p.stage != 'Fotoğraflar hazırlanıyor') failureCode = 'render_failed';
          onProgress?.call(p);
        },
      );

      failureCode = 'upload_failed';
      onProgress?.call(const BookProgress('Kitap yükleniyor', 0, 0));
      final slot = await repo.beginArtifact(lease.jobId, sha256.convert(bytes).toString(), bytes.length);
      await repo.uploadStaging(slot.stagingPath, bytes);

      // From here on the server owns the outcome (verify, quarantine, retry).
      failureCode = '';
      onProgress?.call(const BookProgress('Sunucu doğruluyor', 0, 0));
      final version = await retryTransient(() => repo.finalize(slot.artifactId, pages));
      final file = await generator.saveLocally('ilk-yil-kitabi-v$version.pdf', bytes);
      return BookPublishResult(file: file, version: version, pageCount: pages);
    } catch (e) {
      if (failureCode.isNotEmpty) unawaited(repo.fail(lease.jobId, failureCode).catchError((_) {}));
      throw _friendly(e);
    } finally {
      heartbeat.cancel();
    }
  }

  /// Finalize is idempotent on the server, so a lost reply or a transient
  /// server error is retried with the same artifact. Giving up would throw
  /// away a rendered book while the job's lease blocks a new attempt.
  static Future<T> retryTransient<T>(
    Future<T> Function() op, {
    int attempts = 3,
    Duration delay = const Duration(seconds: 2),
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await op();
      } catch (e) {
        if (attempt >= attempts || !isTransient(e)) rethrow;
        await Future<void>.delayed(delay * attempt);
      }
    }
  }

  /// Network trouble or a 5xx from the function; refusals (4xx) are final.
  static bool isTransient(Object e) => AppException.isNetworkError(e) || (e is FunctionException && e.status >= 500);

  static Object _friendly(Object e) => switch (e) {
    BookIntegrityException() => const AppException(
      'Arşiv verisi doğrulanamadı. Lütfen tekrar deneyin.',
      kind: AppErrorKind.server,
    ),
    BookImageException() => const AppException(
      'Bazı fotoğraflar indirilemedi. İnternet bağlantınızı kontrol edip tekrar deneyin.',
      kind: AppErrorKind.network,
    ),
    _ => e,
  };
}
