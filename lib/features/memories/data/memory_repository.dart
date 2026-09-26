import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../../media/domain/media_item.dart';
import '../domain/comment.dart';
import '../domain/memory.dart';

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) => MemoryRepository(ref.watch(supabaseProvider)));

class MemoryRepository {
  MemoryRepository(this._client);

  final SupabaseClient _client;

  Future<Memory?> get(String id) async {
    final row = await _client.from('memories').select().eq('id', id).maybeSingle();
    return row == null ? null : Memory.fromJson(row);
  }

  Future<List<Memory>> forBaby(String babyId, {DateTime? from, DateTime? to}) async {
    var q = _client.from('memories').select().eq('baby_id', babyId);
    if (from != null) q = q.gte('memory_date', from.toIso8601String().substring(0, 10));
    if (to != null) q = q.lte('memory_date', to.toIso8601String().substring(0, 10));
    final rows = await q.order('memory_date');
    return rows.map(Memory.fromJson).toList();
  }

  Future<Memory> create(MemoryDraft draft) async {
    final row = await _client.from('memories').insert(draft.toJson()).select().single();
    return Memory.fromJson(row);
  }

  Future<Memory> update(String id, MemoryDraft draft) async {
    final json = draft.toJson()..remove('baby_id');
    final row = await _client.from('memories').update(json).eq('id', id).select().single();
    return Memory.fromJson(row);
  }

  Future<void> setIncludeInBook(String id, bool value) =>
      _client.from('memories').update({'include_in_book': value}).eq('id', id);

  /// Removes the files first (Storage API), then the row (cascades media rows).
  Future<void> delete(String id, List<MediaItem> media) async {
    await removeFiles(_client, media);
    await _client.from('memories').delete().eq('id', id);
  }

  // Comments / family notes ------------------------------------------------------
  Future<List<Comment>> comments(TargetKind kind, String targetId) async {
    final rows = await _client.from('comments').select().eq(kind.column, targetId).order('created_at');
    return rows.map(Comment.fromJson).toList();
  }

  Future<void> addComment({
    required String babyId,
    required TargetKind kind,
    required String targetId,
    required String body,
  }) => _client.from('comments').insert({'baby_id': babyId, kind.column: targetId, 'body': body.trim()});

  Future<void> deleteComment(String id) => _client.from('comments').delete().eq('id', id);

  // Favorites (per user) ---------------------------------------------------------------
  Future<Set<String>> favoriteIds(String babyId) async {
    final rows = await _client
        .from('favorites')
        .select('memory_id, media_id, milestone_id, letter_id')
        .eq('baby_id', babyId);
    return {for (final r in rows) (r['memory_id'] ?? r['media_id'] ?? r['milestone_id'] ?? r['letter_id']) as String};
  }

  Future<void> setFavorite({
    required String babyId,
    required TargetKind kind,
    required String targetId,
    required bool favorite,
  }) async {
    if (favorite) {
      await _client.from('favorites').insert({'baby_id': babyId, kind.column: targetId});
    } else {
      await _client.from('favorites').delete().eq(kind.column, targetId);
    }
  }
}

/// Best-effort removal of media files through the Storage API. Rows removed
/// by cascades are also queued server-side for the cleanup function.
Future<void> removeFiles(SupabaseClient client, List<MediaItem> media) async {
  final paths = [
    for (final m in media) ...[m.storagePath, ?m.thumbPath],
  ];
  if (paths.isEmpty) return;
  try {
    await client.storage.from(Buckets.babyMedia).remove(paths);
  } catch (_) {}
}
