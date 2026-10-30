import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/premium_models.dart';

final premiumRepositoryProvider = Provider<PremiumRepository>((ref) => PremiumRepository(ref.watch(supabaseProvider)));

/// Premium storefront and entitlements. The app only opens an order; the
/// entitlement is granted by the server after the store verified payment.
class PremiumRepository {
  PremiumRepository(this._client);

  final SupabaseClient _client;

  Future<PremiumStoreView> storeView(String babyId) async {
    final ownedRows = await _client.rpc('baby_entitlements', params: {'p_baby_id': babyId}) as List;
    final owned = {for (final r in ownedRows.cast<Map>()) ?PremiumProduct.fromCode(r['product_code'] as String?)};
    try {
      final rows = await _client.rpc('premium_storefront', params: {'p_baby_id': babyId}) as List;
      return PremiumStoreView(
        isParent: true,
        offers: [for (final r in rows) PremiumOffer.fromJson((r as Map).cast<String, dynamic>())],
        owned: owned,
      );
    } on PostgrestException catch (e) {
      if (e.hint != 'not_parent') rethrow;
      return PremiumStoreView(isParent: false, offers: const [], owned: owned);
    }
  }

  Future<PremiumOrder> requestPurchase({
    required String babyId,
    required PremiumProduct product,
    required String provider,
  }) async {
    final rows = await _client.rpc(
      'request_premium_purchase',
      params: {'p_baby_id': babyId, 'p_product_code': product.code, 'p_provider': provider},
    ) as List;
    return PremiumOrder.fromJson((rows.single as Map).cast<String, dynamic>());
  }

  /// `product_code` → store product id for a provider.
  Future<Map<String, String>> storeProducts(String provider) async {
    final rows = await _client.rpc('premium_store_products', params: {'p_provider': provider}) as List;
    return {for (final r in rows.cast<Map>()) r['product_code'] as String: r['provider_product_id'] as String};
  }
}
