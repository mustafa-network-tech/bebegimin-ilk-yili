import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../media/presentation/media_viewer_screen.dart';
import '../../media/presentation/media_widgets.dart';
import '../../milestones/application/milestone_providers.dart';
import '../application/memory_providers.dart';
import '../data/memory_repository.dart';
import '../domain/comment.dart';
import 'comments_section.dart';

class MemoryDetailScreen extends ConsumerWidget {
  const MemoryDetailScreen({super.key, required this.memoryId});

  final String memoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    final detail = ref.watch(memoryDetailProvider(memoryId));
    if (!detail.hasValue) {
      return Scaffold(
        appBar: AppBar(),
        body: AsyncValueView<MemoryDetail?>(
          value: detail,
          onRetry: () => ref.invalidate(memoryDetailProvider(memoryId)),
          data: (_) => const SizedBox.shrink(),
        ),
      );
    }
    return Scaffold(
      body: AsyncValueView<MemoryDetail?>(
        value: detail,
        onRetry: () => ref.invalidate(memoryDetailProvider(memoryId)),
        data: (d) {
          if (d == null || baby == null) {
            return Scaffold(
              appBar: AppBar(),
              body: const EmptyState(icon: Icons.search_off_rounded, title: 'Anı bulunamadı', message: 'Silinmiş olabilir ya da erişim yetkiniz yok.'),
            );
          }
          final m = d.memory;
          final theme = Theme.of(context);
          final access = ref.watch(accessProvider(m.babyId));
          final canEdit = access.canEditContent(m.authorId);
          final favorites = ref.watch(favoritesProvider(m.babyId)).value ?? const <String>{};
          final isFav = favorites.contains(m.id);
          final author = ref.watch(authorNameProvider((m.babyId, m.authorId)));
          final age = baby.ageOn(m.date);
          final linked = m.milestoneId == null
              ? null
              : ref.watch(milestoneSlotsProvider(m.babyId)).value?.where((s) => s.milestone?.id == m.milestoneId).firstOrNull;
          final fy = baby.firstYear;

          Future<void> delete() async {
            final ok = await confirm(context, title: 'Anı silinsin mi?', message: 'Anı ve bağlı fotoğraf/videolar kalıcı olarak silinir.', confirmLabel: 'Sil', destructive: true);
            if (!ok || !context.mounted) return;
            final done = await runWithProgress(context, () async {
              await ref.read(memoryRepositoryProvider).delete(m.id, d.media);
              return true;
            });
            if (done == true && context.mounted) {
              ref.read(contentRevisionProvider.notifier).bump();
              context.pop();
            }
          }

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: d.media.isEmpty ? null : 340,
                flexibleSpace: d.media.isEmpty
                    ? null
                    : FlexibleSpaceBar(
                        background: PageView(
                          children: [
                            for (var i = 0; i < d.media.length; i++)
                              MediaThumb(
                                media: d.media[i],
                                radius: 0,
                                memCacheWidth: 1200,
                                onTap: () => context.push('/viewer', extra: MediaViewerArgs(media: d.media, initialIndex: i)),
                              ),
                          ],
                        ),
                      ),
                actions: [
                  IconButton(
                    tooltip: 'Favori',
                    icon: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                    onPressed: () => ref.read(favoritesProvider(m.babyId).notifier).toggle(TargetKind.memory, m.id).catchError((Object e) {
                      if (context.mounted) showError(context, e);
                    }),
                  ),
                  if (canEdit)
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        switch (v) {
                          case 'edit':
                            context.push('/memory/${m.id}/edit');
                          case 'book':
                            await runWithProgress(context, () => ref.read(memoryRepositoryProvider).setIncludeInBook(m.id, !m.includeInBook));
                            ref.read(contentRevisionProvider.notifier).bump();
                          case 'delete':
                            await delete();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Düzenle')),
                        PopupMenuItem(value: 'book', child: Text(m.includeInBook ? 'Kitaptan çıkar' : 'Kitaba dahil et')),
                        const PopupMenuItem(value: 'delete', child: Text('Sil')),
                      ],
                    ),
                ],
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                sliver: SliverList.list(
                  children: [
                    Text(
                      [Dates.longWithWeekday(m.date), ?Dates.timeLabel(m.time)].join(' · '),
                      style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Text(m.title, style: theme.textTheme.headlineMedium),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Pill(label: m.category.label, icon: m.category.icon),
                        Pill(label: age == null ? 'Doğumdan önce' : '${baby.firstName} ${age.whileLabel}', color: theme.colorScheme.secondary),
                        if (fy.isBookCandidate(m.date))
                          Pill(
                            label: m.includeInBook ? 'İlk Yılım kitabında' : 'Kitap dışı',
                            icon: Icons.menu_book_rounded,
                            color: m.includeInBook ? AppColors.apricot : theme.colorScheme.outline,
                          ),
                      ],
                    ),
                    if (linked != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        color: AppColors.honey.withValues(alpha: 0.12),
                        child: ListTile(
                          leading: Text(linked.type.emoji ?? '⭐', style: const TextStyle(fontSize: 26)),
                          title: Text(linked.type.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: const Text('Bağlı kilometre taşı'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/milestone/${linked.milestone!.id}'),
                        ),
                      ),
                    ],
                    if (m.body?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: 18),
                      SelectableText(m.body!, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.6)),
                    ],
                    const SizedBox(height: 16),
                    Text('— $author', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    if (d.media.length > 1) ...[
                      const SizedBox(height: 20),
                      GridView.count(
                        crossAxisCount: 4,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        children: [
                          for (var i = 0; i < d.media.length; i++)
                            MediaThumb(
                              media: d.media[i],
                              radius: 10,
                              onTap: () => context.push('/viewer', extra: MediaViewerArgs(media: d.media, initialIndex: i)),
                            ),
                        ],
                      ),
                    ],
                    const Divider(height: 40),
                    CommentsSection(babyId: m.babyId, kind: TargetKind.memory, targetId: m.id),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
