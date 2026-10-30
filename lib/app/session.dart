import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_providers.dart';

/// Set when the user opened a password-reset link.
final passwordRecoveryProvider = NotifierProvider<PasswordRecovery, bool>(PasswordRecovery.new);

class PasswordRecovery extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(authStateProvider, (_, next) {
      final event = next.value?.event;
      if (event == AuthChangeEvent.passwordRecovery) state = true;
      if (event == AuthChangeEvent.signedOut) state = false;
    });
    return false;
  }

  void clear() => state = false;
}

/// Invitation code opened through a link before the user was signed in /
/// onboarded; consumed by the join screen.
final pendingInviteCodeProvider = NotifierProvider<PendingInviteCode, String?>(PendingInviteCode.new);

class PendingInviteCode extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? code) => state = code;
}
