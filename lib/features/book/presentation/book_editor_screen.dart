import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../media/presentation/media_widgets.dart';
import '../application/book_providers.dart';
import '../data/book_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import 'book_gate.dart';
import '../../babies/presentation/route_baby.dart';

IconData pageIcon(BookPageType t) => switch (t) {
  BookPageType.cover => Icons.photo_album_rounded,
  BookPageType.welcome => Icons.waving_hand_rounded,
  BookPageType.birth => Icons.child_friendly_rounded,
  BookPageType.month => Icons.calendar_month_rounded,
  BookPageType.milestones => Icons.star_rounded,
  BookPageType.letters => Icons.mail_rounded,
  BookPageType.oneYear => Icons.cake_rounded,
  BookPageType.backCover => Icons.menu_book_rounded,
  BookPageType.custom => Icons.note_add_rounded,
};

/// Book editor: title, format, cover, back cover text, chapter order and
/// visibility. Chapter content is edited in [BookPageEditorScreen].
class BookEditorScreen extends ConsumerStatefulWidget {
  const BookEditorScreen({super.key, required this.babyId});

  final String babyId;

  @override
  ConsumerState<BookEditorScreen> createState() => _BookEditorScreenState();
}

class _BookEditorScreenState extends ConsumerState<BookEditorScreen> {
  List<BookPage>? _pages;
  BookProject? _source;

