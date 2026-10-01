import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../subscription/data/store_billing.dart';
import '../data/premium_repository.dart';
import '../domain/premium_models.dart';

/// Storefront (parents) and owned products (everyone) of one baby; refetched
/// after purchases, on resume and after server refusals.
final premiumStoreViewProvider = FutureProvider.autoDispose.family<PremiumStoreView, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(premiumRepositoryProvider).storeView(babyId);
});

/// Store-localized premium prices keyed by product code.
final premiumStorePricesProvider = FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final store = ref.watch(storeBillingProvider);
  final provider = store.provider;
  if (provider == null) return const {};
  try {
    final products = await ref.watch(premiumRepositoryProvider).storeProducts(provider.key);
    final prices = await store.localizedPrices(products.values);
    return {for (final e in products.entries) e.key: ?prices[e.value]};
  } catch (_) {
    return const {};
  }
});

/// Download sharing rows of one baby (parents).
final downloadPermissionsProvider = FutureProvider.autoDispose.family<List<DownloadPermission>, String>(
  (ref, babyId) => ref.watch(premiumRepositoryProvider).downloadPermissions(babyId),
);
