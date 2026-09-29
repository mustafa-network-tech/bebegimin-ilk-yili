import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../app/theme.dart';
import '../../../core/content/lifecycle_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/states.dart';
import '../application/baby_lifecycle_providers.dart';
import '../application/baby_providers.dart';
import '../domain/baby.dart';
import '../domain/baby_lifecycle.dart';

String lifecycleRoute(String babyId) => '/babies/$babyId/lifecycle';

/// Turkish one-liner for the extension state, shared by the home card and
/// the lifecycle screen.
String? extensionStatusText(BabyLifecycle l) => switch (l.extensionStatus) {
  null => null,
  BabyExtensionStatus.pending => 'Uzatma talebi değerlendiriliyor.',
  BabyExtensionStatus.approved => '${l.approvedExtensionDays} günlük uzatma onaylandı.',
  BabyExtensionStatus.rejected => 'Uzatma talebi reddedildi.',
  BabyExtensionStatus.expired => 'Uzatma talebinin süresi doldu.',
};

/// Home card: server countdown while ACTIVE, "İlk yılı tamamlandı" once LOCKED.
class LifecycleCard extends ConsumerWidget {
  const LifecycleCard({super.key, required this.baby});

  final Baby baby;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lifecycle = ref.watch(babyLifecycleProvider(baby.id));
    final theme = Theme.of(context);

    Widget card({required Widget leading, required String title, required List<Widget> body, VoidCallback? onTap}) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Card(
          color: AppColors.apricot.withValues(alpha: 0.08),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        ...body,
                      ],
                    ),
                  ),
                  if (onTap != null) const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final l = lifecycle.value;
    if (l == null) {
      if (lifecycle.hasError) {
        return card(
          leading: const Icon(Icons.cloud_off_rounded),
          title: 'Arşiv durumu alınamadı',
          body: [Text('Bağlantınızı kontrol edip yeniden deneyin.', style: theme.textTheme.bodySmall)],
          onTap: () => ref.read(lifecycleRevisionProvider.notifier).bump(),
        );
      }
      return card(
        leading: const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
        title: 'Arşiv durumu yükleniyor…',
        body: const [],
      );
    }

    void open() => context.push(lifecycleRoute(baby.id));

    if (l.isLocked) {
      return Semantics(
        label: '${baby.firstName} için ilk yıl tamamlandı. Arşiv kilitli ve salt okunur.',
        excludeSemantics: true,
        child: card(
          leading: const CircleAvatar(
            radius: 24,
            backgroundColor: AppColors.apricot,
            child: Icon(Icons.lock_rounded, color: Colors.white),
          ),
          title: 'İlk Yılı tamamlandı',
          body: [
            Text(
              'Arşiv ${Dates.long(l.effectiveCloseDate)} itibarıyla kilitli. '
              'Anılar, albüm, takvim ve arama açık; yeni içerik eklenemez.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          onTap: open,
        ),
      );
    }

    final total = l.effectiveCloseDate.difference(baby.birthDate).inDays;
    final progress = total <= 0 ? 1.0 : (1 - l.remainingDays / total).clamp(0.0, 1.0);
    final extension = extensionStatusText(l);
    final countdown = l.remainingDays == 1 ? 'Son gün' : '${l.remainingDays} gün kaldı';
    return Semantics(
      label: 'İlk yıl arşivi açık. $countdown. Arşiv ${Dates.long(l.effectiveCloseDate)} tarihinde kilitlenir.',
      excludeSemantics: true,
      child: card(
        leading: const CircleAvatar(
          radius: 24,
          backgroundColor: AppColors.apricot,
          child: Icon(Icons.hourglass_bottom_rounded, color: Colors.white),
        ),
        title: 'İlk Yıl Arşivi · $countdown',
        body: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: progress, minHeight: 7),
          ),
          const SizedBox(height: 6),
          Text(
            'Arşiv ${Dates.long(l.effectiveCloseDate)} tarihinde kilitlenir'
            '${l.hasApprovedExtension ? ' (onaylı uzatma dahil)' : ''}.'
            '${extension == null || l.hasApprovedExtension ? '' : ' $extension'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        onTap: open,
      ),
    );
  }
}

/// Wraps create/edit form routes. Deep links cannot bypass it: the form is
/// only built once the server confirmed the archive is ACTIVE.
class LifecycleWriteGuard extends ConsumerWidget {
  const LifecycleWriteGuard({super.key, this.babyId, required this.child});

  /// Route baby; `null` uses the active selection (new-content routes).
  final String? babyId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = babyId ?? ref.watch(activeBabyProvider)?.id;
    if (id == null) return const Scaffold(body: LoadingView());
    final lifecycle = ref.watch(babyLifecycleProvider(id));
    final l = lifecycle.value;
    if (l != null && l.isActive) return child;
    if (l != null) return _LockedRouteView(babyId: id);
    if (lifecycle.hasError) {
      return Scaffold(
        appBar: AppBar(),
        body: ErrorView(error: lifecycle.error!, onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump()),
      );
    }
    return const Scaffold(body: LoadingView());
  }
}

class _LockedRouteView extends StatelessWidget {
  const _LockedRouteView({required this.babyId});

  final String babyId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Arşiv kilitli')),
      body: EmptyState(
        icon: Icons.lock_rounded,
        title: 'İlk yıl arşivi tamamlandı',
        message: 'Bu arşiv artık salt okunur. Anıları, albümü ve takvimi görüntülemeye devam edebilirsiniz.',
        action: FilledButton(
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
          child: const Text('Geri dön'),
        ),
      ),
    );
  }
}

/// Book / premium routes. ACTIVE profiles never reach them (plan 2.2); LOCKED
/// profiles see a placeholder until entitlements exist, unless the internal
/// PREMIUM_PREVIEW flag is on.
class PremiumRouteGate extends ConsumerWidget {
  const PremiumRouteGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final lifecycle = ref.watch(babyLifecycleProvider(baby.id));
    final l = lifecycle.value;
    if (l == null) {
      return Scaffold(
        appBar: AppBar(),
        body: lifecycle.hasError
            ? ErrorView(error: lifecycle.error!, onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump())
            : const LoadingView(),
      );
    }
    if (l.isLocked && Env.premiumPreview) return child;
    return Scaffold(
      appBar: AppBar(title: const Text('İlk Yıl hatıraları')),
      body: EmptyState(
        icon: l.isLocked ? Icons.auto_stories_rounded : Icons.hourglass_bottom_rounded,
        title: l.isLocked ? 'Yakında' : 'İlk yıl devam ediyor',
        message: l.isLocked
            ? 'Dijital kitap, film ve çevrimdışı arşiv yakında bu tamamlanmış arşivden hazırlanabilecek.'
            : 'Kitap, film ve çevrimdışı arşiv, ilk yıl arşivi ${Dates.long(l.effectiveCloseDate)} tarihinde '
                  'tamamlandıktan sonra hazırlanabilir.',
        action: FilledButton(
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
          child: const Text('Geri dön'),
        ),
      ),
    );
  }
}
