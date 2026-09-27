import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../memories/data/memory_repository.dart';
import '../domain/media_item.dart';

final mediaRepositoryProvider = Provider<MediaRepository>((ref) => MediaRepository(ref.watch(supabaseProvider)));

class AlbumQuery {
  const AlbumQuery({this.kind, this.tag, this.ids, this.from, this.to, this.text});

  final MediaKind? kind;
  final String? tag;
  final Set<String>? ids;
  final DateTime? from;
  final DateTime? to;
  final String? text;

  @override
  bool operator ==(Object other) =>
      other is AlbumQuery &&
      other.kind == kind &&
      other.tag == tag &&
      other.from == from &&
      other.to == to &&
      other.text == text &&
      ((other.ids == null && ids == null) ||
          (other.ids != null && ids != null && other.ids!.length == ids!.length && other.ids!.containsAll(ids!)));

  @override
  int get hashCode => Object.hash(kind, tag, from, to, text, ids?.length);
}

class MediaRepository {
  MediaRepository(this._client);

  final SupabaseClient _client;

  Future<List<MediaItem>> album(
    String babyId, {
    AlbumQuery query = const AlbumQuery(),
    int offset = 0,
    int limit = 60,
  }) async {
    var q = _client.from('media').select().eq('baby_id', babyId).eq('status', 'ready');
    if (query.kind != null) q = q.eq('kind', query.kind!.name);
    if (query.tag != null) q = q.contains('tags', [query.tag!]);
    if (query.ids != null) q = q.inFilter('id', query.ids!.toList());
    if (query.from != null) q = q.gte('taken_on', Dates.toSql(query.from!));
    if (query.to != null) q = q.lte('taken_on', Dates.toSql(query.to!));
    if (query.text?.trim().isNotEmpty ?? false) {
      q = q.ilike('caption', '%${query.text!.trim().replaceAll('%', r'\%').replaceAll('_', r'\_')}%');
    }
    final rows = await q
        .order('taken_on', ascending: false)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return rows.map(MediaItem.fromJson).toList();
  }

  /// Media attached to any of the given parents (timeline thumbnails).
  Future<List<MediaItem>> forParents({
    required String babyId,
    Iterable<String> memoryIds = const [],
    Iterable<String> milestoneIds = const [],
    Iterable<String> letterIds = const [],
  }) async {
    final filters = <String>[
      if (memoryIds.isNotEmpty) 'memory_id.in.(${memoryIds.join(',')})',
      if (milestoneIds.isNotEmpty) 'milestone_id.in.(${milestoneIds.join(',')})',
      if (letterIds.isNotEmpty) 'letter_id.in.(${letterIds.join(',')})',
    ];
    if (filters.isEmpty) return const [];
    final rows = await _client
        .from('media')
        .select()
        .eq('baby_id', babyId)
        .or(filters.join(','))
        .order('sort_order')
        .order('created_at');
    return rows.map(MediaItem.fromJson).where((m) => m.status == 'ready').toList();
  }

  Future<List<MediaItem>> allForBaby(String babyId) async {
    final rows = await _client.from('media').select().eq('baby_id', babyId).eq('status', 'ready').order('taken_on');
    return rows.map(MediaItem.fromJson).toList();
  }

  Future<List<String>> tags(String babyId) async {
    final rows = await _client.from('media').select('tags').eq('baby_id', babyId).eq('status', 'ready');
    final set = <String>{for (final r in rows) ...((r['tags'] as List?) ?? const []).map((e) => e.toString())};
    return set.toList()..sort();
  }

  Future<MediaItem> update(
    String babyId,
    String id, {
    String? caption,
    List<String>? tags,
    bool? includeInBook,
    DateTime? takenOn,
  }) async {
    final row = await _client
        .from('media')
        .update({
          'caption': ?caption,
          'tags': ?tags,
          'include_in_book': ?includeInBook,
          if (takenOn != null) 'taken_on': Dates.toSql(takenOn),
        })
        .eq('baby_id', babyId)
        .eq('id', id)
        .select()
        .single();
    return MediaItem.fromJson(row);
  }

  Future<void> delete(MediaItem media) async {
    await removeFiles(_client, [media]);
    await _client.from('media').delete().eq('baby_id', media.babyId).eq('id', media.id);
  }
}
