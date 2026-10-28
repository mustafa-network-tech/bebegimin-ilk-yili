import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/store_billing.dart';
import '../domain/subscription_models.dart';

/// Whether the app should quietly ask the store for the account's purchases.
///
/// A renewal, a refund or a plan change made in the store never passes through the
/// app, so the server may be unaware of the newest purchase token. Asking costs
/// little (the store answers from its cache) and each result is verified by the
/// server, so the app never shows an unverified subscription as active.
bool shouldAutoRestore({
  required FamilyAccountOverview? overview,
  required DateTime now,
  required DateTime? lastAttempt,
  required bool inFlight,
  required bool supported,
  Duration minGap = const Duration(hours: 6),
  Duration lead = const Duration(days: 3),
}) {
  if (!supported || inFlight || overview == null) return false;
  if (!overview.isParent || overview.testAccess) return false;
  if (lastAttempt != null && now.difference(lastAttempt) < minGap) return false;
  final sub = overview.subscription;
  if (sub == null) return false; // nothing was ever bought: no reason to nag the store
  // Ended / on hold: the user may have renewed, resubscribed or changed plan in the store.
  if (sub.status == 'expired' || sub.status == 'canceled' || sub.status == 'past_due') return true;
  final end = sub.currentPeriodEnd;
  // Renewal due soon or overdue (the server has not seen the new period yet).
  return end != null && !end.isAfter(now.add(lead));
}

final autoRestoreProvider = Provider<AutoRestore>((ref) => AutoRestore(ref.read(storeBillingProvider)));

/// Runs at most one quiet restore at a time and at most every few hours.
class AutoRestore {
  AutoRestore(this._billing);

  final StoreBilling _billing;
  bool _inFlight = false;
  DateTime? _lastAttempt;

  /// Returns whether a restore was started.
  Future<bool> maybeRun(FamilyAccountOverview? overview, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    if (!shouldAutoRestore(
      overview: overview,
      now: at,
      lastAttempt: _lastAttempt,
      inFlight: _inFlight,
      supported: _billing.isSupported,
    )) {
      return false;
    }
    _inFlight = true;
    _lastAttempt = at;
    try {
      await _billing.restore(silent: true);
      return true;
    } catch (_) {
      return false; // offline / store unavailable: never blocks the app
    } finally {
      _inFlight = false;
    }
  }
}
