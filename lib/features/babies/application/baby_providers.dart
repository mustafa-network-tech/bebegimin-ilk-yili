import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../data/baby_repository.dart';
import '../domain/baby.dart';

final babiesProvider = FutureProvider<List<Baby>>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return const [];
  return ref.watch(babyRepositoryProvider).myBabies(uid);
});

/// Selected child (persisted). `null` → first baby.
final activeBabyIdProvider = NotifierProvider<ActiveBabyId, String?>(ActiveBabyId.new);

class ActiveBabyId extends Notifier<String?> {
  static const _key = 'active_baby_id';

  @override
  String? build() => ref.read(sharedPreferencesProvider).getString(_key);

  Future<void> select(String? id) async {
    final changedBaby = state != null && id != null && state != id;
    if (changedBaby) {
      await ref.read(localCacheProvider).clear();
      ref.read(signedUrlCacheProvider).clear();
    }
    state = id;
    final prefs = ref.read(sharedPreferencesProvider);
    if (id == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, id);
    }
  }
}

final activeBabyProvider = Provider<Baby?>((ref) {
  final babies = ref.watch(babiesProvider).value ?? const <Baby>[];
  final id = ref.watch(activeBabyIdProvider);
  return babies.firstWhereOrNull((b) => b.id == id) ?? babies.firstOrNull;
});

/// Route-scoped baby. Detail screens must use this instead of the active
/// navigation selection, which is only a UI convenience.
final babyByIdProvider = Provider.family<Baby?, String>((ref, babyId) {
  final babies = ref.watch(babiesProvider).value ?? const <Baby>[];
  return babies.firstWhereOrNull((baby) => baby.id == babyId);
});

final babyStatsProvider = FutureProvider.autoDispose.family<BabyStats, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(babyRepositoryProvider).stats(babyId);
});
