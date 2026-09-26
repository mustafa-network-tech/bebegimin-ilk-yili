import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/turkish.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/form_fields.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../media/application/media_providers.dart';
import '../../media/data/upload_queue.dart';
import '../../media/domain/media_item.dart';
import '../../media/presentation/media_picker.dart';
import '../../media/presentation/media_widgets.dart';
import '../application/letter_providers.dart';
import '../data/letter_repository.dart';
import '../domain/letter.dart';

/// "Ailemden Bana" – letters from the family to the baby.
class LettersScreen extends ConsumerWidget {
  const LettersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final letters = ref.watch(lettersProvider(baby.id));
    final access = ref.watch(accessProvider(baby.id));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ailemden Bana')),
      floatingActionButton: access.can(AppPermission.writeLetter)
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/letter/new'),
              icon: const Icon(Icons.edit_rounded),
              label: const Text('Mektup yaz'),
            )
          : null,
      body: AsyncValueView<List<Letter>>(
        value: letters,
        onRetry: () => ref.invalidate(lettersProvider(baby.id)),
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.mail_outline_rounded,
                title: 'İlk mektubu siz yazın',
                message: '${Turkish.dative(baby.firstName)} yıllar sonra okuyacağı bir mektup bırakın.',
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final l = list[i];
                  return Card(
                    color: AppColors.lavender.withValues(alpha: 0.10),
                    child: InkWell(
                      onTap: () => context.push('/letter/${l.id}'),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.mail_rounded, color: AppColors.lavender),
                                const SizedBox(width: 8),
                                Expanded(child: Text(l.signature, style: theme.textTheme.labelLarge)),
                                Text(Dates.short(l.writtenOn), style: theme.textTheme.labelMedium),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (l.title?.isNotEmpty ?? false)
                              Text(l.title!, style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'Lora')),
                            const SizedBox(height: 4),
                            Text(
                              l.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'Lora',
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class LetterFormScreen extends ConsumerStatefulWidget {
  const LetterFormScreen({super.key, this.letterId});

  final String? letterId;

  @override
  ConsumerState<LetterFormScreen> createState() => _LetterFormScreenState();
}

class _LetterFormScreenState extends ConsumerState<LetterFormScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  DateTime _date = Dates.today();
  bool _include = true;
  PickedMedia? _photo;
  bool _busy = false;
  bool _loaded = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save(String babyId) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(letterRepositoryProvider);
      final letter = widget.letterId == null
          ? await repo.create(
              babyId: babyId,
              title: _title.text,
              body: _body.text,
              writtenOn: _date,
              includeInBook: _include,
            )
          : await repo.update(
              widget.letterId!,
              title: _title.text,
              body: _body.text,
              writtenOn: _date,
              includeInBook: _include,
            );
      if (_photo != null) {
        await ref
            .read(uploadQueueProvider.notifier)
            .enqueue(babyId: babyId, files: [_photo!], takenOn: _date, letterId: letter.id);
      }
      ref.read(contentRevisionProvider.notifier).bump();
      if (!mounted) return;
      showSnack(context, 'Mektubunuz kaydedildi 💌');
      widget.letterId == null ? context.pushReplacement('/letter/${letter.id}') : context.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    if (widget.letterId != null && !_loaded) {
      final l = ref.watch(letterDetailProvider(widget.letterId!)).value;
      if (l == null) return Scaffold(appBar: AppBar(), body: const LoadingView());
      _loaded = true;
      _title.text = l.title ?? '';
      _body.text = l.body;
      _date = l.writtenOn;
      _include = l.includeInBook;
    }
    final access = ref.watch(accessProvider(baby.id));
    return Scaffold(
      appBar: AppBar(title: Text('${Turkish.dative(baby.firstName)} mektup')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Başlık (isteğe bağlı)', hintText: 'Sevgili kızım'),
              validator: (v) => Validators.maxLength(v, 140),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _body,
              minLines: 10,
              maxLines: 30,
              maxLength: 20000,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontFamily: 'Lora', fontSize: 17, height: 1.6),
              decoration: const InputDecoration(
                alignLabelWithHint: true,
                hintText: 'Bugün seni ilk kez kucağıma aldım…',
              ),
              validator: (v) => Validators.required(v, field: 'Mektup'),
            ),
            DateField(
              label: 'Tarih',
              value: _date,
              firstDate: Dates.addDays(baby.birthDate, -300),
              lastDate: Dates.today(),
              onChanged: (d) => setState(() => _date = d),
            ),
            if (widget.letterId == null && access.can(AppPermission.addPhoto)) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await MediaPicker.choose(context, videos: false);
                  if (p.isNotEmpty) setState(() => _photo = p.first);
                },
                icon: Icon(_photo == null ? Icons.add_photo_alternate_outlined : Icons.check_circle_outline),
                label: Text(_photo == null ? 'Fotoğraf ekle (isteğe bağlı)' : 'Fotoğraf seçildi'),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _include,
              onChanged: (v) => setState(() => _include = v),
              title: const Text('İlk Yılım kitabında kullanılabilir'),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy ? null : () => _save(baby.id), child: const Text('Kaydet')),
          ],
        ),
      ),
    );
  }
}

class LetterDetailScreen extends ConsumerWidget {
  const LetterDetailScreen({super.key, required this.letterId});

  final String letterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final letter = ref.watch(letterDetailProvider(letterId));
    final media = ref.watch(parentMediaProvider(('letter', letterId))).value ?? const <MediaItem>[];
    final theme = Theme.of(context);
    final l = letter.value;
    final access = l == null ? null : ref.watch(accessProvider(l.babyId));
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (l != null && (access?.canEditLetter(l.authorId) ?? false))
            IconButton(
              tooltip: 'Düzenle',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/letter/$letterId/edit'),
            ),
          if (l != null && (access?.canDeleteLetter(l.authorId) ?? false))
            IconButton(
              tooltip: 'Sil',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Mektup silinsin mi?',
                  message: 'Bu işlem geri alınamaz.',
                  confirmLabel: 'Sil',
                  destructive: true,
                );
                if (!ok || !context.mounted) return;
                final done = await runWithProgress(context, () async {
                  await ref.read(letterRepositoryProvider).delete(letterId, media);
                  return true;
                });
                if (done == true && context.mounted) {
                  ref.read(contentRevisionProvider.notifier).bump();
                  context.pop();
                }
              },
            ),
        ],
      ),
      body: AsyncValueView<Letter?>(
        value: letter,
        onRetry: () => ref.invalidate(letterDetailProvider(letterId)),
        data: (l) => l == null
            ? const EmptyState(icon: Icons.search_off_rounded, title: 'Mektup bulunamadı')
            : ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
                children: [
                  Text(Dates.longWithWeekday(l.writtenOn), style: theme.textTheme.labelLarge),
                  const SizedBox(height: 16),
                  if (l.title?.isNotEmpty ?? false) ...[
                    Text(l.title!, style: theme.textTheme.headlineMedium),
                    const SizedBox(height: 16),
                  ],
                  SelectableText(
                    l.body,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontFamily: 'Lora',
                      fontSize: 18,
                      height: 1.7,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text('— ${l.signature}', style: theme.textTheme.titleMedium),
                  ),
                  if (media.isNotEmpty) ...[const SizedBox(height: 24), MediaCollage(media: media, height: 260)],
                ],
              ),
      ),
    );
  }
}
