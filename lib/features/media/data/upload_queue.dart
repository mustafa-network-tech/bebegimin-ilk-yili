import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/connectivity.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../domain/media_item.dart';
import '../domain/pending_upload.dart';
import 'image_processing.dart';

/// A file the user picked, before it is queued.
class PickedMedia {
  const PickedMedia({required this.path, required this.kind, this.durationMs, this.caption});

  final String path;
  final MediaKind kind;
  final int? durationMs;
  final String? caption;
}

final uploadQueueProvider = NotifierProvider<UploadQueue, List<PendingUpload>>(UploadQueue.new);

/// Sequential, persistent, resumable upload queue.
///
/// Flow per item: (1) photo processed on device, (2) `media` row inserted
/// with status `uploading` (this row authorises the Storage write), (3)
/// files uploaded, (4) row marked `ready`. Every step is idempotent, so an
/// interrupted upload simply resumes from the start of the failed step.
class UploadQueue extends Notifier<List<PendingUpload>> {
  static const _legacyPrefsKey = 'upload_queue.v1';
  static const _prefsPrefix = 'upload_queue.v2.';
  static const maxAttempts = 6;
  bool _running = false;
  Directory? _dir;

  SupabaseClient get _client => ref.read(supabaseProvider);

  @override
  List<PendingUpload> build() {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return const [];
    final prefs = ref.read(sharedPreferencesProvider);
    final legacyRaw = prefs.getString(_legacyPrefsKey);
    if (legacyRaw != null) {
      unawaited(prefs.remove(_legacyPrefsKey));
      unawaited(_purgeLegacyQueue(legacyRaw));
    }
    final raw = prefs.getString('$_prefsPrefix$userId');
    var items = <PendingUpload>[];
    if (raw != null) {
      try {
        items = (jsonDecode(raw) as List)
            .map((e) => PendingUpload.fromJson((e as Map).cast<String, dynamic>()))
            // app was killed mid-upload -> retry
            .map((u) => u.state == UploadState.uploading ? u.copyWith(state: UploadState.queued) : u)
            .toList();
      } catch (_) {}
    }
    ref.listen(isOnlineProvider, (_, next) {
      if (next.value == true) unawaited(process());
    });
    Future.microtask(process);
    return items;
  }

  Future<void> _persist() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    await ref
        .read(sharedPreferencesProvider)
        .setString('$_prefsPrefix$userId', jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  Future<Directory> _workDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    _dir = await Directory('${base.path}/uploads').create(recursive: true);
    return _dir!;
  }

  int pendingFor(String babyId) => state.where((u) => u.babyId == babyId).length;

