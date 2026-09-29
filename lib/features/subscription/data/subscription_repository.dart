import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/subscription_models.dart';

final subscriptionRepositoryProvider = Provider<SubscriptionRepository>(
  (ref) => SubscriptionRepository(ref.watch(supabaseProvider)),
);

/// Family account and subscription read models. The app can only open a
/// checkout intent; plans are activated exclusively by verified provider
/// events on the server.
class SubscriptionRepository {
  SubscriptionRepository(this._client);

  final SupabaseClient _client;

  Future<PlanCatalog> catalog() async {
    final rows = await _client.rpc('subscription_plan_catalog') as List;
    return PlanCatalog([for (final r in rows) PlanCatalogItem.fromJson((r as Map).cast<String, dynamic>())]);
  }

  /// `null` while a legacy baby is not mapped to a family account yet.
  Future<String?> accountIdForBaby(String babyId) async =>
      await _client.rpc('family_account_id_for_baby', params: {'p_baby_id': babyId}) as String?;

  Future<FamilyAccountOverview> overview(String accountId) async {
    final json = await _client.rpc('family_account_overview', params: {'p_family_account_id': accountId});
    return FamilyAccountOverview.fromJson((json as Map).cast<String, dynamic>());
  }

  /// `<plan_code>.<billing_period>` → store product id for a provider.
  Future<Map<String, String>> storeProducts(String provider) async {
    final rows = await _client.rpc('subscription_store_products', params: {'p_provider': provider}) as List;
    return {
      for (final r in rows.cast<Map>()) '${r['plan_code']}.${r['billing_period']}': r['provider_product_id'] as String,
    };
  }

  Future<BabyAccessState> accessState(String babyId) async {
    final rows = await _client.rpc('baby_access_state', params: {'p_baby_id': babyId}) as List;
    return BabyAccessState.fromJson(babyId, (rows.single as Map).cast<String, dynamic>());
  }

  /// Sends a store receipt to the server, which verifies it with Apple /
  /// Google and binds it to the caller's family account (parents only).
  /// Returns the server's routing (`subscription` / `premium`) and result.
  Future<({String kind, String result})> verifyPurchase({
    required String provider,
    required String verificationData,
    required String productId,
    String? checkoutIntentId,
    String? orderId,
  }) async {
    final res = await _client.functions.invoke(
      'billing-verify-purchase',
      body: {
        'provider': provider,
        'verification_data': verificationData,
        'product_id': productId,
        'checkout_intent_id': ?checkoutIntentId,
        'order_id': ?orderId,
      },
    );
    final data = res.data as Map?;
    return (kind: (data?['kind'] as String?) ?? 'unknown', result: (data?['result'] as String?) ?? 'unknown');
  }

  Future<CheckoutIntent> requestCheckout({
    required String accountId,
    required String planCode,
    required BillingPeriod period,
    String? provider,
  }) async {
    final rows = await _client.rpc(
      'request_subscription_checkout',
      params: {
        'p_family_account_id': accountId,
        'p_plan_code': planCode,
        'p_billing_period': period.key,
        'p_provider': ?provider,
      },
    ) as List;
    return CheckoutIntent.fromJson((rows.single as Map).cast<String, dynamic>());
  }
}
