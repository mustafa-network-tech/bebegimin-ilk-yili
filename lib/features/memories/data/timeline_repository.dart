import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../domain/timeline_entry.dart';

final timelineRepositoryProvider = Provider<TimelineRepository>(
  (ref) => TimelineRepository(ref.watch(supabaseProvider), ref.watch(localCacheProvider)),
);

/// Filters for the timeline view and the search screen.
class TimelineQuery {
  const TimelineQuery({
    this.types = const {},
    this.from,
    this.to,
    this.authorId,
    this.text,
    this.ids,
    this.onlyBookCandidates = false,
  });

  final Set<EntryType> types;
  final DateTime? from;
  final DateTime? to;
  final String? authorId;
  final String? text;
  final Set<String>? ids;
  final bool onlyBookCandidates;

  bool get isEmpty =>
      types.isEmpty && from == null && to == null && authorId == null && (text?.isEmpty ?? true) && ids == null;

  @override
  bool operator ==(Object other) =>
      other is TimelineQuery &&
      other.types.length == types.length &&
      other.types.containsAll(types) &&
      other.from == from &&
      other.to == to &&
      other.authorId == authorId &&
      other.text == text &&
      other.onlyBookCandidates == onlyBookCandidates &&
      ((other.ids == null && ids == null) ||
          (other.ids != null && ids != null && other.ids!.length == ids!.length && other.ids!.containsAll(ids!)));

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(types), from, to, authorId, text, onlyBookCandidates, ids?.length);
}

class TimelineRepository {
  TimelineRepository(this._client, this._cache);

  final SupabaseClient _client;
  final LocalCache _cache;

  static const pageSize = 30;

  /// PostgREST `ilike` pattern with wildcards escaped.
  static String likePattern(String text) =>
      '%${text.trim().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_').replaceAll(',', ' ')}%';

  Future<List<TimelineEntry>> page(String babyId, {int offset = 0, TimelineQuery query = const TimelineQuery()}) async {
    Future<List<TimelineEntry>> fetch() async {
      var q = _client.from('timeline_entries').select().eq('baby_id', babyId);
      if (query.types.isNotEmpty) q = q.inFilter('entry_type', query.types.map((t) => t.name).toList());
      if (query.from != null) q = q.gte('entry_date', Dates.toSql(query.from!));
      if (query.to != null) q = q.lte('entry_date', Dates.toSql(query.to!));
      if (query.authorId != null) q = q.eq('author_id', query.authorId!);
      if (query.ids != null) q = q.inFilter('id', query.ids!.toList());
      if (query.onlyBookCandidates) q = q.eq('include_in_book', true);
      final text = query.text?.trim();
      if (text != null && text.isNotEmpty) {
        final p = likePattern(text);
        q = q.or('title.ilike.$p,body.ilike.$p');
      }
      final rows = await q
          .order('entry_date', ascending: false)
          .order('entry_time', ascending: false, nullsFirst: false)
          .order('created_at', ascending: false)
          .range(offset, offset + pageSize - 1);
      return rows.map(TimelineEntry.fromJson).toList();
    }

    // Only the unfiltered first page is cached for offline use.
    if (offset == 0 && query.isEmpty) {
      return _cache.networkFirst<List<TimelineEntry>>(
        key: 'timeline.$babyId',
        fetch: fetch,
        encode: (l) => l.map((e) => e.toJson()).toList(),
        decode: (j) => (j as List).map((e) => TimelineEntry.fromJson((e as Map).cast<String, dynamic>())).toList(),
      );
    }
    return fetch();
  }

  /// All entries of a date range (calendar month).
  Future<List<TimelineEntry>> range(String babyId, DateTime from, DateTime to) async {
    final rows = await _client
        .from('timeline_entries')
        .select()
        .eq('baby_id', babyId)
        .gte('entry_date', Dates.toSql(from))
        .lte('entry_date', Dates.toSql(to))
        .order('entry_date')
        .limit(1000);
    return rows.map(TimelineEntry.fromJson).toList();
  }
}
