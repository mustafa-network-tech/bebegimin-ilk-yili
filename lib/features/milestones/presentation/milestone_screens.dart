import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/content/content_route.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/form_fields.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../media/application/media_providers.dart';
import '../../media/data/upload_queue.dart';
import '../../media/domain/media_item.dart';
import '../../media/presentation/media_picker.dart';
import '../../media/presentation/media_viewer_screen.dart';
import '../../media/presentation/media_widgets.dart';
import '../../memories/domain/comment.dart';
import '../../memories/presentation/comments_section.dart';
import '../application/milestone_providers.dart';
import '../data/milestone_repository.dart';
import '../domain/milestone.dart';

/// "İlklerim": achieved firsts + the ones still to come + custom firsts.
class MilestonesScreen extends ConsumerWidget {
  const MilestonesScreen({super.key});

  Future<void> _createCustom(BuildContext context, WidgetRef ref, String babyId) async {
    final title = TextEditingController();
    final emoji = TextEditingController(text: '⭐');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Özel bir ilk'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Başlık', hintText: 'İlk bisiklet turum'),
            ),
            TextField(
              controller: emoji,
              maxLength: 4,
              decoration: const InputDecoration(labelText: 'Emoji'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Oluştur')),
        ],
      ),
    );
    if (ok != true || title.text.trim().isEmpty || !context.mounted) return;
    final type = await runWithProgress(
      context,
      () => ref.read(milestoneRepositoryProvider).createCustomType(babyId, title.text, emoji.text),
    );
    if (type != null && context.mounted) {
      ref.read(contentRevisionProvider.notifier).bump();
      context.push('/milestone/new?typeId=${type.id}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final slots = ref.watch(milestoneSlotsProvider(baby.id));
    final access = ref.watch(accessProvider(baby.id));
    final canAdd = access.can(AppPermission.addMilestone);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('İlklerim')),
      floatingActionButton: canAdd
          ? FloatingActionButton.extended(
              onPressed: () => _createCustom(context, ref, baby.id),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Özel ilk'),
            )
          : null,
      body: AsyncValueView<List<MilestoneSlot>>(
        value: slots,
        onRetry: () => ref.invalidate(milestoneSlotsProvider(baby.id)),
        data: (list) {
          final achieved = list.where((s) => s.achieved).toList();
          final upcoming = list.where((s) => !s.achieved).toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 100),
            children: [
              if (achieved.isNotEmpty) ...[
                SectionHeader(title: 'Yaşadıklarımız · ${achieved.length}'),
                for (final s in achieved)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Card(
                      color: AppColors.honey.withValues(alpha: 0.12),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: Text(s.type.emoji ?? '⭐', style: const TextStyle(fontSize: 30)),
                        title: Text(s.type.title, style: theme.textTheme.titleMedium),
                        subtitle: Text(
                          '${Dates.long(s.milestone!.achievedOn)} · ${baby.ageOn(s.milestone!.achievedOn)?.label ?? ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push(
                          contentRoute(ContentRouteKind.milestone, s.milestone!.babyId, s.milestone!.id),
                        ),
                      ),
                    ),
                  ),
              ],
              const SectionHeader(title: 'Sırada neler var?'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 0.95,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final s in upcoming)
                      Card(
                        child: InkWell(
                          onTap: canAdd ? () => context.push('/milestone/new?typeId=${s.type.id}') : null,
                          onLongPress: s.type.isCustom && canAdd
                              ? () async {
                                  final ok = await confirm(
                                    context,
                                    title: 'Özel ilk silinsin mi?',
                                    message: s.type.title,
                                    confirmLabel: 'Sil',
                                    destructive: true,
                                  );
                                  if (ok && context.mounted) {
                                    await runWithProgress(
                                      context,
                                      () => ref.read(milestoneRepositoryProvider).deleteCustomType(s.type.id),
                                    );
                                    ref.read(contentRevisionProvider.notifier).bump();
                                  }
                                }
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Opacity(
                                  opacity: 0.55,
                                  child: Text(s.type.emoji ?? '⭐', style: const TextStyle(fontSize: 30)),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  s.type.title,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                                ),
                                if (s.type.isCustom) const Text('özel', style: TextStyle(fontSize: 10.5)),
                              ],
                            ),
                          ),
                        ),
                      ),
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