  /// Copies the picked files into app storage (gallery temp files may be
  /// deleted by the OS) and queues them.
  Future<void> enqueue({
    required String babyId,
    required List<PickedMedia> files,
    required DateTime takenOn,
    String? memoryId,
    String? milestoneId,
    String? letterId,
    List<String> tags = const [],
  }) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) throw StateError('Upload requires an authenticated user.');
    final root = await _workDir();
    final added = <PendingUpload>[];
    for (final f in files) {
      final id = const Uuid().v4();
      final ext = f.path.contains('.')
          ? f.path.split('.').last.toLowerCase()
          : (f.kind == MediaKind.photo ? 'jpg' : 'mp4');
      final dir = await Directory('${root.path}/$userId/$babyId/$id').create(recursive: true);
      final local = await File(f.path).copy('${dir.path}/source.$ext');
      added.add(
        PendingUpload(
          id: id,
          userId: userId,
          babyId: babyId,
          kind: f.kind,
          localPath: local.path,
          mimeType: f.kind == MediaKind.photo ? 'image/jpeg' : ImageProcessing.mimeForVideo(f.path),
          takenOn: Dates.dateOnly(takenOn),
          memoryId: memoryId,
          milestoneId: milestoneId,
          letterId: letterId,
          caption: f.caption,
          tags: tags,
          durationMs: f.durationMs,
        ),
      );
    }
    state = [...state, ...added];
    await _persist();
    unawaited(process());
  }

  Future<void> retryFailed({String? babyId}) async {
    state = [
      for (final u in state)
        u.state == UploadState.failed && (babyId == null || u.babyId == babyId)
            ? u.copyWith(state: UploadState.queued, attempts: 0, clearError: true)
            : u,
    ];
    await _persist();
    await process();
  }

  Future<void> cancel(String id) async {
    final item = state.where((u) => u.id == id).firstOrNull;
    if (item == null) return;
    state = state.where((u) => u.id != id).toList();
    await _persist();
    await _cleanupLocal(item);
    if (item.rowCreated) {
      try {
        await _client.from('media').delete().eq('baby_id', item.babyId).eq('id', item.id);
      } catch (_) {}
    }
  }

  Future<void> clearAll() async {
    final userId = ref.read(currentUserIdProvider);
    final items = List<PendingUpload>.of(state);
    state = const [];
    if (userId != null) {
      await ref.read(sharedPreferencesProvider).remove('$_prefsPrefix$userId');
    }
    await ref.read(sharedPreferencesProvider).remove(_legacyPrefsKey);
    for (final item in items) {
      await _cleanupLocal(item);
    }
  }

  Future<void> process() async {
    if (_running) return;
    if (ref.read(currentUserIdProvider) == null) return;
    _running = true;
    try {
      while (true) {
        final next = state.where((u) => u.state == UploadState.queued).firstOrNull;
        if (next == null) break;
        final ok = await _uploadOne(next);
        if (!ok) break; // offline: wait for connectivity
      }
    } finally {
      _running = false;
    }
  }

  void _replace(PendingUpload u) {
    state = [for (final x in state) x.id == u.id ? u : x];
  }

  /// Returns false when processing should pause (network down).
  Future<bool> _uploadOne(PendingUpload item) async {
    var u = item.copyWith(state: UploadState.uploading);
    _replace(u);
    try {
      final dir = await _workDir();
      final storage = _client.storage.from(Buckets.babyMedia);
      int? width, height;
      File original;
      File? thumb;

      if (u.kind == MediaKind.photo) {
        final processedDir = await Directory('${dir.path}/${u.localNamespace}').create(recursive: true);
        final processed = await ImageProcessing.processPhoto(u.localPath, processedDir.path, u.id);
        original = processed.original;
        thumb = processed.thumb;
        width = processed.width;
        height = processed.height;
      } else {
        original = File(u.localPath);
      }
      final size = await original.length();

      if (!u.rowCreated) {
        try {
          await _client.from('media').insert({
            'id': u.id,
            'baby_id': u.babyId,
            'memory_id': u.memoryId,
            'milestone_id': u.milestoneId,
            'letter_id': u.letterId,
            'kind': u.kind.name,
            'storage_path': u.storagePath,
            'thumb_path': u.thumbPath,
            'mime_type': u.mimeType,
            'width': width,
            'height': height,
            'duration_ms': u.durationMs,
            'size_bytes': size,
            'caption': u.caption,
            'taken_on': Dates.toSql(u.takenOn),
            'tags': u.tags,
            'status': 'uploading',
          });
        } on PostgrestException catch (e) {
          if (e.code != '23505') rethrow; // already inserted by a previous attempt
        }
        u = u.copyWith(rowCreated: true);
        _replace(u);
        await _persist();
      }

      await storage.upload(
        u.storagePath,
        original,
        fileOptions: FileOptions(contentType: u.mimeType, upsert: true, cacheControl: '31536000'),
      );
      if (thumb != null && u.thumbPath != null) {
        await storage.upload(
          u.thumbPath!,
          thumb,
          fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true, cacheControl: '31536000'),
        );
      }
      await _client.from('media').update({'status': 'ready'}).eq('baby_id', u.babyId).eq('id', u.id);

      state = state.where((x) => x.id != u.id).toList();
      await _persist();
      await _cleanupLocal(u);
      ref.read(contentRevisionProvider.notifier).bump();
      return true;
    } catch (e) {
      final err = AppException.from(e);
      if (err.isNetwork) {
        _replace(u.copyWith(state: UploadState.queued));
        await _persist();
        return false;
      }
      debugPrint('upload failed: $e');
      // A locked archive never becomes writable again: fail without retries.
      final attempts = AppException.isLifecycleLocked(e) ? maxAttempts : u.attempts + 1;
      _replace(
        u.copyWith(
          attempts: attempts,
          state: attempts >= maxAttempts ? UploadState.failed : UploadState.queued,
          error: err.message,
        ),
      );
      await _persist();
      // small back-off before the next item / retry
      await Future<void>.delayed(Duration(seconds: attempts * 2));
      return attempts < maxAttempts || state.any((x) => x.state == UploadState.queued);
    }
  }

  Future<void> _cleanupLocal(PendingUpload u) async {
    final dir = await _workDir();
    final itemDir = Directory('${dir.path}/${u.localNamespace}');
    try {
      if (await itemDir.exists()) await itemDir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _purgeLegacyQueue(String raw) async {
    try {
      final root = await _workDir();
      final rootPath = root.absolute.path;
      final rows = (jsonDecode(raw) as List).whereType<Map>().map((row) => row.cast<String, dynamic>());
      for (final row in rows) {
        final id = row['id'] as String?;
        final localPath = row['local_path'] as String?;
        if (id == null) continue;
        if (localPath != null) {
          final source = File(localPath);
          final name = source.path.split(Platform.pathSeparator).last;
          if (source.parent.absolute.path == rootPath && name.startsWith('$id.src.')) {
            try {
              if (await source.exists()) await source.delete();
            } catch (_) {}
          }
        }
        for (final path in ['${root.path}/${id}_original.jpg', '${root.path}/${id}_thumb.jpg']) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
