import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/family_providers.dart';
import '../data/family_repository.dart';
import '../domain/activity_entry.dart';
import '../domain/family_member.dart';
import '../domain/permission.dart';
import '../domain/relation.dart';
import '../../babies/presentation/route_baby.dart';
import 'permission_editor.dart';

String memberRoute(String babyId, String memberId) => '/babies/$babyId/members/$memberId';

/// Role / permission management for one member (manage_members).
class MemberEditScreen extends ConsumerStatefulWidget {
  const MemberEditScreen({super.key, required this.babyId, required this.memberId});

  /// Route baby (`/babies/:babyId/members/:memberId`).
  final String babyId;
  final String memberId;

  @override
  ConsumerState<MemberEditScreen> createState() => _MemberEditScreenState();
}

class _MemberEditScreenState extends ConsumerState<MemberEditScreen> {
  FamilyMember? _member;
  late Relation _relation;
  final _label = TextEditingController();
  late bool _admin;
  late Set<AppPermission> _permissions;
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _init(FamilyMember m) {
    if (_member != null) return;
    _member = m;
    _relation = m.relation;
    _label.text = m.relationLabel ?? '';
    _admin = m.isAdmin;
    _permissions = {...m.permissions};
  }

  Future<void> _save() async {
    final m = _member!;
    setState(() => _busy = true);
    try {
      await ref
          .read(familyRepositoryProvider)
          .updateMember(
            m.babyId,
            m.id,
            relation: _relation,
            relationLabel: _relation == Relation.diger ? _label.text : null,
            isAdmin: _admin,
            permissions: _permissions,
          );
      ref.invalidate(membersProvider(m.babyId));
      if (mounted) {
        showSnack(context, 'Kaydedildi');
        context.pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final m = _member!;
    final ok = await confirm(
      context,
      title: '${m.shownName} aileden çıkarılsın mı?',
      message: 'Bu kişi artık hiçbir içeriği göremez. Eklediği anılar ailede kalır.',
      confirmLabel: 'Çıkar',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final done = await runWithProgress(context, () async {
      await ref.read(familyRepositoryProvider).removeMember(m.babyId, m.id);
      return true;
    });
    if (done == true && mounted) {
      ref.invalidate(membersProvider(m.babyId));
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(babyByIdProvider(widget.babyId));
    if (baby == null) return const RouteBabyMissing();
    final members = ref.watch(membersProvider(baby.id)).value;
    final m = members?.firstWhereOrNull((x) => x.id == widget.memberId);
    if (m == null) return Scaffold(appBar: AppBar(), body: const LoadingView());
    _init(m);
    final access = ref.watch(accessProvider(baby.id));
    final uid = ref.watch(currentUserIdProvider);
    final isMe = m.userId == uid;
    // Only Anne / Baba are admins and add parents (P-5 / P-8); nobody changes
    // or removes the other parent (P-9). The server enforces the same rules.
    final actorIsParent = ref.watch(myMembershipProvider(baby.id))?.isParentAdmin ?? false;
    final protectedParent = m.protectedFrom(uid);
    final canManage =
        access.can(AppPermission.manageMembers) && !isMe && !protectedParent && (access.isAdmin || !m.isAdmin);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(m.shownName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Center(
            child: AppAvatar(name: m.shownName, path: m.avatarPath, radius: 40),
          ),
          const SizedBox(height: 10),
          Center(child: Text(m.introduction, style: theme.textTheme.titleLarge)),
          Center(
            child: Text('${Dates.long(m.joinedAt.toLocal())} tarihinden beri ailede', style: theme.textTheme.bodySmall),
          ),
          const SizedBox(height: 20),
          if (!canManage) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.isAdmin ? 'Yönetici — tüm yetkiler' : 'Yetkiler', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    if (!m.isAdmin)
                      for (final p in m.permissions) Text('• ${p.label}'),
                    if (isMe) ...[
                      const SizedBox(height: 12),
                      Text('Kendi yetkilerinizi değiştiremezsiniz.', style: theme.textTheme.bodySmall),
                    ] else if (protectedParent) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Anne veya Babanın aile üyeliği ve yetkileri yalnızca kendisi tarafından değiştirilebilir.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ] else ...[
            DropdownButtonFormField<Relation>(
              initialValue: _relation,
              decoration: const InputDecoration(labelText: 'Yakınlık'),
              items: [
                for (final r in Relation.values)
                  if (!r.isParent || actorIsParent || r == m.relation) DropdownMenuItem(value: r, child: Text(r.label)),
              ],
              onChanged: (r) => setState(() {
                _relation = r ?? _relation;
                if (!_relation.isParent) _admin = false;
              }),
            ),
            if (_relation == Relation.diger) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Yakınlık adı'),
              ),
            ],
            if (actorIsParent && _relation.isParent)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _admin,
                onChanged: (v) => setState(() => _admin = v),
                title: const Text('Yönetici'),
                subtitle: const Text('Anne ve Baba eşit yöneticidir: tüm yetkiler, üyeleri yönetme ve bebeği silme.'),
              ),
            if (!_admin)
              PermissionEditor(
                value: _permissions,
                canGrantManagement: access.isAdmin,
                onChanged: (v) => setState(() => _permissions = v),
              ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('Kaydet')),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
              onPressed: _busy ? null : _remove,
              icon: const Icon(Icons.person_remove_outlined),
              label: const Text('Aileden çıkar'),
            ),
          ],
        ],
      ),
    );
  }
}

class ActivityLogScreen extends ConsumerWidget {
  const ActivityLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final log = ref.watch(activityProvider(baby.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Etkinlik geçmişi')),
      body: AsyncValueView<List<ActivityEntry>>(
        value: log,
        onRetry: () => ref.invalidate(activityProvider(baby.id)),
        data: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.history_rounded, title: 'Henüz kayıt yok')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final e = list[i];
                  final actor = ref.watch(authorNameProvider((baby.id, e.actorId)));
                  return ListTile(
                    title: Text('$actor ${e.description}'),
                    subtitle: Text(Dates.short(e.createdAt.toLocal())),
                  );
                },
              ),
      ),
    );
  }
}
