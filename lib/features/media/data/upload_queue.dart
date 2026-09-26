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
  static const _prefsKey = 'upload_queue.v1';
  static const maxAttempts = 6;
  bool _running = false;
  Directory? _dir;

  SupabaseClient get _client => ref.read(supabaseProvider);

  @override
  List<PendingUpload> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_prefsKey);
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
    ref.listen(currentUserIdProvider, (prev, next) {
      if (next != null) unawaited(process());
    });
    Future.microtask(process);
    return items;
  }

  Future<void> _persist() => ref.read(sharedPreferencesProvider).setString(
    _prefsKey,
    jsonEncode(state.map((e) => e.toJson()).toList()),
  );

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
    final dir = await _workDir();
    final added = <PendingUpload>[];
    for (final f in files) {
      final id = const Uuid().v4();
      final ext = f.path.contains('.') ? f.path.split('.').last.toLowerCase() : (f.kind == MediaKind.photo ? 'jpg' : 'mp4');
      final local = await File(f.path).copy('${dir.path}/$id.src.$ext');
      added.add(PendingUpload(
        id: id,
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
      ));
    }
    state = [...state, ...added];
    await _persist();
    unawaited(process());
  }

  Future<void> retryFailed() async {
    state = [
      for (final u in state) u.state == UploadState.failed ? u.copyWith(state: UploadState.queued, attempts: 0, clearError: true) : u,
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
        await _client.from('media').delete().eq('id', item.id);
      } catch (_) {}
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
        final processed = await ImageProcessing.processPhoto(u.localPath, dir.path, u.id);
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
      await _client.from('media').update({'status': 'ready'}).eq('id', u.id);

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
      final attempts = u.attempts + 1;
      _replace(u.copyWith(
        attempts: attempts,
        state: attempts >= maxAttempts ? UploadState.failed : UploadState.queued,
        error: err.message,
      ));
      await _persist();
      // small back-off before the next item / retry
      await Future<void>.delayed(Duration(seconds: attempts * 2));
      return attempts < maxAttempts || state.any((x) => x.state == UploadState.queued);
    }
  }

  Future<void> _cleanupLocal(PendingUpload u) async {
    final dir = await _workDir();
    for (final path in [u.localPath, '${dir.path}/${u.id}_original.jpg', '${dir.path}/${u.id}_thumb.jpg']) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
