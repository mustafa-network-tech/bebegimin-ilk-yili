import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../errors/app_exception.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('overridden in main()'),
);

final localCacheProvider = Provider<LocalCache>((ref) => LocalCache(ref.watch(sharedPreferencesProvider)));

/// Small JSON cache for "last seen" data so the app still shows something
/// useful without a connection. Never used for authorisation decisions.
class LocalCache {
  LocalCache(this._prefs);

  final SharedPreferences _prefs;
  static const _prefix = 'cache.v1.';

  static String userBabyKey({required String userId, required String babyId, required String resource}) =>
      'user.$userId.baby.$babyId.$resource';

  Future<void> put(String key, Object? json) => _prefs.setString('$_prefix$key', jsonEncode(json));

  Object? get(String key) {
    final raw = _prefs.getString('$_prefix$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await _prefs.remove(k);
    }
  }

  /// Network first; on a *network* error fall back to the cached copy.
  Future<T> networkFirst<T>({
    required String key,
    required Future<T> Function() fetch,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) async {
    try {
      final value = await fetch();
      await put(key, encode(value));
      return value;
    } catch (e) {
      if (AppException.isNetworkError(e)) {
        final cached = get(key);
        if (cached != null) return decode(cached);
      }
      rethrow;
    }
  }
}
