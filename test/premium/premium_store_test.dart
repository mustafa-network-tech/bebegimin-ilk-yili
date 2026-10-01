import 'dart:async';

import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:bebegimin_ilk_yili/features/premium/application/premium_providers.dart';
import 'package:bebegimin_ilk_yili/features/premium/data/premium_repository.dart';
import 'package:bebegimin_ilk_yili/features/premium/domain/premium_models.dart';
import 'package:bebegimin_ilk_yili/features/premium/presentation/premium_store_screen.dart';
import 'package:bebegimin_ilk_yili/features/subscription/data/store_billing.dart';
import 'package:bebegimin_ilk_yili/features/subscription/domain/subscription_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';

class _FakeStore implements StoreBilling {
  final premium = <PremiumOrder>[];
  final _events = StreamController<StorePurchaseEvent>.broadcast();

  @override
  StoreProvider? get provider => StoreProvider.appStore;
  @override
  bool get isSupported => true;
  @override
  Stream<StorePurchaseEvent> get events => _events.stream;
  @override
  void start() {}
  @override
  Future<Map<String, String>> localizedPrices(Iterable<String> ids) async => const {};
  @override
  Future<void> buy(CheckoutIntent intent) async {}
  @override
  Future<void> buyPremium(PremiumOrder order) async => premium.add(order);
  @override
  Future<void> restore() async {}
  @override
  void dispose() => _events.close();
}

class _FakeRepo implements PremiumRepository {
  final requests = <(String, PremiumProduct, String)>[];

  @override
  Future<PremiumOrder> requestPurchase({
    required String babyId,
    required PremiumProduct product,
    required String provider,
  }) async {
    requests.add((babyId, product, provider));
    return PremiumOrder.fromJson({
      'order_id': '0b5c0000-0000-4000-8000-000000000001',
      'provider': provider,
      'provider_product_id': 'bebegimin.${product.code}',
      'product_code': product.code,
      'price_minor': 54900,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BabyLifecycle lifecycle({required bool locked}) => BabyLifecycle(
  babyId: defne.id,
  status: locked ? BabyLifecycleStatus.locked : BabyLifecycleStatus.active,
  businessDate: d(2026, 9, 29),
  baseCloseDate: d(2026, 9, 22),
  effectiveCloseDate: locked ? d(2026, 9, 22) : d(2026, 10, 22),
  remainingDays: locked ? 0 : 23,
  extensionStatus: null,
  approvedExtensionDays: 0,
  canRequestExtension: false,
);

PremiumOffer offer(String code, int price, {bool owned = false, String? block}) => PremiumOffer.fromJson({
  'product_code': code,
  'price_minor': price,
  'currency': 'TRY',
  'owned': owned,
  'purchase_block': owned ? 'already_owned' : block,
});

PremiumStoreView parentView({String? block}) => PremiumStoreView(
  isParent: true,
  offers: [
    offer('first_year_book', 34900, owned: true),
    offer('first_year_html', 44900, block: block),
    offer('first_year_film', 54900, block: block),
  ],
  owned: {PremiumProduct.book},
);

Future<void> _pump(
  WidgetTester tester, {
  required bool locked,
  PremiumStoreView? view,
  _FakeStore? store,
  _FakeRepo? repo,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        babiesProvider.overrideWithValue(AsyncData([defne])),
        babyLifecycleProvider(defne.id).overrideWithValue(AsyncData(lifecycle(locked: locked))),
        premiumStoreViewProvider(defne.id).overrideWithValue(AsyncData(view ?? parentView())),
        premiumStorePricesProvider.overrideWithValue(const AsyncData({})),
        storeBillingProvider.overrideWithValue(store ?? _FakeStore()),
        premiumRepositoryProvider.overrideWithValue(repo ?? _FakeRepo()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: PremiumStoreScreen(babyId: defne.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  test('products and refusal hints', () {
    expect(PremiumProduct.fromCode('first_year_film'), PremiumProduct.film);
    expect(PremiumProduct.book.format, 'PDF');
    expect(PremiumProduct.book.description, contains('Fiziksel / basılı kitap bu ürüne dahil değildir'));
    expect(PurchaseBlock.fromHint('subscription_required'), PurchaseBlock.subscriptionRequired);
    expect(PurchaseBlock.fromHint(null), isNull);
    expect(offer('first_year_film', 54900).canBuy, isTrue);
    expect(offer('first_year_film', 54900, owned: true).canBuy, isFalse);
  });

  testWidgets('ACTIVE archive: no storefront at all', (tester) async {
    await _pump(tester, locked: false);
    expect(find.text('İlk yıl devam ediyor'), findsOneWidget);
    expect(find.text('Satın al'), findsNothing);
    expect(find.textContaining('₺'), findsNothing);
  });

  testWidgets('LOCKED archive: three separate products with catalog prices', (tester) async {
    await _pump(tester, locked: true);
    expect(find.text('Dijital İlk Yıl Kitabı'), findsOneWidget);
    expect(find.text('Offline HTML Hatırası'), findsOneWidget);
    expect(find.text('İlk Yıl Filmi'), findsOneWidget);
    expect(find.text(formatMinor(44900)), findsOneWidget);
    expect(find.text(formatMinor(54900)), findsOneWidget);
    expect(find.textContaining('Fiziksel / basılı kitap bu ürüne dahil değildir'), findsOneWidget);
    // An owned product opens its own screen instead of "Satın al".
    expect(find.text('Kitabı aç'), findsOneWidget);
    // Parents of an owning family can share downloads with Family Members.
    expect(find.text('Aile üyeleriyle paylaş'), findsOneWidget);
    expect(find.text('Satın al'), findsNWidgets(2));
  });

  testWidgets('buying opens an order and starts the store purchase', (tester) async {
    final store = _FakeStore();
    final repo = _FakeRepo();
    await _pump(tester, locked: true, store: store, repo: repo);
    await tester.tap(find.text('Satın al').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('diğer ebeveyn ikinci kez ödeme yapmaz'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Satın al').last);
    await tester.pumpAndSettle();
    expect(repo.requests.single, (defne.id, PremiumProduct.film, 'app_store'));
    expect(store.premium.single.providerProductId, 'bebegimin.first_year_film');
  });

  testWidgets('without a live subscription the parent is sent to the family plan', (tester) async {
    await _pump(tester, locked: true, view: parentView(block: 'subscription_required'));
    expect(find.text('Satın al'), findsNothing);
    expect(find.text('Aile paketine git'), findsNWidgets(2));
  });

  testWidgets('storefront kill switch shows "coming soon"', (tester) async {
    await _pump(tester, locked: true, view: parentView(block: 'storefront_closed'));
    expect(find.text('Satın al'), findsNothing);
    expect(find.text('Yakında satışta.'), findsNWidgets(2));
  });

  testWidgets('family members see owned products, no prices, no purchase', (tester) async {
    await _pump(
      tester,
      locked: true,
      view: const PremiumStoreView(isParent: false, offers: [], owned: {PremiumProduct.book}),
    );
    expect(find.text('Dijital ürünleri Anne veya Baba satın alabilir.'), findsOneWidget);
    expect(find.textContaining('₺'), findsNothing);
    expect(find.text('Satın al'), findsNothing);
    expect(find.text('Kitabı aç'), findsOneWidget);
    expect(find.text('Aile üyeleriyle paylaş'), findsNothing);
  });
}
