import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/turkish.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../babies/domain/baby.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../application/book_providers.dart';
import '../data/book_generator.dart';
import '../data/book_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import 'book_generation.dart';

class BookHomeScreen extends ConsumerStatefulWidget {
  const BookHomeScreen({super.key});

  @override
  ConsumerState<BookHomeScreen> createState() => _BookHomeScreenState();
}

class _BookHomeScreenState extends ConsumerState<BookHomeScreen> {
  BookFormat _format = BookFormat.square21;

  Future<void> _create(Baby baby) async {
    final project = await runWithProgress(context, () async {
      final source = await ref.read(bookGeneratorProvider).loadSource(baby);
      final plan = const BookComposer().plan(source);
      return ref
          .read(bookRepositoryProvider)
          .create(
            babyId: baby.id,
            title: '${Turkish.genitive(baby.firstName)} İlk Yılı',
            subtitle: baby.fullName,
            format: _format,
            plan: plan,
          );
    }, message: 'İlk 365 günün içerikleri toplanıyor…');
    if (project != null && mounted) {
      ref.invalidate(bookProjectProvider(baby.id));
      context.push('/book/editor');
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(accessProvider(baby.id));
    final project = ref.watch(bookProjectProvider(baby.id));
    final today = Dates.today();
    final fy = baby.firstYear;
    final theme = Theme.of(context);
    final canCreate = access.can(AppPermission.createBook);

    return Scaffold(
      appBar: AppBar(title: const Text('İlk Yılım kitabı')),
      body: AsyncValueView<BookProject?>(
        value: project,
        onRetry: () => ref.invalidate(bookProjectProvider(baby.id)),
        data: (p) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Card(
              color: AppColors.apricot.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fy.isComplete(today)
                          ? '${baby.firstName} ilk yılını tamamladı 🎉'
                          : 'İlk yıl devam ediyor · ${fy.dayNumber(today) ?? 0}/365',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Kitap, ${Dates.long(fy.start)} – ${Dates.long(fy.end)} arasındaki anıları, fotoğrafları, ilkleri ve '
                      'aile mektuplarını kullanır. Geçmiş tarihli eklediğiniz anılar da dahildir. Arşiv 1 yaşından sonra da '
                      'büyümeye devam eder.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (!fy.isComplete(today)) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: fy.progress(today),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (p == null) ...[
              const SizedBox(height: 16),
              if (canCreate) ...[
                Text('Kitap ölçüsü', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                _FormatPicker(value: _format, onChanged: (f) => setState(() => _format = f)),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _create(baby),
                  icon: const Icon(Icons.auto_stories_rounded),
                  label: const Text('İlk Yılım Kitabını Oluştur'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Kapak, "Hoş geldin", doğum bilgileri, 12 ay, İlklerim, Ailemden Bana ve Bir Yaşındayım bölümleri otomatik hazırlanır; '
                  'sonra her şeyi düzenleyebilirsiniz.',
                  style: theme.textTheme.bodySmall,
                ),
              ] else
                const EmptyState(
                  icon: Icons.menu_book_outlined,
                  title: 'Kitap henüz oluşturulmadı',
                  message: 'Aile yöneticisi kitabı oluşturduğunda burada görünecek.',
                ),
            ] else ...[
              if (canCreate) _ProjectCard(baby: baby, project: p),
              _Exports(project: p, canDelete: access.isAdmin),
            ],
          ],
        ),
      ),
    );
  }
}

class _FormatPicker extends StatelessWidget {
  const _FormatPicker({required this.value, required this.onChanged});

  final BookFormat value;
  final ValueChanged<BookFormat> onChanged;

  @override
  Widget build(BuildContext context) => RadioGroup<BookFormat>(
    groupValue: value,
    onChanged: (v) => onChanged(v!),
    child: Column(
      children: [
        for (final f in BookFormat.values)
          RadioListTile<BookFormat>(
            value: f,
            contentPadding: EdgeInsets.zero,
            title: Text('${f.label} · ${f.sizeLabel}'),
            subtitle: Text(f.isSquare ? 'Fotoğraf kitabı baskısı için' : 'Evde yazdırmaya ve A4 baskıya uygun'),
          ),
      ],
    ),
  );
}

