import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/signed_urls.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/form_fields.dart';
import '../../../core/widgets/storage_image.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../family/domain/relation.dart';
import '../../media/presentation/media_picker.dart';
import '../application/baby_providers.dart';
import '../data/baby_repository.dart';
import '../domain/baby.dart';

/// Create a baby (caller becomes admin) or edit an existing baby profile.
class BabyFormScreen extends ConsumerStatefulWidget {
  const BabyFormScreen({super.key, this.babyId});

  final String? babyId;

  @override
  ConsumerState<BabyFormScreen> createState() => _BabyFormScreenState();
}

class _BabyFormScreenState extends ConsumerState<BabyFormScreen> {
  final _form = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _place = TextEditingController();
  final _weight = TextEditingController();
  final _length = TextEditingController();
  final _story = TextEditingController();
  final _relationLabel = TextEditingController();
  DateTime? _birthDate;
  TimeOfDay? _birthTime;
  Relation _relation = Relation.anne;
  bool _busy = false;
  Baby? _baby;

  bool get _isEdit => widget.babyId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final b = (ref.read(babiesProvider).value ?? const <Baby>[]).firstWhereOrNull((b) => b.id == widget.babyId);
      if (b != null) _fill(b);
    }
  }

  void _fill(Baby b) {
    _baby = b;
    _first.text = b.firstName;
    _last.text = b.lastName ?? '';
    _place.text = b.birthPlace ?? '';
    _weight.text = b.birthWeightGrams?.toString() ?? '';
    _length.text = b.birthLengthCm?.toString().replaceAll('.', ',') ?? '';
    _story.text = b.story ?? '';
    _birthDate = b.birthDate;
    _birthTime = parseSqlTime(b.birthTime);
  }

  @override
  void dispose() {
    for (final c in [_first, _last, _place, _weight, _length, _story, _relationLabel]) {
      c.dispose();
    }
    super.dispose();
  }

  BabyInput _input() => BabyInput(
    firstName: _first.text,
    lastName: _last.text,
    birthDate: _birthDate!,
    birthTime: _birthTime == null
        ? null
        : '${_birthTime!.hour.toString().padLeft(2, '0')}:${_birthTime!.minute.toString().padLeft(2, '0')}',
    birthPlace: _place.text,
    birthWeightGrams: int.tryParse(_weight.text.trim()),
    birthLengthCm: double.tryParse(_length.text.trim().replaceAll(',', '.')),
    story: _story.text,
  );

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_birthDate == null) {
      showSnack(context, 'Doğum tarihini seçin.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(babyRepositoryProvider);
      if (_isEdit) {
        await repo.update(widget.babyId!, _input());
        ref.invalidate(babiesProvider);
        if (mounted) {
          showSnack(context, 'Kaydedildi');
          context.pop();
        }
      } else {
        final baby = await repo.create(
          _input(),
          relation: _relation,
          relationLabel: _relation == Relation.diger ? _relationLabel.text : null,
        );
        await ref.read(activeBabyIdProvider.notifier).select(baby.id);
        ref.invalidate(babiesProvider);
        if (mounted) {
          showSnack(context, '${baby.firstName} için arşiv hazır 🤍');
          context.go('/home');
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImage({required bool cover}) async {
    final baby = _baby;
    if (baby == null) return;
    final file = await pickCompressedPhoto(context, shortSide: cover ? 1600 : 800);
    if (file == null || !mounted) return;
    await runWithProgress(context, () async {
      await ref.read(babyRepositoryProvider).uploadImage(baby, file, cover: cover);
      ref.invalidate(babiesProvider);
      final updated = (await ref.read(babiesProvider.future)).firstWhereOrNull((b) => b.id == baby.id);
      if (updated != null && mounted) setState(() => _baby = updated);
    }, success: cover ? 'Kapak fotoğrafı güncellendi' : 'Profil fotoğrafı güncellendi');
  }

  Future<void> _delete() async {
    final baby = _baby!;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${baby.firstName} kalıcı olarak silinsin mi?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tüm anılar, fotoğraflar, videolar, mektuplar, kitaplar ve aile üyelikleri geri alınamaz şekilde silinir.',
            ),
            const SizedBox(height: 12),
            Text('Onaylamak için "${baby.firstName}" yazın:'),
            TextField(controller: ctrl, autofocus: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim() == baby.firstName),
            child: const Text('Kalıcı olarak sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await runWithProgress(context, () async {
      await ref.read(babyRepositoryProvider).delete(baby.id);
      return true;
    }, message: 'Siliniyor…');
    if (done == true && mounted) {
      await ref.read(activeBabyIdProvider.notifier).select(null);
      ref.invalidate(babiesProvider);
      if (mounted) context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = _baby;
    final access = baby == null ? null : ref.watch(accessProvider(baby.id));
    final today = Dates.today();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Bebek profili' : 'Yeni bebek'),
        actions: [
          if (_isEdit && (access?.isAdmin ?? false))
            IconButton(tooltip: 'Sil', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (baby != null && (access?.can(AppPermission.manageBaby) ?? false)) ...[
              _ImagesEditor(
                baby: baby,
                onAvatar: () => _pickImage(cover: false),
                onCover: () => _pickImage(cover: true),
              ),
              const SizedBox(height: 20),
            ],
            TextFormField(
              controller: _first,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Adı *'),
              validator: (v) => Validators.required(v, field: 'Ad') ?? Validators.maxLength(v, 60),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _last,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Soyadı (isteğe bağlı)'),
              validator: (v) => Validators.maxLength(v, 60),
            ),
            const SizedBox(height: 14),
            DateField(
              label: 'Doğum tarihi *',
              value: _birthDate,
              firstDate: DateTime(today.year - 18),
              lastDate: today,
              icon: Icons.cake_outlined,
              onChanged: (d) => setState(() => _birthDate = d),
            ),
            const SizedBox(height: 14),
            TimeField(label: 'Doğum saati', value: _birthTime, onChanged: (t) => setState(() => _birthTime = t)),
            const SizedBox(height: 14),
            TextFormField(
              controller: _place,
              decoration: const InputDecoration(labelText: 'Doğum yeri', prefixIcon: Icon(Icons.place_outlined)),
              validator: (v) => Validators.maxLength(v, 120),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _weight,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Doğum kilosu', suffixText: 'gram'),
                    validator: (v) {
                      if (v == null || v.isEmpty) return null;
                      final g = int.tryParse(v);
                      return (g == null || g < 200 || g > 8000) ? '200–8000 g' : null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _length,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Doğum boyu', suffixText: 'cm'),
                    validator: (v) {
                      if (v == null || v.isEmpty) return null;
                      final c = double.tryParse(v.replaceAll(',', '.'));
                      return (c == null || c < 20 || c > 70) ? '20–70 cm' : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _story,
              minLines: 3,
              maxLines: 6,
              maxLength: 4000,
              decoration: const InputDecoration(
                labelText: 'Kısa hikâye / not',
                alignLabelWithHint: true,
                hintText: 'Doğum hikâyeniz, ismin anlamı…',
              ),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 8),
              Text('Bebeğe yakınlığınız', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in Relation.values)
                    ChoiceChip(
                      label: Text(r.label),
                      selected: _relation == r,
                      onSelected: (_) => setState(() => _relation = r),
                    ),
                ],
              ),
              if (_relation == Relation.diger) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _relationLabel,
                  decoration: const InputDecoration(labelText: 'Yakınlık (ör. Vasi, Bakıcı)'),
                  validator: (v) => Validators.required(v, field: 'Yakınlık'),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Bebeği oluşturan kişi ailenin yöneticisi olur. Diğer aile üyelerini daha sonra davet edebilirsiniz.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _save, child: Text(_isEdit ? 'Kaydet' : 'Bebek profilini oluştur')),
          ],
        ),
      ),
    );
  }
}

class _ImagesEditor extends StatelessWidget {
  const _ImagesEditor({required this.baby, required this.onAvatar, required this.onCover});

  final Baby baby;
  final VoidCallback onAvatar;
  final VoidCallback onCover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 190,
      child: Stack(
        children: [
          Positioned.fill(
            bottom: 40,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Material(
                color: scheme.surfaceContainerHigh,
                child: InkWell(
                  onTap: onCover,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (baby.coverPath != null) StorageImage(bucket: Buckets.babyMedia, path: baby.coverPath),
                      const Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: Chip(avatar: Icon(Icons.edit_outlined, size: 16), label: Text('Kapak')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            bottom: 0,
            child: GestureDetector(
              onTap: onAvatar,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 4),
                ),
                child: ClipOval(
                  child: baby.avatarPath == null
                      ? Container(
                          color: scheme.primaryContainer,
                          child: Icon(Icons.add_a_photo_outlined, color: scheme.primary),
                        )
                      : StorageImage(bucket: Buckets.babyMedia, path: baby.avatarPath),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
