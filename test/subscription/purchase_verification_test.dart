import 'package:bebegimin_ilk_yili/core/errors/app_exception.dart';
import 'package:bebegimin_ilk_yili/features/subscription/data/store_billing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

void main() {
  group('decideVerification: only an explicit server grant activates a plan', () {
    test('granted: true opens the plan, whatever the raw result says', () {
      for (final r in ['applied', 'duplicate', 'stale', 'duplicate_payment']) {
        expect(decideVerification(granted: true, result: r), VerifyDecision.granted, reason: r);
      }
    });

    test('rejected is never a success (the original HTTP 200 bug)', () {
      expect(decideVerification(granted: false, result: 'rejected'), VerifyDecision.notActivated);
    });

    test('duplicate / stale alone do not activate; the server must confirm the real state', () {
      expect(decideVerification(granted: false, result: 'duplicate'), VerifyDecision.notActivated);
      expect(decideVerification(granted: false, result: 'stale'), VerifyDecision.notActivated);
      expect(decideVerification(granted: false, result: 'applied'), VerifyDecision.notActivated);
    });

    test('a reply from an older server (no granted flag, unknown result) never activates', () {
      expect(decideVerification(granted: false, result: 'unknown'), VerifyDecision.notActivated);
    });

    test('pending payments stay unfinished; expired ones are closed without access', () {
      expect(decideVerification(granted: false, result: 'pending'), VerifyDecision.pending);
      expect(decideVerification(granted: false, result: 'inactive'), VerifyDecision.inactive);
    });
  });

  group('plan change only replaces the family\'s own acknowledged subscription', () {
    bool replaceable({
      String product = 'small_family',
      bool purchased = true,
      bool acknowledged = true,
      String current = 'small_family',
    }) => InAppStoreBilling.isReplaceableSubscription(
      productId: product,
      purchased: purchased,
      acknowledged: acknowledged,
      currentPlanCode: current,
    );

    test('the current live plan is replaceable', () => expect(replaceable(), isTrue));

    test('a one-time product is never used as the old purchase', () {
      expect(replaceable(product: 'first_year_book'), isFalse);
      expect(replaceable(product: 'first_year_film'), isFalse);
    });

    test('another subscription on the Google account is left alone', () {
      expect(replaceable(product: 'large_family'), isFalse);
    });

    test('unverified (unacknowledged) or pending purchases are not replaced', () {
      expect(replaceable(acknowledged: false), isFalse);
      expect(replaceable(purchased: false), isFalse);
    });
  });

  group('verification failures show a Turkish message that says the plan is NOT active', () {
    String message(String code, int status) =>
        AppException.from(FunctionException(status: status, details: {'error': code})).message;

    test('every safe code has a Turkish message, none leaks the raw code', () {
      const codes = {
        'not_configured': 503,
        'google_401': 502,
        'google_403': 502,
        'google_404': 422,
        'product_not_found': 400,
        'base_plan_unavailable': 422,
        'verification_failed': 422,
        'purchase_rejected': 409,
        'temporary_error': 503,
        'purchase_not_yours': 403,
      };
      codes.forEach((code, status) {
        final m = message(code, status);
        expect(m, isNot(contains(code)), reason: code);
        expect(m, isNot(startsWith('Sunucu işlemi')), reason: code);
      });
      for (final code in codes.keys.where((c) => c != 'purchase_not_yours')) {
        expect(message(code, 422), contains('etkinleş'), reason: code);
      }
    });

    test('the error code is read from the response body only', () {
      expect(
        AppException.functionErrorCode(const FunctionException(status: 409, details: {'error': 'purchase_rejected'})),
        'purchase_rejected',
      );
      expect(AppException.functionErrorCode(const FunctionException(status: 500)), isNull);
    });

    test('an unknown code falls back to a generic message with the status', () {
      expect(message('something_new', 500), 'Sunucu işlemi tamamlanamadı (500).');
    });
  });
}
