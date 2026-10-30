import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/subscription_providers.dart';
import '../domain/subscription_models.dart';
import 'family_plan_screen.dart';

const plansOverviewRoute = '/plans';

/// Read-only list of the plans and their prices. It works before a baby (and so a
/// family account) exists; buying happens on the family plan screen.
class PlansOverviewScreen extends ConsumerStatefulWidget {
  const PlansOverviewScreen({super.key});

  @override
  ConsumerState<PlansOverviewScreen> createState() => _PlansOverviewScreenState();
}

class _PlansOverviewScreenState extends ConsumerState<PlansOverviewScreen> {
  BillingPeriod _period = BillingPeriod.monthly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = ref.watch(planCatalogProvider);
    final hasBaby = ref.watch(activeBabyProvider) != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Planlar')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Plan aile hesabınıza aittir: Anne ve Baba ile aile üyelerini ve tüm bebeklerinizi kapsar. '
              '${hasBaby ? '' : 'Bebek profilinizi oluşturduktan sonra buradan plan seçebilirsiniz.'}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<BillingPeriod>(
              segments: [for (final p in BillingPeriod.values) ButtonSegment(value: p, label: Text(p.label))],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
          ),
          AsyncValueView<PlanCatalog>(
            value: catalog,
            onRetry: () => ref.invalidate(planCatalogProvider),
            data: (c) => Column(
              children: [
                for (final plan in c.forPeriod(_period))
                  Card(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(planName(plan.planCode), style: theme.textTheme.titleMedium),
                          Text(
                            '${formatMinor(plan.priceMinor)} ${plan.period == BillingPeriod.monthly ? '/ ay' : '/ yıl'}',
                            style: theme.textTheme.titleLarge,
                          ),
                          if (_period == BillingPeriod.annual && (c.annualSavingMinor(plan.planCode) ?? 0) > 0)
                            Text(
                              '12 aylık ödemeye göre ${formatMinor(c.annualSavingMinor(plan.planCode)!)} tasarruf',
                              style: theme.textTheme.bodySmall,
                            ),
                          const SizedBox(height: 6),
                          Text('Anne + Baba ve ${plan.maxFamilyMembers} aile üyesi · tüm bebekler dahil'),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (hasBaby) ...[
            const SectionHeader(title: 'Plan seçmek için'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: () => context.push(familyPlanRoute),
                icon: const Icon(Icons.workspace_premium_rounded),
                label: const Text('Planımı yönet'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
