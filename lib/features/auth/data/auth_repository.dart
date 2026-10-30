import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/env.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../../babies/application/baby_providers.dart';
import '../../media/data/upload_queue.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(supabaseProvider), () async {
    await ref.read(uploadQueueProvider.notifier).clearAll();
    await ref.read(localCacheProvider).clear();
    ref.read(signedUrlCacheProvider).clear();
    await ref.read(activeBabyIdProvider.notifier).select(null);
  }),
);

class AuthRepository {
  AuthRepository(this._client, this._clearSensitiveState);

  final SupabaseClient _client;
  final Future<void> Function() _clearSensitiveState;

  GoTrueClient get _auth => _client.auth;

  Future<void> signIn({required String email, required String password}) =>
      _auth.signInWithPassword(email: email.trim(), password: password);

  /// Returns `true` when a session was created immediately (e-mail
  /// confirmation disabled), `false` when the user must verify the e-mail.
  Future<bool> signUp({required String email, required String password, required String displayName}) async {
    final res = await _auth.signUp(
      email: email.trim(),
      password: password,
      data: {'display_name': displayName.trim()},
      emailRedirectTo: Env.authRedirectUrl,
    );
    return res.session != null;
  }

  Future<void> resendVerification(String email) =>
      _auth.resend(type: OtpType.signup, email: email.trim(), emailRedirectTo: Env.authRedirectUrl);

  Future<void> sendPasswordReset(String email) =>
      _auth.resetPasswordForEmail(email.trim(), redirectTo: Env.authRedirectUrl);

  Future<void> updatePassword(String newPassword) => _auth.updateUser(UserAttributes(password: newPassword));

  Future<void> signOut() async {
    await _clearSensitiveState();
    await _auth.signOut();
  }

  /// Deletes the account through the `privacy-actions` Edge Function
  /// (needs the service role, which never ships with the app).
  /// Babies the user is alone on as a parent: they must be deleted before
  /// the account (decision P-10). Names only, for the settings screen.
  Future<List<String>> accountDeletionBlockers() async {
    final rows = await _client.rpc('account_deletion_blockers') as List;
    return [for (final r in rows) (r as Map)['first_name'] as String];
  }

  Future<void> deleteAccount({required bool deleteMyContent}) async {
    await _client.functions.invoke(
      'privacy-actions',
      body: {'action': 'delete_account', 'delete_content': deleteMyContent},
    );
    await _clearSensitiveState();
    await _auth.signOut(scope: SignOutScope.local);
  }
}