class MilestoneFormScreen extends ConsumerStatefulWidget {
  const MilestoneFormScreen({super.key, this.babyId, this.typeId, this.milestoneId});

  final String? babyId;
  final String? typeId;
  final String? milestoneId;

  @override
  ConsumerState<MilestoneFormScreen> createState() => _MilestoneFormScreenState();
}

class _MilestoneFormScreenState extends ConsumerState<MilestoneFormScreen> {
  final _desc = TextEditingController();
  DateTime _date = Dates.today();
  TimeOfDay? _time;
  bool _include = true;
  final List<PickedMedia> _media = [];
  bool _busy = false;
  bool _loaded = false;
  String? _typeId;

  bool get _isEdit => widget.milestoneId != null;

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save(String babyId) async {
    final typeId = _typeId ?? widget.typeId;
    if (typeId == null) return;
    setState(() => _busy = true);
    try {
      final draft = MilestoneDraft(
        babyId: babyId,
        typeId: typeId,
        achievedOn: _date,
        time: _time,
        description: _desc.text,
        includeInBook: _include,
      );
      final repo = ref.read(milestoneRepositoryProvider);
      final m = _isEdit ? await repo.update(babyId, widget.milestoneId!, draft) : await repo.create(draft);
      if (_media.isNotEmpty) {
        await ref
            .read(uploadQueueProvider.notifier)
            .enqueue(babyId: babyId, files: List.of(_media), takenOn: _date, milestoneId: m.id);
      }
      ref.read(contentRevisionProvider.notifier).bump();
      if (!mounted) return;
      showSnack(context, 'Kaydedildi ✨');
      _isEdit ? context.pop() : context.pushReplacement(contentRoute(ContentRouteKind.milestone, babyId, m.id));
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
    final slots = ref.watch(milestoneSlotsProvider(baby.id)).value;
    if (slots == null) return Scaffold(appBar: AppBar(), body: const LoadingView());
    if (_isEdit && !_loaded) {
      final slot = slots.where((s) => s.milestone?.id == widget.milestoneId).firstOrNull;
      if (slot == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Kilometre taşı bulunamadı',
            message: 'Silinmiş olabilir ya da erişim yetkiniz yok.',
          ),
        );
      }
      _loaded = true;
      _typeId = slot.type.id;
      _date = slot.milestone!.achievedOn;
      _time = parseSqlTime(slot.milestone!.achievedTime);
      _desc.text = slot.milestone!.description ?? '';
      _include = slot.milestone!.includeInBook;
    }
    final type = slots.map((s) => s.type).where((t) => t.id == (_typeId ?? widget.typeId)).firstOrNull;
    final access = ref.watch(accessProvider(baby.id));
    final age = baby.ageOn(_date);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(type?.title ?? 'Kilometre taşı')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Center(child: Text(type?.emoji ?? '⭐', style: const TextStyle(fontSize: 56))),
          const SizedBox(height: 12),
          DateField(
            label: 'Ne zaman?',
            value: _date,
            firstDate: baby.birthDate,
            lastDate: Dates.today(),
            helper: age == null ? null : '${baby.firstName} ${age.whileLabel}',
            onChanged: (d) => setState(() => _date = d),
          ),
          const SizedBox(height: 14),
          TimeField(label: 'Saat', value: _time, onChanged: (t) => setState(() => _time = t)),
          const SizedBox(height: 14),
          TextField(
            controller: _desc,
            minLines: 3,
            maxLines: 8,
            maxLength: 4000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nasıl oldu?', alignLabelWithHint: true),
          ),
          if (access.can(AppPermission.addPhoto) || access.can(AppPermission.addVideo)) ...[
            Row(
              children: [
                Text('Fotoğraf / video', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    final p = await MediaPicker.choose(
                      context,
                      photos: access.can(AppPermission.addPhoto),
                      videos: access.can(AppPermission.addVideo),
                    );
                    setState(() => _media.addAll(p));
                  },
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Ekle'),
                ),
              ],
            ),
            if (_media.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in _media)
                    InputChip(
                      avatar: Icon(p.kind == MediaKind.photo ? Icons.photo_outlined : Icons.videocam_outlined),
                      label: Text(p.path.split('/').last, overflow: TextOverflow.ellipsis),
                      onDeleted: () => setState(() => _media.remove(p)),
                    ),
                ],
              ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _include,
            onChanged: (v) => setState(() => _include = v),
            title: const Text('Kitaba dahil et'),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy || type == null ? null : () => _save(baby.id), child: const Text('Kaydet')),
        ],
      ),
    );
  }
}

