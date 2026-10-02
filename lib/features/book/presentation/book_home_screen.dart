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
import '../application/book_providers.dart';
import '../data/book_generator.dart';
import '../data/book_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import 'book_gate.dart';
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
    }, message: 'İlk yıl arşivinin içerikleri toplanıyor…');
    if (project != null && mounted) {
      ref.invalidate(bookProjectProvider(baby.id));
      context.push('/book/editor');
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    // The route gate guarantees an access value that allows viewing.
    final access = ref.watch(bookAccessProvider(baby.id)).value;
    final canCreate = access?.canEdit ?? false;
    final project = canCreate ? ref.watch(bookProjectProvider(baby.id)) : const AsyncData<BookProject?>(null);
    final today = Dates.today();
    final fy = baby.firstYear;
    final theme = Theme.of(context);

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
                _Versions(
                  babyId: baby.id,
                  emptyText: 'Anne veya Baba kitabı hazırlayıp sizinle paylaştığında burada görünecek.',
                ),
            ] else ...[
              _ProjectCard(baby: baby, project: p, rendererEnabled: access?.rendererEnabled ?? false),
              _Versions(babyId: baby.id, emptyText: 'Henüz resmî PDF oluşturulmadı.'),
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
  const _ProjectCard({required this.baby, required this.project, required this.rendererEnabled});

  final Baby baby;
  final BookProject project;
  final bool rendererEnabled;

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
                  onPressed: rendererEnabled
                      ? () async {
                          await publishBook(context, ref, baby);
                          ref.invalidate(bookProjectProvider(baby.id));
                          ref.invalidate(bookVersionsProvider(baby.id));
                        }
                      : null,
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: Text(
                    project.hasBeenGenerated
                        ? 'Kitabı güncelle (sürüm ${project.currentVersion + 1})'
                        : 'Baskıya hazır PDF oluştur',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                rendererEnabled
                    ? 'Resmî PDF, mühürlenmiş arşivden ve şu anki düzenlemelerinizden hazırlanır; sunucu doğruladıktan '
                          'sonra ailenizle paylaşılır.'
                    : 'Kitap oluşturma geçici olarak durduruldu. Düzenlemeleriniz korunuyor.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Versions extends ConsumerWidget {
  const _Versions({required this.babyId, required this.emptyText});

  final String babyId;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = ref.watch(bookVersionsProvider(babyId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Resmî sürümler', padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),
        AsyncValueView<List<BookVersion>>(
          value: versions,
          onRetry: () => ref.invalidate(bookVersionsProvider(babyId)),
          data: (list) => list.isEmpty
              ? Padding(padding: const EdgeInsets.all(8), child: Text(emptyText))
              : Card(
                  child: Column(
                    children: [
                      for (final v in list)
                        ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.picture_as_pdf_outlined)),
                          title: Text('Sürüm ${v.version} · ${v.pageCount} sayfa'),
                          subtitle: Text(
                            v.canDownload
                                ? '${v.createdLabel} · ${v.format.sizeLabel} · ${v.sizeLabel}'
                                : bookDownloadBlockText(v.downloadBlock),
                          ),
                          trailing: Icon(v.canDownload ? Icons.download_rounded : Icons.lock_outline_rounded),
                          onTap: () async {
                            if (!v.canDownload) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text(bookDownloadBlockText(v.downloadBlock))));
                              return;
                            }
                            final file = await runWithProgress(context, () async {
                              final bytes = await ref.read(bookRepositoryProvider).download(v);
                              return ref.read(bookGeneratorProvider).saveLocally(v.fileName, bytes);
                            }, message: 'İndiriliyor…');
                            if (file != null && context.mounted) context.push('/book/view', extra: file);
                          },
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
