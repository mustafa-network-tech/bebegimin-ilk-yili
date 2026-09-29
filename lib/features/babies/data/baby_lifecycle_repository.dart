import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/supabase_providers.dart';
import '../domain/baby_lifecycle.dart';

final babyLifecycleRepositoryProvider = Provider<BabyLifecycleRepository>(
  (ref) => BabyLifecycleRepository(ref.watch(supabaseProvider), ref.watch(localCacheProvider)),
);

class BabyLifecycleRepository {
  BabyLifecycleRepository(this._client, this._cache);

  final SupabaseClient _client;
  final LocalCache _cache;

  /// Server summary. Offline, the last server answer for this user and baby
  /// is used; callers must still apply [BabyLifecycle.tightenedFor].
  Future<BabyLifecycle> summary(String babyId) => _cache.networkFirst<BabyLifecycle>(
    key: LocalCache.userBabyKey(
      userId: _client.auth.currentUser?.id ?? 'signed-out',
      babyId: babyId,
      resource: 'lifecycle',
    ),
    fetch: () => _fetch(babyId),
    encode: (value) => value.toJson(),
    decode: (json) => BabyLifecycle.fromJson((json as Map).cast<String, dynamic>()),
  );

  Future<BabyLifecycle> _fetch(String babyId) async {
    final response = await _client.rpc('baby_lifecycle_summary', params: {'p_baby_id': babyId});
    final row = switch (response) {
      final List<dynamic> rows when rows.isNotEmpty => (rows.first as Map).cast<String, dynamic>(),
      final Map<dynamic, dynamic> map => map.cast<String, dynamic>(),
      _ => throw const FormatException('Lifecycle summary response is empty.'),
    };
    return BabyLifecycle.fromJson(row);
  }

  Future<void> requestExtension({required String babyId, required int days}) =>
      _client.rpc('request_baby_extension', params: {'p_baby_id': babyId, 'p_days': days});

  Future<String> decideExtension({required String requestId, required String decision, String? note}) async {
    final response = await _client.rpc(
      'decide_baby_extension',
      params: {'p_request_id': requestId, 'p_decision': decision, 'p_note': note},
    );
    return response as String;
  }
}