class MilestoneDetailScreen extends ConsumerWidget {
  const MilestoneDetailScreen({super.key, required this.babyId, required this.milestoneId});

  final String babyId;
  final String milestoneId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(babyByIdProvider(babyId));
    if (baby == null) {
      final routeBabyUnavailable = ref.watch(babiesProvider).hasValue;
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
    final slot = ref.watch(milestoneDetailProvider((babyId, milestoneId)));
    final media = ref.watch(parentMediaProvider((babyId, 'milestone', milestoneId))).value ?? const <MediaItem>[];
    final access = ref.watch(accessProvider(babyId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (slot.value != null && access.canEditContent(slot.value!.milestone!.createdBy)) ...[
            IconButton(
              tooltip: 'Düzenle',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push(contentRoute(ContentRouteKind.milestone, babyId, milestoneId, edit: true)),
            ),
            IconButton(
              tooltip: 'Sil',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Silinsin mi?',
                  message: 'Bu ilk ve fotoğrafları silinecek.',
                  confirmLabel: 'Sil',
                  destructive: true,
                );
                if (!ok || !context.mounted) return;
                final done = await runWithProgress(context, () async {
                  await ref.read(milestoneRepositoryProvider).delete(babyId, milestoneId, media);
                  return true;
                });
                if (done == true && context.mounted) {
                  ref.read(contentRevisionProvider.notifier).bump();
                  context.pop();
                }
              },
            ),
          ],
        ],
      ),
      body: AsyncValueView<MilestoneSlot?>(
        value: slot,
        onRetry: () => ref.invalidate(milestoneSlotsProvider(baby.id)),
        data: (s) {
          if (s == null) return const EmptyState(icon: Icons.search_off_rounded, title: 'Bulunamadı');
          final m = s.milestone!;
          final age = baby.ageOn(m.achievedOn);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            children: [
              Center(child: Text(s.type.emoji ?? '⭐', style: const TextStyle(fontSize: 64))),
              const SizedBox(height: 8),
              Text(s.type.title, textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(
                '${Dates.longWithWeekday(m.achievedOn)}${age == null ? '' : ' · ${baby.firstName} ${age.whileLabel}'}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (m.description?.isNotEmpty ?? false) ...[
                const SizedBox(height: 20),
                Text(m.description!, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 17)),
              ],
              if (media.isNotEmpty) ...[
                const SizedBox(height: 20),
                MediaCollage(media: media, height: 240),
                TextButton(
                  onPressed: () => context.push(mediaViewerRoute(babyId), extra: MediaViewerArgs(media: media)),
                  child: const Text('Tüm fotoğrafları gör'),
                ),
              ],
              const Divider(height: 40),
              CommentsSection(babyId: baby.id, kind: TargetKind.milestone, targetId: m.id, title: 'Aile notları'),
            ],
          );
        },
      ),
    );
  }
}