  Future<void> _editSettings(BookProject p, BookSource source) async {
    final title = TextEditingController(text: p.title);
    final subtitle = TextEditingController(text: p.subtitle);
    final back = TextEditingController(text: p.backCoverText);
    var format = p.format;
    var cover = p.coverMediaId;
    final fy = source.baby.firstYear;
    final photos =
        source.media
            .where(
              (m) => m.status == 'ready' && !m.isVideo && fy.isBookCandidate(m.takenOn, closeDate: source.closeDate),
            )
            .toList()
          ..sort((a, b) => b.takenOn.compareTo(a.takenOn));

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.9,
            builder: (ctx, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                Text('Kitap ayarları', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                  controller: title,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Başlık'),
                ),
                TextField(
                  controller: subtitle,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Alt başlık'),
                ),
                const SizedBox(height: 8),
                Text('Ölçü', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<BookFormat>(
                  segments: [for (final f in BookFormat.values) ButtonSegment(value: f, label: Text(f.sizeLabel))],
                  selected: {format},
                  onSelectionChanged: (s) => setLocal(() => format = s.first),
                ),
                const SizedBox(height: 16),
                Text('Kapak fotoğrafı', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (photos.isEmpty)
                  const Text('İlk yıla ait fotoğraf yok. Kapak sade bir tasarımla basılır.')
                else
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: photos.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final m = photos[i];
                        final selected = m.id == cover;
                        return GestureDetector(
                          onTap: () => setLocal(() => cover = m.id),
                          child: Container(
                            width: 96,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selected ? Theme.of(ctx).colorScheme.primary : Colors.transparent,
                                width: 3,
                              ),
                            ),
                            child: MediaThumb(media: m, radius: 11),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: back,
                  maxLength: 1000,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Arka kapak yazısı',
                    hintText: 'Boş bırakılırsa sıcak bir varsayılan metin kullanılır',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await runWithProgress(
      context,
      () => ref
          .read(bookRepositoryProvider)
          .updateProject(
            p.babyId,
            p.id,
            title: title.text.trim().isEmpty ? p.title : title.text.trim(),
            subtitle: subtitle.text.trim().isEmpty ? null : subtitle.text.trim(),
            clearSubtitle: subtitle.text.trim().isEmpty,
            format: format,
            coverMediaId: cover,
            backCoverText: back.text.trim(),
          ),
      success: 'Kaydedildi',
    );
    ref.invalidate(bookProjectProvider(p.babyId));
  }

  Future<void> _persistOrder(BookProject p, List<BookPage> pages) async {
    final updated = [for (var i = 0; i < pages.length; i++) pages[i].copyWith(sortOrder: i)];
    setState(() => _pages = updated);
    try {
      await ref.read(bookRepositoryProvider).savePages(p.babyId, updated);
    } catch (e) {
      if (mounted) showError(context, e);
      ref.invalidate(bookProjectProvider(p.babyId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(babyByIdProvider(widget.babyId));
    if (baby == null) return const RouteBabyMissing();
    final project = ref.watch(bookProjectProvider(baby.id));
    final source = ref.watch(bookSourceProvider(baby.id));
    final theme = Theme.of(context);

    final p = project.value;
    // Reset the optimistic local copy only when the server sends new data.
    if (p != null && !identical(p, _source)) {
      _source = p;
      _pages = p.pages;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kitabı düzenle'),
        actions: [
          if (p != null && source.hasValue)
            IconButton(
              tooltip: 'Kitap ayarları',
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => _editSettings(p, source.requireValue),
            ),
          if (p != null)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'sync' && source.hasValue) {
                  const composer = BookComposer();
                  final sync = composer.sync(p, composer.plan(source.requireValue));
                  if (sync.isEmpty) {
                    showSnack(context, 'Kitap zaten güncel.');
                    return;
                  }
                  await runWithProgress(
                    context,
                    () => ref.read(bookRepositoryProvider).applySync(p, sync),
                    success: '${sync.newItemCount} yeni içerik eklendi',
                  );
                  ref.invalidate(bookProjectProvider(baby.id));
                } else if (v == 'custom') {
                  final ctrl = TextEditingController();
                  final title = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Yeni sayfa'),
                      content: TextField(
                        controller: ctrl,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: 'Başlık'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Ekle')),
                      ],
                    ),
                  );
                  if (title == null || title.isEmpty || !context.mounted) return;
                  await runWithProgress(context, () => ref.read(bookRepositoryProvider).addCustomPage(p, title));
                  ref.invalidate(bookProjectProvider(baby.id));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'sync', child: Text('Yeni içerikleri ekle (taslağı yenile)')),
                PopupMenuItem(value: 'custom', child: Text('Özel sayfa ekle')),
              ],
            ),
        ],
      ),
      body: AsyncValueView<BookProject?>(
        value: project,
        onRetry: () => ref.invalidate(bookProjectProvider(baby.id)),
        data: (p) {
          if (p == null) return const EmptyState(icon: Icons.menu_book_outlined, title: 'Kitap bulunamadı');
          final pages = _pages ?? p.pages;
          final fixedTop = pages.where((x) => x.type == BookPageType.cover).toList();
          final fixedBottom = pages.where((x) => x.type == BookPageType.backCover).toList();
          final movable = pages.where((x) => x.type != BookPageType.cover && x.type != BookPageType.backCover).toList();
          Widget tile(BookPage page, {Widget? drag}) {
            final hidden = page.items.where((i) => i.isHidden).length;
            final visible = page.items.length - hidden;
            final subtitle = switch (page.type) {
              BookPageType.cover => 'Kapak fotoğrafı ve başlık · ayarlardan değiştirin',
              BookPageType.backCover => 'Arka kapak yazısı · ayarlardan değiştirin',
              BookPageType.month => () {
                final (from, to) = baby.firstYear.monthRange(page.monthIndex!);
                return '${Dates.dayMonth(from)} – ${Dates.dayMonth(to)} · $visible içerik${hidden > 0 ? ' ($hidden gizli)' : ''}';
              }(),
              _ => '$visible içerik${hidden > 0 ? ' ($hidden gizli)' : ''}',
            };
            return Card(
              key: ValueKey(page.id),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: page.isHidden ? 0.05 : 0.14),
                  child: Icon(
                    pageIcon(page.type),
                    color: page.isHidden ? theme.disabledColor : theme.colorScheme.primary,
                  ),
                ),
                title: Text(
                  page.title,
                  style: TextStyle(fontWeight: FontWeight.w800, color: page.isHidden ? theme.disabledColor : null),
                ),
                subtitle: Text(page.isHidden ? 'Kitapta gizli' : subtitle),
                onTap: page.type == BookPageType.cover || page.type == BookPageType.backCover
                    ? (source.hasValue ? () => _editSettings(p, source.requireValue) : null)
                    : () => context.push(bookPageRoute(p.babyId, page.id)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (page.type != BookPageType.cover && page.type != BookPageType.backCover)
                      IconButton(
                        tooltip: page.isHidden ? 'Göster' : 'Gizle',
                        icon: Icon(page.isHidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () async {
                          final updated = page.copyWith(isHidden: !page.isHidden);
                          setState(() => _pages = [for (final x in pages) x.id == page.id ? updated : x]);
                          try {
                            await ref.read(bookRepositoryProvider).savePages(p.babyId, [updated]);
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ?drag,
                  ],
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Bölümlerin sırasını sürükleyerek değiştirin, dokunarak içeriklerini düzenleyin.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              for (final page in fixedTop) tile(page),
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorderItem: (oldIndex, newIndex) {
                  final list = [...movable];
                  list.insert(newIndex, list.removeAt(oldIndex));
                  _persistOrder(p, [...fixedTop, ...list, ...fixedBottom]);
                },
                children: [
                  for (var i = 0; i < movable.length; i++)
                    tile(
                      movable[i],
                      drag: ReorderableDragStartListener(
                        index: i,
                        child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle_rounded)),
                      ),
                    ),
                ],
              ),
              for (final page in fixedBottom) tile(page),
            ],
          );
        },
      ),
    );
  }
}
