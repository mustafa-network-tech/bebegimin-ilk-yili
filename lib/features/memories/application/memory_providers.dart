import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../../media/data/media_repository.dart';
import '../../media/domain/media_item.dart';
import '../data/memory_repository.dart';
import '../data/timeline_repository.dart';
import '../domain/comment.dart';
import '../domain/memory.dart';
import '../domain/timeline_entry.dart';

class TimelineKey {
  const TimelineKey(this.babyId, [this.query = const TimelineQuery()]);

  final String babyId;
  final TimelineQuery query;

  @override
  bool operator ==(Object other) => other is TimelineKey && other.babyId == babyId && other.query == query;

  @override
  int get hashCode => Object.hash(babyId, query);
}

class TimelineState {
  const TimelineState({required this.entries, required this.media, required this.hasMore, this.loadingMore = false});

  final List<TimelineEntry> entries;

  /// parent id (memory / milestone / letter) → media
  final Map<String, List<MediaItem>> media;
  final bool hasMore;
  final bool loadingMore;

  TimelineState copyWith({
    List<TimelineEntry>? entries,
    Map<String, List<MediaItem>>? media,
    bool? hasMore,
    bool? loadingMore,
  }) => TimelineState(
    entries: entries ?? this.entries,
    media: media ?? this.media,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

final timelineProvider = AsyncNotifierProvider.autoDispose.family<TimelineController, TimelineState, TimelineKey>(
  TimelineController.new,
);

class TimelineController extends AsyncNotifier<TimelineState> {
  TimelineController(this.key);

  final TimelineKey key;

  @override
  Future<TimelineState> build() async {
    ref.watch(contentRevisionProvider);
    final entries = await ref.read(timelineRepositoryProvider).page(key.babyId, query: key.query);
    return TimelineState(
      entries: entries,
      media: await _mediaFor(entries),
      hasMore: entries.length == TimelineRepository.pageSize,
    );
  }

  Future<Map<String, List<MediaItem>>> _mediaFor(List<TimelineEntry> entries) async {
    try {
      final media = await ref
          .read(mediaRepositoryProvider)
          .forParents(
            memoryIds: entries.where((e) => e.type == EntryType.memory).map((e) => e.id),
            milestoneIds: entries.where((e) => e.type == EntryType.milestone).map((e) => e.id),
            letterIds: entries.where((e) => e.type == EntryType.letter).map((e) => e.id),
          );
      final map = <String, List<MediaItem>>{};
      for (final m in media) {
        final parent = m.memoryId ?? m.milestoneId ?? m.letterId;
        if (parent != null) (map[parent] ??= []).add(m);
      }
      return map;
    } catch (_) {
      return const {}; // thumbnails are optional (offline)
    }
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final more = await ref
          .read(timelineRepositoryProvider)
          .page(key.babyId, offset: current.entries.length, query: key.query);
      final media = await _mediaFor(more);
      state = AsyncData(
        current.copyWith(
          entries: [...current.entries, ...more],
          media: {...current.media, ...media},
          hasMore: more.length == TimelineRepository.pageSize,
          loadingMore: false,
        ),
      );
    } catch (e) {
      state = AsyncData(current.copyWith(loadingMore: false));
      rethrow;
    }
  }
}

class MemoryDetail {
  const MemoryDetail(this.memory, this.media);

  final Memory memory;
  final List<MediaItem> media;
}

final memoryDetailProvider = FutureProvider.autoDispose.family<MemoryDetail?, String>((ref, id) async {
  ref.watch(contentRevisionProvider);
  final memory = await ref.watch(memoryRepositoryProvider).get(id);
  if (memory == null) return null;
  final media = await ref.watch(mediaRepositoryProvider).forParents(memoryIds: [id]);
  return MemoryDetail(memory, media);
});

final commentsProvider = FutureProvider.autoDispose.family<List<Comment>, (TargetKind, String)>((ref, key) {
  ref.watch(contentRevisionProvider);
  return ref.watch(memoryRepositoryProvider).comments(key.$1, key.$2);
});

/// The user's favourites for a baby (ids of memories / media / milestones / letters).
final favoritesProvider = AsyncNotifierProvider.family<FavoritesController, Set<String>, String>(
  FavoritesController.new,
);

class FavoritesController extends AsyncNotifier<Set<String>> {
  FavoritesController(this.babyId);

  final String babyId;

  @override
  Future<Set<String>> build() => ref.read(memoryRepositoryProvider).favoriteIds(babyId);

  Future<void> toggle(TargetKind kind, String id) async {
    final current = state.value ?? <String>{};
    final fav = !current.contains(id);
    state = AsyncData(fav ? {...current, id} : ({...current}..remove(id)));
    try {
      await ref.read(memoryRepositoryProvider).setFavorite(babyId: babyId, kind: kind, targetId: id, favorite: fav);
    } catch (e) {
      state = AsyncData(current);
      rethrow;
    }
  }
}
