import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../babies/presentation/baby_app_bar.dart';
import '../../subscription/presentation/family_plan_screen.dart';
import '../application/family_providers.dart';
import '../data/family_repository.dart';
import '../domain/family_member.dart';
import '../domain/invitation.dart';
import '../domain/permission.dart';

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final members = ref.watch(membersProvider(baby.id));
    final access = ref.watch(accessProvider(baby.id));
    final uid = ref.watch(currentUserIdProvider);
    final canInvite = access.can(AppPermission.inviteMembers);
    final otherBabies = (ref.watch(babiesProvider).value ?? const []).where((b) => b.id != baby.id).toList();

    return Scaffold(
      appBar: const BabyAppBar(title: 'Aile'),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(membersProvider(baby.id));
          ref.invalidate(invitationsProvider(baby.id));
          await ref.read(membersProvider(baby.id).future);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                '${baby.firstName} için özel aile alanı. İçerikleri yalnızca buradaki kişiler, verilen yetkiler kadar görebilir.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            if (canInvite)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => context.push('/family/invite'),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text('Aileye davet et'),
                      ),
                    ),
                    if (access.isAdmin && otherBabies.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: 'Kardeşin ailesinden ekle',
                        onPressed: () => context.push('/family/add-from-sibling'),
                        icon: const Icon(Icons.diversity_1_rounded),
                      ),
                    ],
                  ],
                ),
              ),
            const SectionHeader(title: 'Aile üyeleri'),
            AsyncValueView<List<FamilyMember>>(
              value: members,
              onRetry: () => ref.invalidate(membersProvider(baby.id)),
              data: (list) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Card(
                  child: Column(
                    children: [
                      for (final m in list)
                        ListTile(
                          leading: AppAvatar(name: m.shownName, path: m.avatarPath),
                          title: Text(
                            m.userId == uid ? '${m.shownName} (siz)' : m.shownName,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            [
                              m.relationName,
                              if (m.isAdmin) 'Yönetici',
                              '${m.isAdmin ? AppPermission.values.length : m.permissions.length} yetki',
                            ].join(' · '),
                          ),
                          trailing: m.isAdmin
                              ? const Icon(Icons.verified_user_rounded, size: 20)
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/family/member/${m.id}'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (canInvite) _Invitations(babyId: baby.id),
            const SectionHeader(title: 'Aile paketi'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(child: FamilyPlanTile(babyId: baby.id)),
            ),
            const SectionHeader(title: 'Bebek'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.child_care_rounded),
                      title: Text('${baby.fullName} profili'),
                      subtitle: Text('Doğum: ${Dates.long(baby.birthDate)}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push('/baby/${baby.id}/edit'),
                    ),
                    if (access.isAdmin)
                      ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: const Text('Etkinlik geçmişi'),
                        subtitle: const Text('Katılımlar, yetki değişiklikleri, davetler'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push('/family/activity'),
                      ),
                    ListTile(
                      leading: const Icon(Icons.add_circle_outline_rounded),
                      title: const Text('Başka bir çocuk ekle'),
                      onTap: () => context.push('/baby/new'),
                    ),
                    ListTile(
                      leading: Icon(Icons.logout_rounded, color: Theme.of(context).colorScheme.error),
                      title: Text('Bu aileden ayrıl', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      onTap: () async {
                        final ok = await confirm(
                          context,
                          title: 'Aileden ayrılmak istiyor musunuz?',
                          message: '${baby.firstName} arşivine artık erişemezsiniz. Eklediğiniz anılar ailede kalır.',
                          confirmLabel: 'Ayrıl',
                          destructive: true,
                        );
                        if (!ok || !context.mounted || uid == null) return;
                        final done = await runWithProgress(context, () async {
                          await ref.read(familyRepositoryProvider).leave(baby.id, uid);
                          return true;
                        });
                        if (done == true) {
                          await ref.read(activeBabyIdProvider.notifier).select(null);
                          ref.invalidate(babiesProvider);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Invitations extends ConsumerWidget {
  const _Invitations({required this.babyId});

  final String babyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(invitationsProvider(babyId));
    final now = DateTime.now();
    final pending = (invites.value ?? const <Invitation>[]).where((i) => i.isUsable(now)).toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Bekleyen davetler'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            child: Column(
              children: [
                for (final i in pending)
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.mail_outline_rounded)),
                    title: Text(
                      InviteCode.pretty(i.code),
                      style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
                    ),
                    subtitle: Text(
                      '${i.relation.label}${i.invitedEmail == null ? '' : ' · ${i.invitedEmail}'} · son gün ${Dates.short(i.expiresAt.toLocal())}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        switch (v) {
                          case 'copy':
                            await Clipboard.setData(ClipboardData(text: i.code));
                            if (context.mounted) showSnack(context, 'Kod kopyalandı');
                          case 'share':
                            await SharePlus.instance.share(ShareParams(text: invitationMessage(i)));
                          case 'revoke':
                            await runWithProgress(
                              context,
                              () => ref.read(familyRepositoryProvider).revokeInvitation(i.id),
                              success: 'Davet iptal edildi',
                            );
                            ref.invalidate(invitationsProvider(babyId));
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'copy', child: Text('Kodu kopyala')),
                        PopupMenuItem(value: 'share', child: Text('Paylaş')),
                        PopupMenuItem(value: 'revoke', child: Text('İptal et')),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String invitationMessage(Invitation i) =>
    'Seni ailemizin özel anı arşivine davet ediyorum 🤍\n\n'
    '"Bebeğimin İlk Yılı" uygulamasında davet kodu: ${InviteCode.pretty(i.code)}\n'
    'Bağlantı: ${i.link}\n\n'
    'Kod ${Dates.long(i.expiresAt.toLocal())} tarihine kadar geçerlidir.';
