import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses server-authoritative active lifecycle summary', () {
    final lifecycle = BabyLifecycle.fromJson({
      'baby_id': 'baby-1',
      'status': 'ACTIVE',
      'business_date': '2026-09-27',
      'base_close_date': '2026-09-30',
      'effective_close_date': '2026-10-30',
      'remaining_days': 33,
      'extension_status': 'approved',
      'approved_extension_days': 30,
      'can_request_extension': false,
    });

    expect(lifecycle.isActive, isTrue);
    expect(lifecycle.isLocked, isFalse);
    expect(lifecycle.remainingDays, 33);
    expect(lifecycle.extensionStatus, BabyExtensionStatus.approved);
    expect(lifecycle.approvedExtensionDays, 30);
    expect(lifecycle.canRequestExtension, isFalse);
  });

  test('parses locked and expired lifecycle summary', () {
    final lifecycle = BabyLifecycle.fromJson({
      'baby_id': 'baby-2',
      'status': 'LOCKED',
      'business_date': '2026-09-27',
      'base_close_date': '2026-09-27',
      'effective_close_date': '2026-09-27',
      'remaining_days': 0,
      'extension_status': 'expired',
      'approved_extension_days': 0,
      'can_request_extension': false,
    });

    expect(lifecycle.isLocked, isTrue);
    expect(lifecycle.remainingDays, 0);
    expect(lifecycle.extensionStatus, BabyExtensionStatus.expired);
  });

  test('rejects unknown server status instead of guessing', () {
    expect(
      () => BabyLifecycle.fromJson({
        'baby_id': 'baby-3',
        'status': 'PAUSED',
        'business_date': '2026-09-27',
        'base_close_date': '2026-09-27',
        'effective_close_date': '2026-09-27',
        'remaining_days': 0,
        'extension_status': null,
        'approved_extension_days': 0,
        'can_request_extension': false,
      }),
      throwsFormatException,
    );
  });
}
