import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart' show ReplacementMode;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../../core/errors/app_exception.dart';
import '../../premium/domain/premium_models.dart';
import '../domain/subscription_models.dart';
import 'subscription_repository.dart';

/// Store of the running platform (`null` on web / desktop).
enum StoreProvider {
  appStore('app_store'),
  googlePlay('google_play');

  const StoreProvider(this.key);

  final String key;

  static StoreProvider? get current {
    if (kIsWeb) return null;
    if (Platform.isIOS) return appStore;
    if (Platform.isAndroid) return googlePlay;
    return null;
  }
}

/// Google Play mapping `<productId>:<basePlanId>` (see the provider product table).
class GoogleProductRef {
  const GoogleProductRef(this.productId, this.basePlanId);

  static GoogleProductRef parse(String value) {
    final i = value.indexOf(':');
    if (i <= 0 || i == value.length - 1) throw FormatException('Invalid Google Play product id: $value');
    return GoogleProductRef(value.substring(0, i), value.substring(i + 1));
  }

  final String productId;
  final String basePlanId;
}

enum StorePurchaseStatus { pending, verified, canceled, failed }

/// What to do with a purchase after the server answered.
enum VerifyDecision { granted, pending, inactive, notActivated }

/// Success needs the server's explicit `granted: true`. `rejected`, `duplicate`
/// or `stale` alone, an unknown result or an older server's reply without
/// `granted` never count as an activated subscription.
@visibleForTesting
VerifyDecision decideVerification({required bool granted, required String result}) {
  if (granted) return VerifyDecision.granted;
  if (result == 'pending') return VerifyDecision.pending;
  if (result == 'inactive') return VerifyDecision.inactive;
  return VerifyDecision.notActivated;
}

class StorePurchaseEvent {
  const StorePurchaseEvent(this.status, [this.message]);

  final StorePurchaseStatus status;
  final String? message;
}

final storeBillingProvider = Provider<StoreBilling>((ref) {
  final billing = InAppStoreBilling(ref);
  ref.onDispose(billing.dispose);
  return billing;
});

/// App Store / Google Play subscriptions. Purchases are only *started* here;
/// the server verifies every receipt with the store and binds it to the
/// family account before access opens.
abstract class StoreBilling {
  /// Store of this device (`null` = purchases not possible here).
  StoreProvider? get provider;
  bool get isSupported;
  Stream<StorePurchaseEvent> get events;
  void start();
  Future<Map<String, String>> localizedPrices(Iterable<String> storeProductIds);

  /// [currentPlanCode] is the plan code of the family's live subscription (if
  /// any): on Google Play only that subscription may be replaced by a plan change.
  Future<void> buy(CheckoutIntent intent, {String? currentPlanCode});

  /// One-time premium product (consumable in the store; the server keeps the
  /// permanent, baby-scoped entitlement).
  Future<void> buyPremium(PremiumOrder order);

  /// Asks the store for the purchases of this account; each one is verified by the
  /// server before anything is granted. [silent] (automatic restore) suppresses
  /// failure messages: the user did not ask for it.
  Future<void> restore({bool silent = false});
  void dispose();
}

class InAppStoreBilling implements StoreBilling {
  InAppStoreBilling(this._ref);

  final Ref _ref;
  final _events = StreamController<StorePurchaseEvent>.broadcast();
  final _intentByStoreProduct = <String, String>{};
  final _orderByStoreProduct = <String, String>{};
  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _restoring = false;
  DateTime? _silentUntil;

  InAppPurchase get _iap => InAppPurchase.instance;
  StoreProvider? get _store => StoreProvider.current;

  @override
  StoreProvider? get provider => _store;

  @override
  bool get isSupported => _store != null;

  @override
  Stream<StorePurchaseEvent> get events => _events.stream;

