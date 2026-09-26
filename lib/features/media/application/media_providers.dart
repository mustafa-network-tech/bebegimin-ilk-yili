import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../data/media_repository.dart';
import '../domain/media_item.dart';

class AlbumKey {
  const AlbumKey(this.babyId, [this.query = const AlbumQuery()]);

  final String babyId;
  final AlbumQuery query;

  @override
  bool operator ==(Object other) => other is AlbumKey && other.babyId == babyId && other.query == query;

  @override
  int get hashCode => Object.hash(babyId, query);
}

class AlbumState {
  const AlbumState(this.items, {required this.hasMore, this.loadingMore = false});

  final List<MediaItem> items;
  final bool hasMore;
  final bool loadingMore;
}

final albumProvider = AsyncNotifierProvider.autoDispose.family<AlbumController, AlbumState, AlbumKey>(
  AlbumController.new,
);

class AlbumController extends AsyncNotifier<AlbumState> {
  AlbumController(this.key);

  final AlbumKey key;
  static const _page = 60;

  @override
  Future<AlbumState> build() async {
    ref.watch(contentRevisionProvider);
    final items = await ref.read(mediaRepositoryProvider).album(key.babyId, query: key.query, limit: _page);
    return AlbumState(items, hasMore: items.length == _page);
  }

  Future<void> loadMore() async {
    final s = state.value;
    if (s == null || !s.hasMore || s.loadingMore) return;
    state = AsyncData(AlbumState(s.items, hasMore: true, loadingMore: true));
    try {
      final more = await ref
          .read(mediaRepositoryProvider)
          .album(key.babyId, query: key.query, offset: s.items.length, limit: _page);
      state = AsyncData(AlbumState([...s.items, ...more], hasMore: more.length == _page));
    } catch (_) {
      state = AsyncData(AlbumState(s.items, hasMore: true));
    }
  }
}

final albumTagsProvider = FutureProvider.autoDispose.family<List<String>, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(mediaRepositoryProvider).tags(babyId);
});

final parentMediaProvider = FutureProvider.autoDispose.family<List<MediaItem>, (String kind, String id)>((ref, key) {
  ref.watch(contentRevisionProvider);
  final repo = ref.watch(mediaRepositoryProvider);
  return switch (key.$1) {
    'milestone' => repo.forParents(milestoneIds: [key.$2]),
    'letter' => repo.forParents(letterIds: [key.$2]),
    _ => repo.forParents(memoryIds: [key.$2]),
  };
});
