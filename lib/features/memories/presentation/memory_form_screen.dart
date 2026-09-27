import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/content/content_route.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/form_fields.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../babies/domain/baby.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../media/data/media_repository.dart';
import '../../media/data/upload_queue.dart';
import '../../media/domain/media_item.dart';
import '../../media/presentation/media_picker.dart';
import '../../media/presentation/media_widgets.dart';
import '../../milestones/application/milestone_providers.dart';
import '../application/memory_providers.dart';
import '../data/memory_repository.dart';
import '../domain/memory.dart';

/// Create / edit a memory. Any past date can be chosen – a first-year date
/// makes the memory a candidate for the "İlk Yılım" book even if it is
/// added years later.
class MemoryFormScreen extends ConsumerStatefulWidget {
  const MemoryFormScreen({
    super.key,
    this.babyId,
    this.memoryId,
    this.initialCategory,
    this.initialDate,
    this.autoPick,
  });

  final String? babyId;
  final String? memoryId;
  final MemoryCategory? initialCategory;
  final DateTime? initialDate;

  /// "photo" / "video": open the picker immediately.
  final String? autoPick;

  @override
  ConsumerState<MemoryFormScreen> createState() => _MemoryFormScreenState();
}

class _MemoryFormScreenState extends ConsumerState<MemoryFormScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  late DateTime _date = widget.initialDate ?? Dates.today();
  TimeOfDay? _time;
  late MemoryCategory _category = widget.initialCategory ?? MemoryCategory.moment;
  String? _milestoneId;
  bool _includeInBook = true;
  final List<PickedMedia> _newMedia = [];
  List<MediaItem> _existing = const [];
  final Set<String> _removed = {};
  bool _busy = false;
  bool _loaded = false;

  bool get _isEdit => widget.memoryId != null;

  @override
  void initState() {
    super.initState();
    if (widget.autoPick != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _addMedia(videos: widget.autoPick == 'video', photos: widget.autoPick != 'video'),
      );
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _fill(MemoryDetail d) {
    if (_loaded) return;
    _loaded = true;
    final m = d.memory;
    _title.text = m.title;
    _body.text = m.body ?? '';
    _date = m.date;
    _time = parseSqlTime(m.time);
    _category = m.category;
    _milestoneId = m.milestoneId;
    _includeInBook = m.includeInBook;
    _existing = d.media;
  }

  Future<void> _addMedia({bool photos = true, bool videos = true}) async {
    final access = ref.read(activeAccessProvider);
    final picked = await MediaPicker.choose(
      context,
      photos: photos && access.can(AppPermission.addPhoto),
      videos: videos && access.can(AppPermission.addVideo),
    );
    if (picked.isEmpty) return;
    setState(() {
      _newMedia.addAll(picked);
      if (_title.text.isEmpty) {
        _title.text = picked.every((p) => p.kind == MediaKind.video) ? 'Yeni bir video' : 'Yeni fotoğraflar';
      }
    });
  }

  Future<void> _save(Baby baby) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final draft = MemoryDraft(
        babyId: baby.id,
        title: _title.text,
        body: _body.text,
        date: _date,
        time: _time,
        category: _category,
        milestoneId: _milestoneId,
        includeInBook: _includeInBook,
      );
      final repo = ref.read(memoryRepositoryProvider);
      final memory = _isEdit ? await repo.update(baby.id, widget.memoryId!, draft) : await repo.create(draft);

      for (final m in _existing.where((m) => _removed.contains(m.id))) {
        await ref.read(mediaRepositoryProvider).delete(m);
      }
      if (_newMedia.isNotEmpty) {
        await ref
            .read(uploadQueueProvider.notifier)
            .enqueue(babyId: baby.id, files: List.of(_newMedia), takenOn: _date, memoryId: memory.id);
      }
      ref.read(contentRevisionProvider.notifier).bump();
      if (!mounted) return;
      showSnack(context, _newMedia.isEmpty ? 'Anı kaydedildi' : 'Anı kaydedildi, dosyalar yükleniyor…');
      if (_isEdit) {
        context.pop();
      } else {
        context.pushReplacement(contentRoute(ContentRouteKind.memory, baby.id, memory.id));
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
    if (baby == null) {
      final routeBabyUnavailable = widget.babyId != null && ref.watch(babiesProvider).hasValue;
      return Scaffold(
        appBar: routeBabyUnavailable ? AppBar() : null,
        body: routeBabyUnavailable
            ? const EmptyState(
                icon: Icons.search_off_rounded,
                title: 'Bebek profili bulunamadı',
                message: 'Silinmiş olabilir ya da erişim yetkiniz yok.',
              )
            : const LoadingView(),
      );
    }
    if (_isEdit) {
      final detailKey = (baby.id, widget.memoryId!);
      final detail = ref.watch(memoryDetailProvider(detailKey));
      if (!detail.hasValue) {
        return Scaffold(
          appBar: AppBar(),
          body: AsyncValueView(
            value: detail,
            data: (_) => const SizedBox(),
            onRetry: () => ref.invalidate(memoryDetailProvider(detailKey)),
          ),
        );
      }
      if (detail.value == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Anı bulunamadı',
            message: 'Silinmiş olabilir ya da erişim yetkiniz yok.',
          ),
        );
      }
      _fill(detail.value!);
    }
    final theme = Theme.of(context);
    final fy = baby.firstYear;
    final age = baby.ageOn(_date);
    final inFirstYear = fy.isBookCandidate(_date);
    final milestones = ref.watch(milestoneSlotsProvider(baby.id)).value?.where((s) => s.achieved).toList() ?? const [];
    final access = ref.watch(accessProvider(baby.id));
    final canAddMedia = access.can(AppPermission.addPhoto) || access.can(AppPermission.addVideo);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Anıyı düzenle' : 'Yeni anı'),
        actions: [TextButton(onPressed: _busy ? null : () => _save(baby), child: const Text('Kaydet'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            TextFormField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              style: theme.textTheme.titleLarge?.copyWith(fontFamily: 'Lora'),
              decoration: const InputDecoration(labelText: 'Başlık', hintText: 'İlk kez parkta…'),
              validator: (v) => Validators.required(v, field: 'Başlık') ?? Validators.maxLength(v, 140),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _body,
              minLines: 4,
              maxLines: 12,
              maxLength: 10000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Ne oldu?',
                alignLabelWithHint: true,
                hintText: 'Bu anı yıllar sonra okuduğunuzda ne hatırlamak istersiniz?',
              ),
            ),
            const SizedBox(height: 6),
            DateField(
              label: 'Tarih',
              value: _date,
              firstDate: Dates.addDays(baby.birthDate, -300),
              lastDate: Dates.today(),
              helper: age == null ? 'Doğumdan önce (hamilelik anısı)' : '${baby.firstName} ${age.whileLabel}',
              onChanged: (d) => setState(() => _date = d),
            ),
            if (inFirstYear)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book_rounded, size: 18, color: AppColors.apricot),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Bu tarih İlk Yılım dönemine denk geliyor; kitaba aday olur.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            TimeField(label: 'Saat', value: _time, onChanged: (t) => setState(() => _time = t)),
            const SizedBox(height: 18),
            Text('Kategori', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in MemoryCategory.values)
                  ChoiceChip(
                    avatar: Icon(c.icon, size: 18),
                    label: Text(c.label),
                    selected: _category == c,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            if (milestones.isNotEmpty) ...[
              const SizedBox(height: 18),
              DropdownButtonFormField<String?>(
                initialValue: _milestoneId,
                decoration: const InputDecoration(
                  labelText: 'Kilometre taşı bağlantısı',
                  prefixIcon: Icon(Icons.star_outline_rounded),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Bağlantı yok')),
                  for (final s in milestones)
                    DropdownMenuItem(value: s.milestone!.id, child: Text('${s.type.emoji ?? ''} ${s.type.title}')),
                ],
                onChanged: (v) => setState(() => _milestoneId = v),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Text('Fotoğraf ve videolar', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (canAddMedia)
                  TextButton.icon(
                    onPressed: _addMedia,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Ekle'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_existing.isEmpty && _newMedia.isEmpty)
              Text('Henüz dosya eklenmedi.', style: theme.textTheme.bodySmall)
            else
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (final m in _existing.where((m) => !_removed.contains(m.id)))
                    _RemovableTile(
                      onRemove: () => setState(() => _removed.add(m.id)),
                      child: MediaThumb(media: m, radius: 10),
                    ),
                  for (final p in _newMedia)
                    _RemovableTile(
                      onRemove: () => setState(() => _newMedia.remove(p)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: p.kind == MediaKind.photo
                            ? Image.file(File(p.path), fit: BoxFit.cover, cacheWidth: 300)
                            : Container(
                                color: theme.colorScheme.surfaceContainerHigh,
                                child: const Icon(Icons.videocam_outlined),
                              ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 18),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeInBook,
              onChanged: (v) => setState(() => _includeInBook = v),
              title: const Text('Kitaba dahil et'),
              subtitle: const Text('İlk Yılım kitabı oluşturulurken bu anı kullanılabilir.'),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : () => _save(baby),
              child: Text(_isEdit ? 'Değişiklikleri kaydet' : 'Anıyı kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemovableTile extends StatelessWidget {
  const _RemovableTile({required this.child, required this.onRemove});

  final Widget child;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      Positioned(
        right: 2,
        top: 2,
        child: InkWell(
          onTap: onRemove,
          child: const CircleAvatar(
            radius: 11,
            backgroundColor: Colors.black54,
            child: Icon(Icons.close_rounded, size: 14, color: Colors.white),
          ),
        ),
      ),
    ],
  );
}
