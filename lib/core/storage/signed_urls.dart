import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase_providers.dart';

abstract final class Buckets {
  static const babyMedia = 'baby-media';
  static const books = 'books';
  static const avatars = 'avatars';
}

final signedUrlCacheProvider = Provider<SignedUrlCache>(
  (ref) => SignedUrlCache(ref.watch(supabaseProvider)),
);

/// Private buckets are only reachable through short-lived signed URLs.
/// This cache signs each object once per hour and deduplicates requests.
class SignedUrlCache {
  SignedUrlCache(this._client);

  final SupabaseClient _client;
  static const _ttl = Duration(hours: 1);
  static const _safety = Duration(minutes: 5);

  final _cache = <String, ({String url, DateTime expires})>{};
  final _inFlight = <String, Future<String>>{};

  String _key(String bucket, String path) => '$bucket/$path';

  /// Stable cache key for image caches – survives URL re-signing so photos
  /// seen once stay available offline.
  static String cacheKey(String bucket, String path) => '$bucket/$path';

  String? peek(String bucket, String path) {
    final hit = _cache[_key(bucket, path)];
    if (hit != null && hit.expires.isAfter(DateTime.now())) return hit.url;
    return null;
  }

  Future<String> url(String bucket, String path) {
    final key = _key(bucket, path);
    final cached = peek(bucket, path);
    if (cached != null) return Future.value(cached);
    return _inFlight[key] ??= _client.storage
        .from(bucket)
        .createSignedUrl(path, _ttl.inSeconds)
        .then((url) {
          _cache[key] = (url: url, expires: DateTime.now().add(_ttl - _safety));
          return url;
        })
        .whenComplete(() => _inFlight.remove(key));
  }

  /// Signs many objects with one request (grids, timelines).
  Future<void> prefetch(String bucket, Iterable<String> paths) async {
    final missing = paths.where((p) => peek(bucket, p) == null && !_inFlight.containsKey(_key(bucket, p))).toSet().toList();
    if (missing.isEmpty) return;
    for (var i = 0; i < missing.length; i += 100) {
      final chunk = missing.sublist(i, (i + 100).clamp(0, missing.length));
      try {
        final signed = await _client.storage.from(bucket).createSignedUrlsResult(chunk, _ttl.inSeconds);
        final expires = DateTime.now().add(_ttl - _safety);
        for (final s in signed.whereType<SignedUrlSuccess>()) {
          _cache[_key(bucket, s.path)] = (url: s.signedUrl, expires: expires);
        }
      } catch (_) {
        // Individual widgets will retry on their own.
      }
    }
  }

  void evict(String bucket, String path) => _cache.remove(_key(bucket, path));

  void clear() => _cache.clear();
}
