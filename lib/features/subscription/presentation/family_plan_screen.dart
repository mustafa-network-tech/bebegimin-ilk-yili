import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/subscription_providers.dart';
import '../data/store_billing.dart';
import '../data/subscription_repository.dart';
import '../domain/subscription_models.dart';

const familyPlanRoute = '/family/plan';

/// Family package: current plan, covered babies, member capacity and the
/// catalog. One subscription per family account covers both parents and all
/// babies; Family Members never pay separately.
class FamilyPlanScreen extends ConsumerStatefulWidget {
  const FamilyPlanScreen({super.key});

  @override
  ConsumerState<FamilyPlanScreen> createState() => _FamilyPlanScreenState();
}

class _FamilyPlanScreenState extends ConsumerState<FamilyPlanScreen> {
  BillingPeriod? _period;
  bool _busy = false;
  StreamSubscription<StorePurchaseEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = ref.read(storeBillingProvider).events.listen((e) {
      if (!mounted) return;
      switch (e.status) {
        case StorePurchaseStatus.verified:
          showSnack(context, 'Aile paketiniz güncellendi.');
        case StorePurchaseStatus.pending:
          showSnack(context, 'Ödeme onayı bekleniyor…');
        case StorePurchaseStatus.failed:
          if (e.message != null) showSnack(context, e.message!, error: true);
        case StorePurchaseStatus.canceled:
          break;
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _choose(FamilyAccountOverview account, PlanCatalogItem plan) async {
    final warnDowngrade = account.activeFamilyMembers > plan.maxFamilyMembers;
    final ok = await confirm(
      context,
      title: '${planName(plan.planCode)} · ${plan.period.label}',
      message:
          '${formatMinor(plan.priceMinor)} ${plan.period == BillingPeriod.monthly ? '/ ay' : '/ yıl'}. '
          'Abonelik aile hesabına aittir; iki ebeveyni ve tüm bebekleri kapsar.'
          '${warnDowngrade ? '\n\nBu planın kapasitesi (${plan.maxFamilyMembers}) şu anki aktif aile üyesi sayısından '
                    '(${account.activeFamilyMembers}) az. Kimse otomatik çıkarılmaz; ancak sayı kapasiteye inene kadar '
                    'yeni aile üyesi eklenemez.' : ''}',
      confirmLabel: 'Devam et',
    );
    if (!ok || !mounted) return;
    final store = ref.read(storeBillingProvider);
    final provider = store.provider;
    if (provider == null) {
      showSnack(context, 'Satın alma yalnızca iOS ve Android uygulamasında yapılabilir.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      // The intent binds the store purchase to this family account; the plan
      // opens only after the server verified the receipt with the store.
      final intent = await ref
          .read(subscriptionRepositoryProvider)
          .requestCheckout(accountId: account.id, planCode: plan.planCode, period: plan.period, provider: provider.key);
      await store.buy(intent);
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
    final overview = ref.watch(familyAccountOverviewProvider(baby.id));
    final catalog = ref.watch(planCatalogProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Aile paketi')),
      body: AsyncValueView<FamilyAccountOverview?>(
        value: overview,
        onRetry: () => ref.invalidate(familyAccountOverviewProvider(baby.id)),
        data: (account) {
          if (account == null) {
            return const EmptyState(
              icon: Icons.family_restroom_rounded,
              title: 'Aile hesabı eşleştiriliyor',
              message: 'Bu bebek henüz bir aile hesabına bağlanmadı. Eşleştirme tamamlandığında paket bilgisi burada görünür.',
            );
          }
          final period = _period ?? account.subscription?.period ?? BillingPeriod.monthly;
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(familyAccountOverviewProvider(baby.id));
              ref.invalidate(planCatalogProvider);
              await ref.read(familyAccountOverviewProvider(baby.id).future);
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _SubscriptionCard(account: account),
                _CapacityCard(account: account),
                const SectionHeader(title: 'Kapsanan bebekler'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final b in account.babies)
                        Chip(avatar: const Icon(Icons.child_care_rounded), label: Text(b)),
                    ],
                  ),
                ),
                const SectionHeader(title: 'Kişiler'),
                for (final m in account.members)
                  ListTile(
                    leading: Icon(m.isParent ? Icons.shield_rounded : Icons.person_outline_rounded),
                    title: Text(m.displayName),
                    subtitle: Text(
                      '${m.isParent ? 'Ebeveyn' : 'Aile üyesi'}'
                      '${m.relationshipLabel == null ? '' : ' · ${m.relationshipLabel}'} · ${m.statusLabel}',
                    ),
                  ),
                const SectionHeader(title: 'Planlar'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<BillingPeriod>(
                    segments: [for (final p in BillingPeriod.values) ButtonSegment(value: p, label: Text(p.label))],
                    selected: {period},
                    onSelectionChanged: (s) => setState(() => _period = s.first),
                  ),
                ),
                AsyncValueView<PlanCatalog>(
                  value: catalog,
                  onRetry: () => ref.invalidate(planCatalogProvider),
                  data: (c) => Column(
                    children: [
                      for (final plan in c.forPeriod(period))
                        _PlanCard(
                          plan: plan,
                          storePrice: ref.watch(storePricesProvider).value?['${plan.planCode}.${plan.period.key}'],
                          saving: period == BillingPeriod.annual ? c.annualSavingMinor(plan.planCode) : null,
                          account: account,
                          busy: _busy,
                          onChoose: account.isParent ? () => _choose(account, plan) : null,
                        ),
                    ],
                  ),
                ),
                if (!account.isParent)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Aile paketini Anne veya Baba yönetir. Aile üyeleri için ayrı abonelik gerekmez.'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.account});

  final FamilyAccountOverview account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = account.subscription;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(account.displayName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (s == null)
              const Text('Henüz bir aile paketi yok.')
            else ...[
              Text('${planName(s.planCode)} · ${s.period.label}', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '${s.statusLabel}'
                '${s.currentPeriodEnd == null ? '' : ' · ${s.cancelAtPeriodEnd ? 'Bitiş' : 'Yenileme'}: ${Dates.long(s.currentPeriodEnd!.toLocal())}'}',
              ),
            ],
            if (account.overCapacity) ...[
              const SizedBox(height: 10),
              Text(
                'Aktif aile üyesi sayısı paket kapasitesinin üzerinde. Kimse çıkarılmadı; ancak sayı kapasiteye inene '
                'kadar yeni aile üyesi eklenemez.',
                style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CapacityCard extends StatelessWidget {
  const _CapacityCard({required this.account});

  final FamilyAccountOverview account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cap = account.capacity;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: cap == null
                  ? '${account.activeFamilyMembers} aile üyesi'
                  : '${account.activeFamilyMembers} / $cap aile üyesi kullanılıyor',
              excludeSemantics: true,
              child: Text(
                cap == null
                    ? 'Aile üyeleri: ${account.activeFamilyMembers}'
                    : 'Aile üyeleri: ${account.activeFamilyMembers} / $cap',
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (cap != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: (account.activeFamilyMembers / cap).clamp(0.0, 1.0),
                  minHeight: 8,
                  color: account.isFull ? theme.colorScheme.error : null,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text('Ebeveynler: ${account.activeParents} / 2 (kapasiteye dahil değil)', style: theme.textTheme.bodySmall),
            if (account.isFull && account.isParent) ...[
              const SizedBox(height: 8),
              Text(
                'Kapasite dolu. Yeni aile üyesi için paketi yükseltebilirsiniz.',
                style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    this.storePrice,
    required this.saving,
    required this.account,
    required this.busy,
    required this.onChoose,
  });

  final PlanCatalogItem plan;

  /// Localized price from the App Store / Google Play, when available.
  final String? storePrice;
  final int? saving;
  final FamilyAccountOverview account;
  final bool busy;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = account.subscription;
    final current = account.subscriptionLive && s?.planCode == plan.planCode && s?.period == plan.period;
    final upgrade = account.subscriptionLive && (s?.maxFamilyMembers ?? 0) < plan.maxFamilyMembers;
    final tooSmall = account.activeFamilyMembers > plan.maxFamilyMembers;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      shape: current
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(planName(plan.planCode), style: theme.textTheme.titleMedium)),
                if (current) const Chip(label: Text('Mevcut plan')),
              ],
            ),
            Text(
              '${formatMinor(plan.priceMinor)} ${plan.period == BillingPeriod.monthly ? '/ ay' : '/ yıl'}',
              style: theme.textTheme.titleLarge,
            ),
            if (storePrice != null) Text('Mağaza fiyatı: $storePrice', style: theme.textTheme.bodySmall),
            if (saving != null && saving! > 0)
              Text('12 aylık ödemeye göre ${formatMinor(saving!)} tasarruf', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Text('Anne + Baba ve ${plan.maxFamilyMembers} aile üyesi · tüm bebekler dahil'),
            if (tooSmall)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Bu plan şu anki ${account.activeFamilyMembers} aile üyesinden küçük.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (onChoose != null && !current) ...[
              const SizedBox(height: 10),
              FilledButton(onPressed: busy ? null : onChoose, child: Text(upgrade ? 'Yükselt' : 'Seç')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact entry on the family screen.
class FamilyPlanTile extends ConsumerWidget {
  const FamilyPlanTile({super.key, required this.babyId});

  final String babyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(familyAccountOverviewProvider(babyId)).value;
    final cap = account?.capacity;
    return ListTile(
      leading: const Icon(Icons.workspace_premium_outlined),
      title: const Text('Aile paketi'),
      subtitle: Text(
        account == null
            ? 'Plan ve aile üyesi kapasitesi'
            : account.subscription == null || !account.subscriptionLive
            ? 'Aktif paket yok'
            : '${planName(account.subscription!.planCode)} · ${account.activeFamilyMembers} / $cap aile üyesi'
                  '${account.isFull ? ' · dolu' : ''}',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.push(familyPlanRoute),
    );
  }
}