class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.baby, required this.project});

  final Baby baby;
  final BookProject project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sync = ref.watch(bookSyncPreviewProvider(baby.id)).value;
    final visiblePages = project.pages.where((p) => !p.isHidden).length;
    final items = project.pages.fold<int>(0, (n, p) => n + p.visibleItems.length);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(project.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                '${project.format.label} ${project.format.sizeLabel} · $visiblePages bölüm · $items içerik',
                style: theme.textTheme.bodyMedium,
              ),
              if (project.hasBeenGenerated)
                Text('Son sürüm: ${project.currentVersion}', style: theme.textTheme.bodySmall),
              if (sync != null && !sync.isEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.new_releases_outlined),
                      const SizedBox(width: 10),
                      Expanded(child: Text('İlk yıla ait ${sync.newItemCount} yeni içerik bulundu.')),
                      TextButton(
                        onPressed: () async {
                          await runWithProgress(
                            context,
                            () => ref.read(bookRepositoryProvider).applySync(project, sync),
                            success: 'Taslak güncellendi',
                          );
                          ref.invalidate(bookProjectProvider(baby.id));
                        },
                        child: const Text('Ekle'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/book/editor'),
                      icon: const Icon(Icons.edit_note_rounded),
                      label: const Text('Düzenle'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final res = await generateWithProgress(context, ref, project, baby, BookQuality.screen);
                        if (res != null && context.mounted) context.push('/book/view', extra: res.$1);
                      },
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('Önizle'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await publishBook(context, ref, project, baby);
                    ref.invalidate(bookProjectProvider(baby.id));
                    ref.invalidate(bookExportsProvider(project.id));
                  },
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: Text(
                    project.hasBeenGenerated
                        ? 'Kitabı güncelle (sürüm ${project.currentVersion + 1})'
                        : 'Baskıya hazır PDF oluştur',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Exports extends ConsumerWidget {
  const _Exports({required this.project, required this.canDelete});

  final BookProject project;
  final bool canDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exports = ref.watch(bookExportsProvider(project.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Oluşturulan sürümler', padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),
        AsyncValueView<List<BookExport>>(
          value: exports,
          onRetry: () => ref.invalidate(bookExportsProvider(project.id)),
          data: (list) => list.isEmpty
              ? const Padding(padding: EdgeInsets.all(8), child: Text('Henüz PDF oluşturulmadı.'))
              : Card(
                  child: Column(
                    children: [
                      for (final e in list)
                        ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.picture_as_pdf_outlined)),
                          title: Text('Sürüm ${e.version} · ${e.pageCount} sayfa'),
                          subtitle: Text('${e.createdLabel} · ${e.format.sizeLabel} · ${e.sizeLabel}'),
                          onTap: () async {
                            final file = await runWithProgress(context, () async {
                              final bytes = await ref.read(bookRepositoryProvider).download(e);
                              return ref.read(bookGeneratorProvider).saveExportLocally(e, bytes);
                            }, message: 'İndiriliyor…');
                            if (file != null && context.mounted) context.push('/book/view', extra: file);
                          },
                          trailing: canDelete
                              ? IconButton(
                                  tooltip: 'Sil',
                                  icon: const Icon(Icons.delete_outline_rounded),
                                  onPressed: () async {
                                    final ok = await confirm(
                                      context,
                                      title: 'Sürüm ${e.version} silinsin mi?',
                                      message: 'PDF dosyası kalıcı olarak silinir.',
                                      confirmLabel: 'Sil',
                                      destructive: true,
                                    );
                                    if (!ok || !context.mounted) return;
                                    await runWithProgress(
                                      context,
                                      () => ref.read(bookRepositoryProvider).deleteExport(e),
                                    );
                                    ref.invalidate(bookExportsProvider(project.id));
                                  },
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
