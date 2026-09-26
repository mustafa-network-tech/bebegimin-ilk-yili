import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/env.dart';
import '../../../core/supabase_providers.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(ref.watch(supabaseProvider)));

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

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

  Future<void> signOut() => _auth.signOut();

  /// Deletes the account through the `privacy-actions` Edge Function
  /// (needs the service role, which never ships with the app).
  Future<void> deleteAccount({required bool deleteMyContent}) async {
    await _client.functions.invoke(
      'privacy-actions',
      body: {'action': 'delete_account', 'delete_content': deleteMyContent},
    );
    await _auth.signOut(scope: SignOutScope.local);
  }
}
