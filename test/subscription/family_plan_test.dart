import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/subscription/application/subscription_providers.dart';
import 'package:bebegimin_ilk_yili/features/subscription/domain/subscription_models.dart';
import 'package:bebegimin_ilk_yili/features/subscription/presentation/family_plan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';

PlanCatalog catalog() => PlanCatalog([
  for (final (code, cap, monthly, annual) in const [
    ('small_family', 3, 29900, 322920),
    ('normal_family', 6, 36900, 398520),
    ('large_family', 12, 46900, 506520),
  ]) ...[
    PlanCatalogItem.fromJson({
      'plan_code': code,
      'billing_period': 'monthly',
      'max_parent_seats': 2,
      'max_family_members': cap,
      'price_minor': monthly,
      'currency': 'TRY',
    }),
    PlanCatalogItem.fromJson({
      'plan_code': code,
      'billing_period': 'annual',
      'max_parent_seats': 2,
      'max_family_members': cap,
      'price_minor': annual,
      'currency': 'TRY',
    }),
  ],
]);

FamilyAccountOverview overview({
  String role = 'parent',
  String? plan = 'small_family',
  String status = 'active',
  int members = 1,
  bool overCapacity = false,
}) => FamilyAccountOverview.fromJson({
  'id': 'acct-1',
  'display_name': 'Elif\'in ailesi',
  'my_role': role,
  'subscription': plan == null
      ? null
      : {
          'plan_code': plan,
          'billing_period': 'monthly',
          'status': status,
          'current_period_end': '2026-10-29T00:00:00Z',
          'cancel_at_period_end': false,
          'over_capacity': overCapacity,
          'max_family_members': plan == 'small_family' ? 3 : 6,
          'price_minor': 29900,
          'currency': 'TRY',
        },
  'subscription_live': plan != null && status == 'active',
  'enforcement': false,
  'active_parents': 2,
  'active_family_members': members,
  'babies': [
    {'id': 'b1', 'first_name': 'Defne'},
    {'id': 'b2', 'first_name': 'Ece'},
  ],
  'members': [
    {'user_id': 'u1', 'display_name': 'Elif', 'role': 'parent', 'status': 'active', 'relationship_label': 'anne'},
    {'user_id': 'u2', 'display_name': 'Mert', 'role': 'parent', 'status': 'active', 'relationship_label': 'baba'},
  ],
});

Future<void> pumpPlan(WidgetTester tester, FamilyAccountOverview? account) async {
  tester.view.physicalSize = const Size(1200, 4000);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        babiesProvider.overrideWithValue(AsyncData([defne])),
        activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
        familyAccountOverviewProvider(defne.id).overrideWithValue(AsyncData(account)),
        planCatalogProvider.overrideWithValue(AsyncData(catalog())),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const FamilyPlanScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  test('annual saving is derived from catalog prices', () {
    final c = catalog();
    expect(c.annualSavingMinor('small_family'), 29900 * 12 - 322920);
    expect(c.forPeriod(BillingPeriod.annual).map((p) => p.maxFamilyMembers), [3, 6, 12]);
  });

  test('capacity only exists with a live subscription', () {
    expect(overview(members: 3).isFull, isTrue);
    expect(overview(plan: null, members: 30).capacity, isNull);
    expect(overview(status: 'canceled', members: 5).isFull, isFalse);
  });

  testWidgets('parents see one family plan for both babies and can upgrade', (tester) async {
    await pumpPlan(tester, overview(members: 3));
    expect(find.text('Small Family · Aylık'), findsOneWidget);
    expect(find.text('Defne'), findsOneWidget);
    expect(find.text('Ece'), findsOneWidget);
    expect(find.text('Aile üyeleri: 3 / 3'), findsOneWidget);
    expect(find.text('Ebeveynler: 2 / 2 (kapasiteye dahil değil)'), findsOneWidget);
    expect(find.textContaining('Kapasite dolu'), findsOneWidget);
    expect(find.text('Mevcut plan'), findsOneWidget);
    expect(find.text('Yükselt'), findsNWidgets(2));
    expect(find.textContaining('₺'), findsWidgets);
  });

  testWidgets('annual view shows the catalog saving', (tester) async {
    await pumpPlan(tester, overview());
    await tester.tap(find.text('Yıllık'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tasarruf'), findsNWidgets(3));
  });

  testWidgets('family members see the plan but cannot buy', (tester) async {
    await pumpPlan(tester, overview(role: 'family_member'));
    expect(find.text('Seç'), findsNothing);
    expect(find.text('Yükselt'), findsNothing);
    expect(find.textContaining('Aile üyeleri için ayrı abonelik gerekmez'), findsOneWidget);
  });

  testWidgets('downgrade below the member count is explained, nobody is removed', (tester) async {
    await pumpPlan(tester, overview(plan: 'normal_family', members: 5, overCapacity: true));
    expect(find.textContaining('Kimse çıkarılmadı'), findsOneWidget);
    expect(find.textContaining('Bu plan şu anki 5 aile üyesinden küçük'), findsOneWidget);
  });

  testWidgets('an unmapped legacy baby explains the pending mapping', (tester) async {
    await pumpPlan(tester, null);
    expect(find.text('Aile hesabı eşleştiriliyor'), findsOneWidget);
  });
}
