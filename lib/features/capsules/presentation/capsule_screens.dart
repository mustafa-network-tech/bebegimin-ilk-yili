import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/content/content_revision.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/form_fields.dart';
import '../../../core/widgets/states.dart';
import '../../../core/widgets/storage_image.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../media/presentation/media_picker.dart';
import '../application/capsule_providers.dart';
import '../data/capsule_repository.dart';
import '../domain/time_capsule.dart';

/// Time capsules. Sealed ones only show the envelope: the backend does not
/// return their content before the opening date (RLS), so there is nothing
/// to hide on the client.
class CapsulesScreen extends ConsumerWidget {
  const CapsulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final capsules = ref.watch(capsulesProvider(baby.id));
    final access = ref.watch(accessProvider(baby.id));
    final today = Dates.today();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Zaman kapsülü')),
      floatingActionButton: access.can(AppPermission.writeLetter)
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/capsule/new'),
              icon: const Icon(Icons.hourglass_top_rounded),
              label: const Text('Kapsül bırak'),
            )
          : null,
      body: AsyncValueView<List<TimeCapsule>>(
        value: capsules,
        onRetry: () => ref.invalidate(capsulesProvider(baby.id)),
        data: (list) => list.isEmpty
            ? !access.can(AppPermission.writeLetter)
                  ? const EmptyState(icon: Icons.hourglass_empty_rounded, title: 'Henüz zaman kapsülü yok')
                  : EmptyState(
                      icon: Icons.hourglass_empty_rounded,
                      title: 'Geleceğe bir mesaj bırakın',
                      message:
                          '${baby.firstName} 5, 10 ya da 18 yaşına geldiğinde açılacak mesajlar yazın. Açılış gününe kadar kimse — siz dahil — içeriği göremez.',
                    )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final c = list[i];
                  final open = c.isOpen(today) && c.body != null;
                  return Card(
                    color: open ? null : theme.colorScheme.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                open ? Icons.drafts_rounded : Icons.lock_clock_rounded,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(c.title, style: theme.textTheme.titleMedium)),
                              if (access.canDeleteCapsule(c.authorId))
                                IconButton(
                                  tooltip: 'Sil',
                                  icon: const Icon(Icons.delete_outline_rounded),
                                  onPressed: () async {
                                    final ok = await confirm(
                                      context,
                                      title: 'Kapsül silinsin mi?',
                                      message: 'Mühürlü içerik de kalıcı olarak silinir.',
                                      confirmLabel: 'Sil',
                                      destructive: true,
                                    );
                                    if (!ok || !context.mounted) return;
                                    await runWithProgress(context, () => ref.read(capsuleRepositoryProvider).delete(c));
                                    ref.read(contentRevisionProvider.notifier).bump();
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${c.signature} · ${Dates.short(c.createdAt.toLocal())} tarihinde bıraktı',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 10),
                          if (!open) ...[
                            Text(
                              '${c.occasion.label} açılacak: ${Dates.long(c.openOn)}',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(c.remainingLabel(today), style: theme.textTheme.bodySmall),
                            if (c.hasPhoto)
                              const Padding(padding: EdgeInsets.only(top: 6), child: Text('📷 Bir fotoğraf içeriyor')),
                          ] else ...[
                            Text(
                              c.body!,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontFamily: 'Lora',
                                fontStyle: FontStyle.italic,
                                height: 1.6,
                              ),
                            ),
                            if (c.hasPhoto) ...[
                              const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: AspectRatio(
                                  aspectRatio: 4 / 3,
                                  child: StorageImage(bucket: Buckets.babyMedia, path: c.photoPath),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class CapsuleFormScreen extends ConsumerStatefulWidget {
  const CapsuleFormScreen({super.key, this.babyId});

  /// Baby pinned by the route; `null` uses the active selection.
  final String? babyId;

  @override
  ConsumerState<CapsuleFormScreen> createState() => _CapsuleFormScreenState();
}

class _CapsuleFormScreenState extends ConsumerState<CapsuleFormScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  CapsuleOccasion _occasion = CapsuleOccasion.age18;
  DateTime? _customDate;
  File? _photo;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  DateTime? _openOn(DateTime birth) => _occasion == CapsuleOccasion.custom ? _customDate : _occasion.openDateFor(birth);

  Future<void> _save(String babyId, DateTime birth) async {
    if (!_form.currentState!.validate()) return;
    final openOn = _openOn(birth);
    if (openOn == null || !openOn.isAfter(Dates.today())) {
      showSnack(context, 'Açılış tarihi gelecekte olmalı.', error: true);
      return;
    }
    final ok = await confirm(
      context,
      title: 'Kapsül mühürlensin mi?',
      message: 'Mesaj ${Dates.long(openOn)} tarihine kadar hiç kimse tarafından okunamaz ve düzenlenemez.',
      confirmLabel: 'Mühürle',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(capsuleRepositoryProvider)
          .create(
            babyId: babyId,
            title: _title.text,
            body: _body.text,
            openOn: openOn,
            occasion: _occasion,
            photoJpeg: _photo,
          );
      ref.read(contentRevisionProvider.notifier).bump();
      if (mounted) {
        showSnack(context, 'Zaman kapsülü mühürlendi ⏳');
        context.pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = widget.babyId == null ? ref.watch(activeBabyProvider) : ref.watch(babyByIdProvider(widget.babyId!));
    if (baby == null) return const Scaffold(body: LoadingView());
    final openOn = _openOn(baby.birthDate);
    return Scaffold(
      appBar: AppBar(title: const Text('Yeni zaman kapsülü')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Text('Ne zaman açılsın?', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in CapsuleOccasion.values)
                  ChoiceChip(
                    label: Text(o.label),
                    selected: _occasion == o,
                    onSelected: (_) => setState(() => _occasion = o),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_occasion == CapsuleOccasion.custom)
              DateField(
                label: 'Açılış tarihi',
                value: _customDate,
                firstDate: Dates.addDays(Dates.today(), 1),
                lastDate: Dates.addYears(Dates.today(), 99),
                onChanged: (d) => setState(() => _customDate = d),
              )
            else if (openOn != null)
              Text('Açılış: ${Dates.longWithWeekday(openOn)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Zarfın üzerine ne yazalım?',
                hintText: '18. yaş gününde aç',
              ),
              validator: (v) => Validators.required(v, field: 'Başlık') ?? Validators.maxLength(v, 140),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _body,
              minLines: 8,
              maxLines: 25,
              maxLength: 20000,
              style: const TextStyle(fontFamily: 'Lora', fontSize: 17, height: 1.6),
              decoration: const InputDecoration(alignLabelWithHint: true, hintText: 'Bu mesajı okuduğunda…'),
              validator: (v) => Validators.required(v, field: 'Mesaj'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final f = await pickCompressedPhoto(context, shortSide: 1600);
                if (f != null) setState(() => _photo = f);
              },
              icon: Icon(_photo == null ? Icons.add_photo_alternate_outlined : Icons.check_circle_outline),
              label: Text(_photo == null ? 'Fotoğraf ekle (isteğe bağlı)' : 'Fotoğraf eklendi'),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : () => _save(baby.id, baby.birthDate),
              icon: const Icon(Icons.lock_rounded),
              label: const Text('Mühürle'),
            ),
          ],
        ),
      ),
    );
  }
}
