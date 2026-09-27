import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/content/content_route.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../memories/application/memory_providers.dart';
import '../application/media_providers.dart';
import '../data/media_repository.dart';
import '../domain/media_item.dart';
import 'media_viewer_screen.dart';
import 'media_widgets.dart';

enum _AlbumFilter { all, photos, videos, favorites, firstYear }

class AlbumScreen extends ConsumerStatefulWidget {
  const AlbumScreen({super.key});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  _AlbumFilter _filter = _AlbumFilter.all;
  String? _tag;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
        final key = _key();
        if (key != null) ref.read(albumProvider(key).notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  AlbumKey? _key() {
    final baby = ref.read(activeBabyProvider);
    if (baby == null) return null;
    final favorites = ref.read(favoritesProvider(baby.id)).value ?? const <String>{};
    final fy = baby.firstYear;
    return AlbumKey(
      baby.id,
      AlbumQuery(
        kind: switch (_filter) {
          _AlbumFilter.photos => MediaKind.photo,
          _AlbumFilter.videos => MediaKind.video,
          _ => null,
        },
        tag: _tag,
        ids: _filter == _AlbumFilter.favorites ? favorites : null,
        from: _filter == _AlbumFilter.firstYear ? Dates.addDays(fy.start, -300) : null,
        to: _filter == _AlbumFilter.firstYear ? fy.firstBirthday : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(activeAccessProvider);
    ref.watch(favoritesProvider(baby.id));
    final key = _key()!;
    final album = ref.watch(albumProvider(key));
    final favorites = ref.watch(favoritesProvider(baby.id)).value ?? const <String>{};
    final tags = ref.watch(albumTagsProvider(baby.id)).value ?? const <String>[];

    if (!access.can(AppPermission.viewAlbum)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Albüm')),
        body: const EmptyState(
          icon: Icons.lock_outline_rounded,
          title: 'Albüme erişim yok',
          message: 'Aile yöneticisi albümü görüntüleme yetkisi verdiğinde fotoğraflar burada görünür.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('${baby.firstName} · Albüm')),
      floatingActionButton: access.can(AppPermission.addPhoto) && access.can(AppPermission.addMemory)
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/memory/new?category=photo&pick=photo'),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Fotoğraf ekle'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(albumProvider(key).future),
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    for (final (f, label) in [
                      (_AlbumFilter.all, 'Tümü'),
                      (_AlbumFilter.photos, 'Fotoğraflar'),
                      (_AlbumFilter.videos, 'Videolar'),
                      (_AlbumFilter.favorites, 'Favoriler'),
                      (_AlbumFilter.firstYear, 'İlk Yılım'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (tags.isNotEmpty)
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      for (final t in tags)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text('#$t'),
                            selected: _tag == t,
                            visualDensity: VisualDensity.compact,
                            onSelected: (v) => setState(() => _tag = v ? t : null),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            AsyncValueView(
              value: album,
              sliver: true,
              onRetry: () => ref.invalidate(albumProvider(key)),
              data: (state) {
                if (state.items.isEmpty) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.photo_library_outlined,
                      title: 'Henüz fotoğraf yok',
                      message: 'Anılara eklenen fotoğraf ve videolar burada toplanır.',
                    ),
                  );
                }
                final groups = groupBy(state.items, (MediaItem m) => DateTime.utc(m.takenOn.year, m.takenOn.month));
                return SliverList.list(
                  children: [
                    for (final entry in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Row(
                          children: [
                            Text(Dates.monthYear(entry.key), style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            Text(
                              baby.ageOn(entry.value.first.takenOn)?.label ?? '',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                          ),
                          itemCount: entry.value.length,
                          itemBuilder: (_, i) {
                            final m = entry.value[i];
                            return MediaThumb(
                              media: m,
                              radius: 10,
                              favorite: favorites.contains(m.id),
                              onTap: () => context.push(
                                mediaViewerRoute(baby.id),
                                extra: MediaViewerArgs(media: state.items, initialIndex: state.items.indexOf(m)),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    if (state.loadingMore) const Padding(padding: EdgeInsets.all(16), child: LoadingView()),
                    const SizedBox(height: 96),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
