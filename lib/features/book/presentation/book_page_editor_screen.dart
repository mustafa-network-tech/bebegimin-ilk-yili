import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/book_providers.dart';
import '../data/book_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import 'book_item_tile.dart';

/// Edit one chapter: title, note, item order, hide/show, captions and
/// adding content from the first-year archive.
class BookPageEditorScreen extends ConsumerStatefulWidget {
  const BookPageEditorScreen({super.key, required this.pageId});

  final String pageId;

  @override
  ConsumerState<BookPageEditorScreen> createState() => _BookPageEditorScreenState();
}

class _BookPageEditorScreenState extends ConsumerState<BookPageEditorScreen> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  List<BookItem>? _items;
  bool _dirtyText = false;
  bool _initialised = false;
  BookPage? _sourcePage;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveText(BookPage page, String babyId) async {
    await runWithProgress(
      context,
      () => ref.read(bookRepositoryProvider).savePages(babyId, [
        page.copyWith(
          title: _title.text.trim().isEmpty ? page.title : _title.text.trim(),
          body: _note.text.trim(),
          clearBody: _note.text.trim().isEmpty,
        ),
      ]),
      success: 'Kaydedildi',
    );
    setState(() => _dirtyText = false);
    ref.invalidate(bookProjectProvider(babyId));
  }

  Future<void> _saveItems(String babyId, List<BookItem> items) async {
    setState(() => _items = items);
    try {
      await ref.read(bookRepositoryProvider).saveItems(babyId, items);
    } catch (e) {
      if (mounted) showError(context, e);
      ref.invalidate(bookProjectProvider(babyId));
    }
  }

  /// Candidates that are not on this page yet.
  List<PlannedItem> _candidates(BookPage page, BookSource src, Set<String> onPage) {
    final fy = src.baby.firstYear;
    const composer = BookComposer();
    bool fits(DateTime d) {
      final slot = composer.slotForDate(fy, d, closeDate: src.closeDate);
      return switch (page.type) {
        BookPageType.month => slot == 'month:${page.monthIndex}',
        BookPageType.welcome || BookPageType.birth || BookPageType.oneYear => slot == page.type.key,
        _ => fy.isBookCandidate(d, closeDate: src.closeDate),
      };
    }

    final result = <PlannedItem>[
      for (final m in src.memories)
        if (!onPage.contains(m.id) && fits(m.date)) PlannedItem(type: BookItemType.memory, refId: m.id, date: m.date),
      for (final m in src.media)
        if (!onPage.contains(m.id) && m.status == 'ready' && (!m.isVideo || m.thumbPath != null) && fits(m.takenOn))
          PlannedItem(type: BookItemType.media, refId: m.id, date: m.takenOn),
      if (page.type == BookPageType.milestones || page.type == BookPageType.custom)
        for (final m in src.milestones)
          if (!onPage.contains(m.id) && fy.isBookCandidate(m.achievedOn, closeDate: src.closeDate))
            PlannedItem(type: BookItemType.milestone, refId: m.id, date: m.achievedOn),
      // letters may come from any date (family messages)
      if (page.type == BookPageType.letters || page.type == BookPageType.custom)
        for (final l in src.letters)
          if (!onPage.contains(l.id)) PlannedItem(type: BookItemType.letter, refId: l.id, date: l.writtenOn),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  Future<void> _add(BookPage page, BookSource src, String babyId, List<BookItem> items) async {
    final candidates = _candidates(page, src, {for (final i in items) i.refId});
    if (candidates.isEmpty) {
      showSnack(context, 'Bu bölüme eklenebilecek başka içerik yok.');
      return;
    }
    final selected = <String>{};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (ctx, scroll) => Column(
            children: [
              ListTile(
                title: const Text('İçerik ekle', style: TextStyle(fontWeight: FontWeight.w800)),
                trailing: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Ekle (${selected.length})'),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: candidates.length,
                  itemBuilder: (_, i) {
                    final c = candidates[i];
                    final info = BookItemInfo.of(src, c.type, c.refId);
                    return CheckboxListTile(
                      value: selected.contains(c.refId),
                      onChanged: (v) => setLocal(() => v == true ? selected.add(c.refId) : selected.remove(c.refId)),
                      secondary: BookItemLeading(source: src, type: c.type, refId: c.refId),
                      title: Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(info.subtitle),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || selected.isEmpty || !mounted) return;
    final start = items.fold<int>(0, (m, i) => i.sortOrder > m ? i.sortOrder : m) + 1;
    await runWithProgress(
      context,
      () => ref
          .read(bookRepositoryProvider)
          .addItems(babyId, page.id, candidates.where((c) => selected.contains(c.refId)).toList(), start),
      success: '${selected.length} içerik eklendi',
    );
    ref.invalidate(bookProjectProvider(babyId));
  }

  Future<void> _editCaption(String babyId, BookItem item, List<BookItem> items) async {
    final ctrl = TextEditingController(text: item.caption);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kitaptaki açıklama'),
        content: TextField(
          controller: ctrl,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Boş bırakılırsa fotoğrafın kendi açıklaması kullanılır'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Kaydet')),
        ],
      ),
    );
    if (res == null) return;
    await _saveItems(babyId, [for (final i in items) i.id == item.id ? i.copyWith(caption: res.trim()) : i]);
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final project = ref.watch(bookProjectProvider(baby.id)).value;
    final source = ref.watch(bookSourceProvider(baby.id));
    final page = project?.pages.firstWhereOrNull((p) => p.id == widget.pageId);
    if (page == null || !source.hasValue) {
      return Scaffold(
        appBar: AppBar(),
        body: source.hasError
            ? ErrorView(error: source.error!, onRetry: () => ref.invalidate(bookSourceProvider(baby.id)))
            : const LoadingView(),
      );
    }
    if (!_initialised) {
      _initialised = true;
      _title.text = page.title;
      _note.text = page.body ?? '';
    }
    if (!identical(page, _sourcePage)) {
      _sourcePage = page;
      _items = page.items;
    }
    final src = source.requireValue;
    final items = _items ?? page.items;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(page.title),
        actions: [if (_dirtyText) TextButton(onPressed: () => _saveText(page, baby.id), child: const Text('Kaydet'))],
      ),
      floatingActionButton: page.type.holdsContent
          ? FloatingActionButton.extended(
              onPressed: () => _add(page, src, baby.id, items),
              icon: const Icon(Icons.add_rounded),
              label: const Text('İçerik ekle'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 100),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                TextField(
                  controller: _title,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Bölüm başlığı'),
                  onChanged: (_) => setState(() => _dirtyText = true),
                ),
                TextField(
                  controller: _note,
                  maxLength: 4000,
                  minLines: 2,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: page.type == BookPageType.month ? 'Bu ayın notu (aylık özet)' : 'Bölüm notu',
                    alignLabelWithHint: true,
                    hintText: page.type == BookPageType.month ? 'Bu ay neler öğrendin, neler sevdin…' : null,
                  ),
                  onChanged: (_) => setState(() => _dirtyText = true),
                ),
                if (page.type == BookPageType.month)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(() {
                      final (from, to) = baby.firstYear.monthRange(page.monthIndex!);
                      return '${Dates.long(from)} – ${Dates.long(to)} · otomatik özet PDF\'e eklenir';
                    }(), style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Bu bölümde içerik yok. "İçerik ekle" ile arşivden seçebilirsiniz.',
                textAlign: TextAlign.center,
              ),
            ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (oldIndex, newIndex) {
              final list = [...items];
              list.insert(newIndex, list.removeAt(oldIndex));
              _saveItems(baby.id, [for (var i = 0; i < list.length; i++) list[i].copyWith(sortOrder: i)]);
            },
            children: [
              for (var i = 0; i < items.length; i++)
                Builder(
                  key: ValueKey(items[i].id),
                  builder: (context) {
                    final item = items[i];
                    final info = BookItemInfo.of(src, item.type, item.refId);
                    return Opacity(
                      opacity: item.isHidden ? 0.45 : 1,
                      child: ListTile(
                        leading: BookItemLeading(source: src, type: item.type, refId: item.refId),
                        title: Text(
                          item.caption?.isNotEmpty ?? false ? item.caption! : info.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(item.isHidden ? 'Kitapta gösterilmiyor' : info.subtitle),
                        onTap: item.type == BookItemType.media ? () => _editCaption(baby.id, item, items) : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: item.isHidden ? 'Kitaba ekle' : 'Kitaptan çıkar',
                              icon: Icon(
                                item.isHidden ? Icons.add_circle_outline_rounded : Icons.remove_circle_outline_rounded,
                              ),
                              onPressed: () => _saveItems(baby.id, [
                                for (final x in items) x.id == item.id ? x.copyWith(isHidden: !x.isHidden) : x,
                              ]),
                            ),
                            ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle_rounded)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
          if (page.type == BookPageType.custom) ...[
            const SizedBox(height: 24),
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                onPressed: () async {
                  final ok = await confirm(
                    context,
                    title: 'Sayfa silinsin mi?',
                    message: 'Yalnızca kitaptaki sayfa silinir, anılar arşivde kalır.',
                    confirmLabel: 'Sil',
                    destructive: true,
                  );
                  if (!ok || !context.mounted) return;
                  await runWithProgress(context, () => ref.read(bookRepositoryProvider).deletePage(page.id));
                  ref.invalidate(bookProjectProvider(baby.id));
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Sayfayı sil'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
