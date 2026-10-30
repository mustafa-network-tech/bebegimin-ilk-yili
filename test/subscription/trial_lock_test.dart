import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/subscription/application/subscription_providers.dart';
import 'package:bebegimin_ilk_yili/features/subscription/domain/subscription_models.dart';
import 'package:bebegimin_ilk_yili/features/subscription/presentation/member_locked_screen.dart';
import 'package:bebegimin_ilk_yili/features/subscription/presentation/plans_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';
import 'family_plan_test.dart' show catalog;

BabyAccessState state(Map<String, dynamic> json) => BabyAccessState.fromJson(defne.id, json);

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('access state', () {
    test('a running trial opens the app and reports its end', () {
      final s = state({
        'allowed': true,
        'reason': 'trial',
        'is_parent': true,
        'plan_required': false,
        'trial_ends_at': '2026-11-02T10:30:00+00:00',
      });
      expect(s.reason, AccessReason.trial);
      expect(s.allowed, isTrue);
      expect(s.blocksApp, isFalse);
      expect(s.lockedMember, isFalse);
      expect(s.trialEndsAt, DateTime.utc(2026, 11, 2, 10, 30));
      expect(s.title, 'Deneme erişimi');
    });

    test('without a plan the parent is sent to the plans and nothing is called read-only', () {
      final s = state({'allowed': false, 'reason': 'subscription_ended', 'is_parent': true, 'plan_required': true});
      expect(s.blocksApp, isTrue);
      expect(s.lockedMember, isFalse);
      expect(s.title, 'Planınızın süresi doldu');
      expect(s.message, contains('hiçbir şey silinmedi'));
      expect(s.message, isNot(contains('salt okunur')));
    });

    test('a family member cannot buy: locked with an explanation, never blocked as a parent', () {
      final s = state({'allowed': false, 'reason': 'no_subscription', 'is_parent': false, 'plan_required': true});
      expect(s.blocksApp, isFalse);
      expect(s.lockedMember, isTrue);
      expect(s.message, contains('Anne veya Baba planı yenilediğinde'));
    });

    test('an old server reply without the new fields keeps the previous behaviour', () {
      final s = state({'allowed': true, 'reason': 'ok', 'is_parent': true});
      expect(s.planRequired, isFalse);
      expect(s.trialEndsAt, isNull);
      expect(s.lockedMember, isFalse);
    });

    test('the enforcement-off state never locks anyone', () {
      final s = state({'allowed': true, 'reason': 'enforcement_off', 'is_parent': false, 'plan_required': false});
      expect(s.lockedMember, isFalse);
      expect(s.blocksApp, isFalse);
    });
  });

  testWidgets('plans can be viewed before a baby exists, without a purchase button', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeBabyProvider.overrideWithValue(null),
          planCatalogProvider.overrideWith((ref) async => catalog()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const PlansOverviewScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Planlar'), findsOneWidget);
    expect(find.text('Small Family'), findsOneWidget);
    expect(find.textContaining('Bebek profilinizi oluşturduktan sonra'), findsOneWidget);
    expect(find.text('Planımı yönet'), findsNothing);
    expect(find.text('Seç'), findsNothing);
  });

  testWidgets('a locked family member only reads why and can re-check', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeAccessGateProvider.overrideWithValue(
            state({'allowed': false, 'reason': 'no_subscription', 'is_parent': false, 'plan_required': true}),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const MemberLockedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Anne veya Baba planı yenilediğinde'), findsOneWidget);
    expect(find.text('Tekrar kontrol et'), findsOneWidget);
    expect(find.text('Plan seç'), findsNothing);
  });
}
