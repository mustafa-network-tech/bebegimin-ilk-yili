import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/comment.dart';
import '../domain/memory.dart';

final memoryRepositoryProvider = Provider<MemoryRepository>((ref) => MemoryRepository(ref.watch(supabaseProvider)));

class MemoryRepository {
  MemoryRepository(this._client);

  final SupabaseClient _client;

  Future<Memory?> get(String babyId, String id) async {
    final row = await _client.from('memories').select().eq('baby_id', babyId).eq('id', id).maybeSingle();
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

  Future<Memory> update(String babyId, String id, MemoryDraft draft) async {
    final json = draft.toJson()..remove('baby_id');
    final row = await _client.from('memories').update(json).eq('baby_id', babyId).eq('id', id).select().single();
    return Memory.fromJson(row);
  }

  Future<void> setIncludeInBook(String babyId, String id, bool value) =>
      _client.from('memories').update({'include_in_book': value}).eq('baby_id', babyId).eq('id', id);

  /// Deletes the row (cascading to its media rows). The database decides
  /// authorisation and lifecycle first; files of cascaded media rows are
  /// queued server-side for the storage-cleanup function.
  Future<void> delete(String babyId, String id) => _client.from('memories').delete().eq('baby_id', babyId).eq('id', id);

  // Comments / family notes ------------------------------------------------------
  Future<List<Comment>> comments(String babyId, TargetKind kind, String targetId) async {
    final rows = await _client
        .from('comments')
        .select()
        .eq('baby_id', babyId)
        .eq(kind.column, targetId)
        .order('created_at');
    return rows.map(Comment.fromJson).toList();
  }

  Future<void> addComment({
    required String babyId,
    required TargetKind kind,
    required String targetId,
    required String body,
  }) => _client.from('comments').insert({'baby_id': babyId, kind.column: targetId, 'body': body.trim()});

  Future<void> deleteComment(String babyId, String id) =>
      _client.from('comments').delete().eq('baby_id', babyId).eq('id', id);

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
      await _client.from('favorites').delete().eq('baby_id', babyId).eq(kind.column, targetId);
    }
  }

  /// RLS-authorized lookup used only to migrate legacy deep links.
  /// Both missing and unauthorized records resolve to null.
  Future<String?> resolveLegacyBabyId(String id) async {
    final row = await _client.from('memories').select('baby_id').eq('id', id).maybeSingle();
    return row?['baby_id'] as String?;
  }
}