  /// Listens from app start so interrupted purchases are finished later.
  @override
  void start() {
    if (!isSupported || _sub != null) return;
    _sub = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) {
        _events.add(StorePurchaseEvent(StorePurchaseStatus.failed, AppException.from(e).message));
      },
    );
  }

  @override
  Future<Map<String, String>> localizedPrices(Iterable<String> storeProductIds) async {
    final store = _store;
    if (store == null || !await _iap.isAvailable()) return const {};
    if (store == StoreProvider.appStore) {
      final res = await _iap.queryProductDetails(storeProductIds.toSet());
      return {for (final p in res.productDetails) p.id: p.price};
    }
    // Google one-time products have plain ids; subscriptions are productId:basePlanId.
    final oneTime = storeProductIds.where((id) => !id.contains(':')).toSet();
    final prices = <String, String>{};
    if (oneTime.isNotEmpty) {
      final res = await _iap.queryProductDetails(oneTime);
      prices.addAll({for (final p in res.productDetails) p.id: p.price});
    }
    final refs = {for (final id in storeProductIds.where((id) => id.contains(':'))) id: GoogleProductRef.parse(id)};
    if (refs.isEmpty) return prices;
    final res = await _iap.queryProductDetails(refs.values.map((r) => r.productId).toSet());
    return {
      ...prices,
      for (final e in refs.entries)
        if (_googleOffer(res.productDetails, e.value) case final d?) e.key: d.price,
    };
  }

  /// The base-plan offer (no promotional offer id) for a Google product ref.
  GooglePlayProductDetails? _googleOffer(List<ProductDetails> details, GoogleProductRef ref) {
    return details.whereType<GooglePlayProductDetails>().firstWhereOrNull((d) {
      final offers = d.productDetails.subscriptionOfferDetails;
      final index = d.subscriptionIndex;
      if (d.id != ref.productId || offers == null || index == null) return false;
      return offers[index].basePlanId == ref.basePlanId && offers[index].offerId == null;
    });
  }

  @override
  Future<void> buy(CheckoutIntent intent, {String? currentPlanCode}) async {
    _silentUntil = null; // a purchase the user started always reports its failures
    final store = _store;
    if (store == null) throw const AppException('Satın alma yalnızca iOS ve Android uygulamasında yapılabilir.');
    if (!await _iap.isAvailable()) {
      throw const AppException('Mağazaya şu an ulaşılamıyor. Lütfen daha sonra tekrar deneyin.');
    }
    PurchaseParam param;
    if (store == StoreProvider.appStore) {
      final res = await _iap.queryProductDetails({_storeId(intent)});
      final product = res.productDetails.firstOrNull;
      if (product == null) throw const AppException('Paket mağazada bulunamadı.');
      // StoreKit 2 stores this UUID as appAccountToken; the server reads it
      // back from the signed transaction to bind the purchase to the family.
      param = PurchaseParam(productDetails: product, applicationUserName: intent.intentId);
    } else {
      final ref = GoogleProductRef.parse(_storeId(intent));
      final res = await _iap.queryProductDetails({ref.productId});
      if (res.error != null) {
        throw const AppException('Mağazaya şu an ulaşılamıyor. Lütfen daha sonra tekrar deneyin.');
      }
      final product = _googleOffer(res.productDetails, ref);
      if (product == null) {
        // Product missing in Play vs. product present but this base plan inactive / not offered.
        throw AppException(
          res.notFoundIDs.contains(ref.productId)
              ? "Bu paket Google Play'de tanımlı değil."
              : "Seçtiğiniz paket seçeneği şu an Google Play'de kullanılamıyor.",
        );
      }
      final offer = product.productDetails.subscriptionOfferDetails![product.subscriptionIndex!];
      final current = await _replaceableGoogleSubscription(currentPlanCode);
      param = GooglePlayPurchaseParam(
        productDetails: product,
        applicationUserName: intent.intentId, // obfuscatedAccountId
        offerToken: offer.offerIdToken,
        changeSubscriptionParam: current == null
            ? null
            : ChangeSubscriptionParam(oldPurchaseDetails: current, replacementMode: ReplacementMode.withTimeProration),
      );
    }
    _intentByStoreProduct[param.productDetails.id] = intent.intentId;
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> buyPremium(PremiumOrder order) async {
    _silentUntil = null;
    final store = _store;
    if (store == null) throw const AppException('Satın alma yalnızca iOS ve Android uygulamasında yapılabilir.');
    if (order.provider != store.key) throw const AppException('Sipariş bu mağaza için hazırlanmadı.');
    if (!await _iap.isAvailable()) {
      throw const AppException('Mağazaya şu an ulaşılamıyor. Lütfen daha sonra tekrar deneyin.');
    }
    final res = await _iap.queryProductDetails({order.providerProductId});
    final product = res.productDetails.firstOrNull;
    if (product == null) throw const AppException('Ürün mağazada bulunamadı.');
    // The order id comes back in the verified receipt (appAccountToken /
    // obfuscatedAccountId) and binds the payment to this baby and family.
    final param = store == StoreProvider.googlePlay
        ? GooglePlayPurchaseParam(productDetails: product, applicationUserName: order.orderId)
        : PurchaseParam(productDetails: product, applicationUserName: order.orderId);
    _orderByStoreProduct[product.id] = order.orderId;
    // Consumed only after the server granted the entitlement (see _verify).
    await _iap.buyConsumable(purchaseParam: param, autoConsume: false);
  }

  String _storeId(CheckoutIntent intent) {
    if (intent.provider != _store?.key) throw const AppException('Paket bu mağaza için hazırlanmadı.');
    return intent.providerProductId;
  }

  /// The Google subscription a plan change replaces: only the family's own
  /// live subscription product. One-time products, unverified (unacknowledged)
  /// purchases and other subscriptions on this Google account are never used.
  Future<GooglePlayPurchaseDetails?> _replaceableGoogleSubscription(String? currentPlanCode) async {
    if (currentPlanCode == null) return null;
    final addition = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final past = await addition.queryPastPurchases();
    if (past.error != null) return null; // buy as a new subscription; never guess
    return past.pastPurchases.whereType<GooglePlayPurchaseDetails>().firstWhereOrNull(
      (p) => isReplaceableSubscription(
        productId: p.productID,
        purchased: p.status == PurchaseStatus.purchased,
        acknowledged: p.billingClientPurchase.isAcknowledged,
        currentPlanCode: currentPlanCode,
      ),
    );
  }

  /// Plan codes are the Google subscription product ids (`small_family` …).
  @visibleForTesting
  static bool isReplaceableSubscription({
    required String productId,
    required bool purchased,
    required bool acknowledged,
    required String currentPlanCode,
  }) => productId == currentPlanCode && purchased && acknowledged;

  @override
  Future<void> restore({bool silent = false}) async {
    if (!isSupported) throw const AppException('Geri yükleme yalnızca iOS ve Android uygulamasında yapılabilir.');
    if (_restoring) return; // one restore at a time
    _restoring = true;
    // Purchases arrive on the purchase stream a little later; failures in that window stay quiet.
    _silentUntil = silent ? DateTime.now().add(const Duration(seconds: 45)) : null;
    try {
      await _iap.restorePurchases().timeout(const Duration(seconds: 20));
    } finally {
      _restoring = false;
    }
  }

  void _emitFailure(String? message) {
    final until = _silentUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    _events.add(StorePurchaseEvent(StorePurchaseStatus.failed, message));
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          _events.add(const StorePurchaseEvent(StorePurchaseStatus.pending));
        case PurchaseStatus.canceled:
          _events.add(const StorePurchaseEvent(StorePurchaseStatus.canceled));
          await _complete(p);
        case PurchaseStatus.error:
          _events.add(StorePurchaseEvent(StorePurchaseStatus.failed, p.error?.message));
          await _complete(p);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verify(p);
      }
    }
  }

  Future<void> _verify(PurchaseDetails p) async {
    final store = _store!;
    try {
      final verified = await _ref
          .read(subscriptionRepositoryProvider)
          .verifyPurchase(
            provider: store.key,
            verificationData: p.verificationData.serverVerificationData,
            productId: p.productID,
            checkoutIntentId: _intentByStoreProduct[p.productID],
            orderId: _orderByStoreProduct[p.productID],
          );
      switch (decideVerification(granted: verified.granted, result: verified.result)) {
        case VerifyDecision.pending:
          // Payment not settled yet: nothing is granted and nothing is acknowledged.
          _events.add(const StorePurchaseEvent(StorePurchaseStatus.pending));
          return;
        case VerifyDecision.inactive:
          // Verified with the store but expired / refunded: no access to open.
          _forget(p);
          await _complete(p);
          _emitFailure('Bu satın alma artık geçerli değil.');
          return;
        case VerifyDecision.notActivated:
          // Left unfinished (never acknowledged): the store delivers it again, and
          // Google refunds purchases that are not acknowledged within three days.
          _emitFailure(_notActivated);
          return;
        case VerifyDecision.granted:
          break;
      }
      // Access / the entitlement exists on the server: only now acknowledge.
      _forget(p);
      await _complete(p);
      if (verified.kind == 'premium' && store == StoreProvider.googlePlay) {
        // Lets the family buy the same product for another baby later. A failure
        // here must not undo the grant; the store keeps the purchase until retried.
        try {
          await _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>().consumePurchase(p);
        } catch (_) {}
      }
      _ref.read(lifecycleRevisionProvider.notifier).bump(); // refresh access / plan
      _events.add(const StorePurchaseEvent(StorePurchaseStatus.verified));
    } on FunctionException catch (e) {
      if (AppException.functionErrorCode(e) == 'purchase_not_yours') {
        // Belongs to another family account: never retried, never applied here.
        _forget(p);
        await _complete(p);
      }
      // Every other failure leaves the purchase unfinished so it is verified again.
      _emitFailure(AppException.from(e).message);
    } catch (e) {
      _emitFailure(AppException.from(e).message);
    }
  }

  static const _notActivated = 'Satın alma doğrulanamadı. Aboneliğiniz etkinleştirilmedi.';

  void _forget(PurchaseDetails p) {
    _intentByStoreProduct.remove(p.productID);
    _orderByStoreProduct.remove(p.productID);
  }

  Future<void> _complete(PurchaseDetails p) async {
    if (!p.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(p);
    } catch (_) {
      // The server may have acknowledged the purchase first; the entitlement is already stored.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _events.close();
  }
}
