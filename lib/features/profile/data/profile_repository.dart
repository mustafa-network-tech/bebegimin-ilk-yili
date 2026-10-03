import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../domain/profile.dart';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(supabaseProvider), ref.watch(localCacheProvider)),
);

/// The signed-in user's profile (null when signed out).
final myProfileProvider = FutureProvider<Profile?>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return null;
  return ref.watch(profileRepositoryProvider).fetch(uid);
});

class ProfileRepository {
  ProfileRepository(this._client, this._cache);

  final SupabaseClient _client;
  final LocalCache _cache;

  Future<Profile?> fetch(String uid) => _cache.networkFirst<Profile?>(
    key: 'profile.$uid',
    fetch: () async {
      final row = await _client.from('profiles').select().eq('id', uid).maybeSingle();
      return row == null ? null : Profile.fromJson(row);
    },
    encode: (p) => p?.toJson(),
    decode: (j) => j == null ? null : Profile.fromJson((j as Map).cast<String, dynamic>()),
  );

  Future<void> update(
    String uid, {
    String? displayName,
    bool? onboardingCompleted,
    Map<String, bool>? notificationPrefs,
    String? avatarPath,
  }) async {
    final patch = <String, dynamic>{
      'display_name': ?displayName?.trim(),
      'onboarding_completed': ?onboardingCompleted,
      'notification_prefs': ?notificationPrefs,
      'avatar_path': ?avatarPath,
    };
    if (patch.isEmpty) return;
    await _client.from('profiles').update(patch).eq('id', uid);
  }

  /// Uploads a new avatar (already compressed JPEG) and removes the old one.
  Future<String> uploadAvatar(String uid, File jpeg, {String? previousPath}) async {
    final path = '$uid/avatar-${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _client.storage
        .from(Buckets.avatars)
        .upload(
          path,
          jpeg,
          fileOptions: const FileOptions(contentType: 'image/jpeg', cacheControl: '3600'),
        );
    await update(uid, avatarPath: path);
    if (previousPath != null) {
      try {
        await _client.storage.from(Buckets.avatars).remove([previousPath]);
      } catch (_) {}
    }
    return path;
  }
}
