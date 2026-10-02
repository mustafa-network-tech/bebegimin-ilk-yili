import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../babies/application/baby_providers.dart';
import '../data/store_billing.dart';
import '../data/subscription_repository.dart';
import '../domain/subscription_models.dart';

final planCatalogProvider = FutureProvider<PlanCatalog>((ref) => ref.watch(subscriptionRepositoryProvider).catalog());

final familyAccountIdProvider = FutureProvider.family<String?, String>(
  (ref, babyId) => ref.watch(subscriptionRepositoryProvider).accountIdForBaby(babyId),
);

/// Family plan overview for a baby's account (`null` if not mapped yet).
/// Refetched after purchases, on app resume and after server refusals.
final familyAccountOverviewProvider = FutureProvider.autoDispose.family<FamilyAccountOverview?, String>((
  ref,
  babyId,
) async {
  ref.watch(lifecycleRevisionProvider);
  final accountId = await ref.watch(familyAccountIdProvider(babyId).future);
  if (accountId == null) return null;
  return ref.watch(subscriptionRepositoryProvider).overview(accountId);
});

/// Store-localized prices keyed by `<plan_code>.<billing_period>`; empty on
/// platforms without a store or when the store is unreachable.
final storePricesProvider = FutureProvider<Map<String, String>>((ref) async {
  final store = ref.watch(storeBillingProvider);
  final provider = store.provider;
  if (provider == null) return const {};
  try {
    final products = await ref.watch(subscriptionRepositoryProvider).storeProducts(provider.key);
    final prices = await store.localizedPrices(products.values);
    return {for (final e in products.entries) e.key: ?prices[e.value]};
  } catch (_) {
    return const {};
  }
});

/// Server decision for a baby: `allowed` = the family may write. Without an
/// active family subscription the archive is read-only (decision P-2).
final babyAccessStateProvider = FutureProvider.family<BabyAccessState, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(subscriptionRepositoryProvider).accessState(babyId);
});

/// True once the server reports that the family subscription is inactive:
/// the archive stays readable, nothing can be added or changed (P-2).
final babySubscriptionReadOnlyProvider = Provider.family<bool, String>(
  (ref, babyId) => ref.watch(babyAccessStateProvider(babyId)).value?.allowed == false,
);

/// Access state of the selected baby (drives the read-only banner).
final activeAccessGateProvider = Provider<BabyAccessState?>((ref) {
  final baby = ref.watch(activeBabyProvider);
  if (baby == null) return null;
  return ref.watch(babyAccessStateProvider(baby.id)).value;
});
