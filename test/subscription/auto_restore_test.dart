import 'dart:async';

import 'package:bebegimin_ilk_yili/features/premium/domain/premium_models.dart';
import 'package:bebegimin_ilk_yili/features/subscription/application/auto_restore.dart';
import 'package:bebegimin_ilk_yili/features/subscription/data/store_billing.dart';
import 'package:bebegimin_ilk_yili/features/subscription/domain/subscription_models.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 11, 1, 12);

FamilyAccountOverview _overview({
  String role = 'parent',
  String? status = 'active',
  DateTime? end,
  bool testAccess = false,
}) => FamilyAccountOverview.fromJson({
  'id': 'acct-1',
  'display_name': 'Aile',
  'my_role': role,
  'subscription': status == null
      ? null
      : {
          'plan_code': 'small_family',
          'billing_period': 'monthly',
          'status': status,
          'current_period_end': end?.toIso8601String(),
          'cancel_at_period_end': false,
          'over_capacity': false,
          'max_family_members': 3,
          'price_minor': 29900,
        },
  'subscription_live': status == 'active',
  'test_access': testAccess,
  'enforcement': true,
  'active_parents': 1,
  'active_family_members': 1,
  'babies': const [],
  'members': const [],
});

bool _should({FamilyAccountOverview? overview, DateTime? lastAttempt, bool inFlight = false, bool supported = true}) =>
    shouldAutoRestore(
      overview: overview,
      now: _now,
      lastAttempt: lastAttempt,
      inFlight: inFlight,
      supported: supported,
    );

class _Store implements StoreBilling {
  _Store({this.supported = true, this.fail = false});

  final bool supported;
  final bool fail;
  final started = Completer<void>();
  Completer<void>? hold;
  final silentFlags = <bool>[];

  @override
  bool get isSupported => supported;
  @override
  StoreProvider? get provider => StoreProvider.googlePlay;
  @override
  Stream<StorePurchaseEvent> get events => const Stream.empty();
  @override
  void start() {}
  @override
  Future<Map<String, String>> localizedPrices(Iterable<String> ids) async => {};
  @override
  Future<void> buy(CheckoutIntent intent, {String? currentPlanCode}) async {}
  @override
  Future<void> buyPremium(PremiumOrder order) async {}
  @override
  Future<void> restore({bool silent = false}) async {
    silentFlags.add(silent);
    if (hold != null) await hold!.future;
    if (fail) throw Exception('offline');
  }

  @override
  void dispose() {}
}

void main() {
  group('shouldAutoRestore', () {
    test('renewal due within three days, or overdue, triggers a restore', () {
      expect(_should(overview: _overview(end: _now.add(const Duration(days: 2)))), isTrue);
      expect(_should(overview: _overview(end: _now.subtract(const Duration(hours: 5)))), isTrue);
      expect(_should(overview: _overview(end: _now.subtract(const Duration(days: 10)))), isTrue);
    });

    test('a renewal far away does not', () {
      expect(_should(overview: _overview(end: _now.add(const Duration(days: 20)))), isFalse);
      expect(_should(overview: _overview(end: null)), isFalse);
    });

    test('ended, held or canceled subscriptions may have been renewed or replaced in the store', () {
      for (final s in ['expired', 'past_due', 'canceled']) {
        expect(
          _should(
            overview: _overview(status: s, end: _now.add(const Duration(days: 30))),
          ),
          isTrue,
          reason: s,
        );
      }
    });

    test('plan change suspicion: an expired row restores even though no date is near', () {
      expect(
        _should(
          overview: _overview(status: 'expired', end: _now.subtract(const Duration(days: 1))),
        ),
        isTrue,
      );
    });

    test('no subscription ever: nothing to restore', () {
      expect(_should(overview: _overview(status: null)), isFalse);
      expect(_should(overview: null), isFalse);
    });

    test('only parents, never test accounts, never unsupported platforms', () {
      final due = _now.subtract(const Duration(days: 1));
      expect(
        _should(
          overview: _overview(role: 'member', end: due),
        ),
        isFalse,
      );
      expect(_should(overview: _overview(testAccess: true, end: due)), isFalse);
      expect(_should(overview: _overview(end: due), supported: false), isFalse);
    });

    test('throttled to one attempt per six hours and one at a time', () {
      final o = _overview(end: _now.subtract(const Duration(days: 1)));
      expect(_should(overview: o, lastAttempt: _now.subtract(const Duration(hours: 5))), isFalse);
      expect(_should(overview: o, lastAttempt: _now.subtract(const Duration(hours: 7))), isTrue);
      expect(_should(overview: o, inFlight: true), isFalse);
    });
  });

  group('AutoRestore', () {
    final due = _overview(end: _now.subtract(const Duration(days: 1)));

    test('restores quietly (silent) and then waits out the throttle', () async {
      final store = _Store();
      final auto = AutoRestore(store);
      expect(await auto.maybeRun(due, now: _now), isTrue);
      expect(store.silentFlags, [true]);
      expect(await auto.maybeRun(due, now: _now.add(const Duration(hours: 1))), isFalse);
      expect(await auto.maybeRun(due, now: _now.add(const Duration(hours: 7))), isTrue);
      expect(store.silentFlags, [true, true]);
    });

    test('never starts two restores at once', () async {
      final store = _Store()..hold = Completer<void>();
      final auto = AutoRestore(store);
      final first = auto.maybeRun(due, now: _now);
      await Future<void>.delayed(Duration.zero);
      expect(await auto.maybeRun(due, now: _now.add(const Duration(hours: 9))), isFalse);
      store.hold!.complete();
      expect(await first, isTrue);
      expect(store.silentFlags.length, 1);
    });

    test('an offline store never throws into the app', () async {
      final auto = AutoRestore(_Store(fail: true));
      expect(await auto.maybeRun(due, now: _now), isFalse);
    });

    test('an unsupported platform does nothing', () async {
      final store = _Store(supported: false);
      expect(await AutoRestore(store).maybeRun(due, now: _now), isFalse);
      expect(store.silentFlags, isEmpty);
    });
  });
}
