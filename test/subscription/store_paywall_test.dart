import 'dart:async';

import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/supabase_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:bebegimin_ilk_yili/features/family/application/family_providers.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/family_member.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/permission.dart';
import 'package:bebegimin_ilk_yili/features/premium/domain/premium_models.dart';
import 'package:bebegimin_ilk_yili/features/subscription/application/subscription_providers.dart';
import 'package:bebegimin_ilk_yili/features/subscription/data/store_billing.dart';
import 'package:bebegimin_ilk_yili/features/subscription/data/subscription_repository.dart';
import 'package:bebegimin_ilk_yili/features/subscription/domain/subscription_models.dart';
import 'package:bebegimin_ilk_yili/features/subscription/presentation/family_plan_screen.dart';
import 'package:bebegimin_ilk_yili/features/subscription/presentation/paywall_screen.dart';
import 'package:bebegimin_ilk_yili/features/subscription/presentation/read_only_banner.dart';
import 'package:bebegimin_ilk_yili/features/babies/presentation/lifecycle_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';
import 'family_plan_test.dart' show catalog, overview;

class _FakeStore implements StoreBilling {
  _FakeStore(this.provider);

  @override
  final StoreProvider? provider;
  final bought = <CheckoutIntent>[];
  int restores = 0;
  final _events = StreamController<StorePurchaseEvent>.broadcast();

  @override
  bool get isSupported => provider != null;
  @override
  Stream<StorePurchaseEvent> get events => _events.stream;
  @override
  void start() {}
  @override
  Future<Map<String, String>> localizedPrices(Iterable<String> ids) async => {for (final id in ids) id: '₺299,99'};
  @override
  Future<void> buy(CheckoutIntent intent) async => bought.add(intent);
  @override
  Future<void> buyPremium(PremiumOrder order) async {}
  @override
  Future<void> restore() async => restores++;
  @override
  void dispose() => _events.close();
}

class _FakeRepo implements SubscriptionRepository {
  final checkouts = <(String, String, String?)>[];

  @override
  Future<CheckoutIntent> requestCheckout({
    required String accountId,
    required String planCode,
    required BillingPeriod period,
    String? provider,
  }) async {
    checkouts.add((planCode, period.key, provider));
    return CheckoutIntent.fromJson({
      'intent_id': '8d2c1a52-0000-4000-8000-000000000001',
      'provider': provider,
      'provider_product_id': 'bebegimin.$planCode.${period.key}',
      'plan_code': planCode,
      'billing_period': period.key,
      'price_minor': 36900,
      'would_exceed_capacity': false,
    });
  }

  @override
  Future<Map<String, String>> storeProducts(String provider) async => {
    'small_family.monthly': 'bebegimin.small_family.monthly',
    'normal_family.monthly': 'bebegimin.normal_family.monthly',
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BabyAccessState state({bool allowed = false, String reason = 'subscription_ended', bool parent = true}) =>
    BabyAccessState.fromJson(defne.id, {'allowed': allowed, 'reason': reason, 'is_parent': parent});

Future<void> _pumpPaywall(WidgetTester tester, BabyAccessState s, _FakeStore store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        babiesProvider.overrideWithValue(AsyncData([defne])),
        activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
        babyAccessStateProvider(defne.id).overrideWithValue(AsyncData(s)),
        storeBillingProvider.overrideWithValue(store),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const PaywallScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  test('Google Play product ids are productId:basePlanId', () {
    final ref = GoogleProductRef.parse('small_family:annual');
    expect(ref.productId, 'small_family');
    expect(ref.basePlanId, 'annual');
    expect(() => GoogleProductRef.parse('small_family'), throwsFormatException);
    expect(() => GoogleProductRef.parse(':monthly'), throwsFormatException);
  });

  test('an inactive family subscription makes the archive read-only, not hidden (decision P-2)', () {
    ProviderContainer container(bool allowed) => ProviderContainer(
      overrides: [
        currentUserIdProvider.overrideWithValue('user-anne'),
        membersProvider(defne.id).overrideWithValue(
          AsyncData([
            FamilyMember.fromJson({
              'id': 'fm-anne',
              'baby_id': defne.id,
              'user_id': 'user-anne',
              'relation': 'anne',
              'relation_label': null,
              'is_admin': true,
              'permissions': const <String>[],
              'joined_at': '2025-09-20T10:00:00Z',
              'profiles': {'display_name': 'Elif', 'avatar_path': null},
            }),
          ]),
        ),
        babyLifecycleProvider(defne.id).overrideWithValue(
          AsyncData(
            BabyLifecycle(
              babyId: defne.id,
              status: BabyLifecycleStatus.active,
              businessDate: DateTime(2026, 1, 1),
              baseCloseDate: DateTime(2026, 9, 22),
              effectiveCloseDate: DateTime(2026, 9, 22),
              remainingDays: 264,
              extensionStatus: null,
              approvedExtensionDays: 0,
              canRequestExtension: false,
            ),
          ),
        ),
        babyAccessStateProvider(defne.id).overrideWithValue(AsyncData(state(allowed: allowed))),
      ],
    );

    final lapsed = container(false);
    addTearDown(lapsed.dispose);
    final access = lapsed.read(accessProvider(defne.id));
    expect(lapsed.read(babySubscriptionReadOnlyProvider(defne.id)), isTrue);
    expect(access.can(AppPermission.viewMemories), isTrue);
    expect(access.can(AppPermission.viewAlbum), isTrue);
    expect(access.can(AppPermission.manageMembers), isTrue, reason: 'family management stays open');
    expect(access.can(AppPermission.addMemory), isFalse);
    expect(access.canCreateAnything, isFalse, reason: 'no + button');

    final paid = container(true);
    addTearDown(paid.dispose);
    expect(paid.read(babySubscriptionReadOnlyProvider(defne.id)), isFalse);
    expect(paid.read(accessProvider(defne.id)).can(AppPermission.addMemory), isTrue);
  });

  test('access reasons are explained without promising deletion', () {
    expect(state().message, contains('hiçbir şey silinmedi'));
    expect(state(parent: false).message, contains('Anne veya Baba'));
    expect(state().message, contains('salt okunur'), reason: 'decision P-2: the archive stays readable');
    expect(state(parent: false).message, contains('hiçbir şey silinmedi'));
    expect(state(reason: 'payment_issue').title, 'Ödeme alınamadı');
    expect(state(reason: 'account_unmapped').title, 'Aile hesabı eşleştiriliyor');
    expect(state(allowed: true, reason: 'ok').allowed, isTrue);
  });

  Future<void> pumpWithGate(WidgetTester tester, Widget child, {required bool allowed}) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        babiesProvider.overrideWithValue(AsyncData([defne])),
        activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
        babyAccessStateProvider(defne.id).overrideWithValue(AsyncData(state(allowed: allowed))),
        babyLifecycleProvider(defne.id).overrideWithValue(
          AsyncData(
            BabyLifecycle(
              babyId: defne.id,
              status: BabyLifecycleStatus.active,
              businessDate: DateTime(2026, 1, 1),
              baseCloseDate: DateTime(2026, 9, 22),
              effectiveCloseDate: DateTime(2026, 9, 22),
              remainingDays: 264,
              extensionStatus: null,
              approvedExtensionDays: 0,
              canRequestExtension: false,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: child),
      ),
    ),
  );

  testWidgets('a lapsed subscription shows a read-only banner instead of locking the app', (tester) async {
    await pumpWithGate(tester, const SubscriptionReadOnlyBanner(), allowed: false);
    expect(find.text('Aile paketi aktif değil: arşiv salt okunur.'), findsOneWidget);
    await pumpWithGate(tester, const SubscriptionReadOnlyBanner(), allowed: true);
    await tester.pumpAndSettle();
    expect(find.textContaining('salt okunur'), findsNothing);
  });

  testWidgets('write forms stay closed while the archive is read-only', (tester) async {
    await pumpWithGate(tester, LifecycleWriteGuard(babyId: defne.id, child: const Text('FORM')), allowed: false);
    await tester.pumpAndSettle();
    expect(find.text('FORM'), findsNothing);
    expect(find.text('Aile paketi aktif değil'), findsOneWidget);
  });

  testWidgets('parents can choose a plan or restore purchases', (tester) async {
    final store = _FakeStore(StoreProvider.appStore);
    await _pumpPaywall(tester, state(), store);
    expect(find.text('Aile paketinizin süresi doldu'), findsOneWidget);
    expect(find.text('Aile paketini seç'), findsOneWidget);
    await tester.tap(find.text('Satın alımları geri yükle'));
    await tester.pumpAndSettle();
    expect(store.restores, 1);
  });

  testWidgets('family members are told a parent renews; no purchase buttons', (tester) async {
    await _pumpPaywall(tester, state(parent: false), _FakeStore(StoreProvider.googlePlay));
    expect(find.text('Aile paketini seç'), findsNothing);
    expect(find.text('Satın alımları geri yükle'), findsNothing);
    expect(find.textContaining('arşiv salt okunur'), findsOneWidget);
    expect(find.textContaining('Anne veya Baba paketi yenilediğinde'), findsOneWidget);
    expect(find.text('Tekrar kontrol et'), findsOneWidget);
  });

  testWidgets('choosing a plan starts a store purchase bound to a checkout intent', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    addTearDown(tester.view.resetPhysicalSize);
    final store = _FakeStore(StoreProvider.appStore);
    final repo = _FakeRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          babiesProvider.overrideWithValue(AsyncData([defne])),
          activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
          familyAccountOverviewProvider(defne.id).overrideWithValue(AsyncData(overview(members: 3))),
          planCatalogProvider.overrideWithValue(AsyncData(catalog())),
          storeBillingProvider.overrideWithValue(store),
          subscriptionRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const FamilyPlanScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mağaza fiyatı: ₺299,99'), findsNWidgets(2));
    await tester.tap(find.text('Yükselt').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devam et'));
    await tester.pumpAndSettle();
    expect(repo.checkouts.single, ('normal_family', 'monthly', 'app_store'));
    expect(store.bought.single.providerProductId, 'bebegimin.normal_family.monthly');
    expect(store.bought.single.intentId, '8d2c1a52-0000-4000-8000-000000000001');
  });

  testWidgets('without a store (web / desktop) no purchase is started', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    addTearDown(tester.view.resetPhysicalSize);
    final store = _FakeStore(null);
    final repo = _FakeRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          babiesProvider.overrideWithValue(AsyncData([defne])),
          activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
          familyAccountOverviewProvider(defne.id).overrideWithValue(AsyncData(overview())),
          planCatalogProvider.overrideWithValue(AsyncData(catalog())),
          storeBillingProvider.overrideWithValue(store),
          subscriptionRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const FamilyPlanScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yükselt').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devam et'));
    await tester.pumpAndSettle();
    expect(repo.checkouts, isEmpty);
    expect(find.textContaining('yalnızca iOS ve Android'), findsOneWidget);
  });
}
