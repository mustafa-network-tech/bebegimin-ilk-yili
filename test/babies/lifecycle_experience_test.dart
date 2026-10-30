import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/content/lifecycle_revision.dart';
import 'package:bebegimin_ilk_yili/core/supabase_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/data/baby_lifecycle_repository.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:bebegimin_ilk_yili/features/babies/presentation/lifecycle_screen.dart';
import 'package:bebegimin_ilk_yili/features/babies/presentation/lifecycle_widgets.dart';
import 'package:bebegimin_ilk_yili/features/family/application/family_providers.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/family_member.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/permission.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';

final ege = Baby(id: 'baby-ege', firstName: 'Ege', birthDate: d(2026, 6, 1));

BabyLifecycle lifecycle(
  String babyId, {
  required bool active,
  required DateTime close,
  int remaining = 0,
  int approved = 0,
  BabyExtensionStatus? extension,
  bool canRequest = false,
}) => BabyLifecycle(
  babyId: babyId,
  status: active ? BabyLifecycleStatus.active : BabyLifecycleStatus.locked,
  businessDate: close.subtract(Duration(days: remaining)),
  baseCloseDate: close.subtract(Duration(days: approved)),
  effectiveCloseDate: close,
  remainingDays: remaining,
  extensionStatus: extension,
  approvedExtensionDays: approved,
  canRequestExtension: canRequest,
);

FamilyMember member(String babyId, {String relation = 'anne', bool admin = true, List<String> perms = const []}) =>
    FamilyMember.fromJson({
      'id': 'fm-$babyId-$relation',
      'baby_id': babyId,
      'user_id': 'user-anne',
      'relation': relation,
      'relation_label': null,
      'is_admin': admin,
      'permissions': perms,
      'joined_at': '2025-09-20T10:00:00Z',
      'profiles': {'display_name': 'Elif', 'avatar_path': null},
    });

class _FakeLifecycleRepository implements BabyLifecycleRepository {
  _FakeLifecycleRepository(this.value);

  BabyLifecycle value;
  int fetches = 0;

  @override
  Future<BabyLifecycle> summary(String babyId) async {
    fetches++;
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child, List<dynamic> overrides) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(theme: AppTheme.light(), home: child),
);

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('BabyLifecycle client rules', () {
    test('Istanbul business date and midnight boundary', () {
      expect(BabyLifecycle.istanbulDate(DateTime.utc(2026, 1, 1, 20, 59, 59)), d(2026, 1, 1));
      expect(BabyLifecycle.istanbulDate(DateTime.utc(2026, 1, 1, 21)), d(2026, 1, 2));
      expect(BabyLifecycle.untilNextBusinessDay(DateTime.utc(2026, 1, 1, 20, 59, 59)), const Duration(seconds: 1));
    });

    test('a stale ACTIVE summary locks once the device passes the close date', () {
      final l = lifecycle('b', active: true, close: d(2026, 1, 2), remaining: 1, canRequest: true);
      expect(l.tightenedFor(DateTime.utc(2026, 1, 1, 20, 59)).isActive, isTrue);
      final after = l.tightenedFor(DateTime.utc(2026, 1, 1, 21, 0, 1));
      expect(after.isLocked, isTrue);
      expect(after.remainingDays, 0);
      expect(after.canRequestExtension, isFalse);
    });

    test('the device clock can never unlock a LOCKED profile', () {
      final l = lifecycle('b', active: false, close: d(2026, 1, 2));
      expect(l.tightenedFor(DateTime.utc(2025, 6, 1)).isLocked, isTrue);
    });

    test('a device clock set back never adds days', () {
      final l = lifecycle('b', active: true, close: d(2026, 1, 11), remaining: 5);
      expect(l.tightenedFor(DateTime.utc(2025, 12, 1)).remainingDays, 5);
    });

    test('summary survives the offline cache round trip', () {
      final l = lifecycle(
        'b',
        active: true,
        close: d(2026, 2, 10),
        remaining: 33,
        approved: 30,
        extension: BabyExtensionStatus.approved,
      );
      final copy = BabyLifecycle.fromJson(l.toJson());
      expect(copy.effectiveCloseDate, l.effectiveCloseDate);
      expect(copy.remainingDays, 33);
      expect(copy.extensionStatus, BabyExtensionStatus.approved);
      expect(copy.isActive, isTrue);
    });
  });

  group('MemberAccess with a locked archive', () {
    final admin = member('b', perms: const []).access;

    test('ACTIVE admin can create and edit', () {
      expect(admin.canCreateAnything, isTrue);
      expect(admin.canEditLetter('user-anne'), isTrue);
    });

    test('LOCKED switches off every archive write but keeps family management', () {
      final locked = admin.withArchiveLocked(true);
      expect(locked.canCreateAnything, isFalse);
      for (final p in AppPermission.values.where((p) => p.writesArchive)) {
        expect(locked.can(p), isFalse, reason: p.key);
      }
      expect(locked.can(AppPermission.viewMemories), isTrue);
      expect(locked.can(AppPermission.inviteMembers), isTrue);
      expect(locked.can(AppPermission.manageMembers), isTrue);
      expect(locked.canEditContent('user-anne'), isFalse);
      expect(locked.canEditMedia('user-anne'), isFalse);
      expect(locked.canEditLetter('user-anne'), isFalse);
      expect(locked.canDeleteComment('user-anne'), isFalse);
      expect(locked.canDeleteCapsule('user-anne'), isFalse);
      expect(locked.isAdmin, isTrue);
    });
  });

  group('providers', () {
    test('two babies keep independent lifecycle and access', () {
      final container = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue('user-anne'),
          membersProvider(defne.id).overrideWithValue(AsyncData([member(defne.id)])),
          membersProvider(ege.id).overrideWithValue(AsyncData([member(ege.id)])),
          babyLifecycleProvider(defne.id)
              .overrideWithValue(AsyncData(lifecycle(defne.id, active: false, close: d(2026, 9, 22)))),
          babyLifecycleProvider(ege.id)
              .overrideWithValue(AsyncData(lifecycle(ege.id, active: true, close: d(2027, 6, 11), remaining: 255))),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(accessProvider(defne.id)).can(AppPermission.addMemory), isFalse);
      expect(container.read(accessProvider(ege.id)).can(AppPermission.addMemory), isTrue);
      expect(container.read(accessProvider(defne.id)).can(AppPermission.inviteMembers), isTrue);
    });

    test('an unknown lifecycle is treated as locked', () {
      final container = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue('user-anne'),
          membersProvider(ege.id).overrideWithValue(AsyncData([member(ege.id)])),
          babyLifecycleProvider(ege.id).overrideWithValue(const AsyncLoading()),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(accessProvider(ege.id)).canCreateAnything, isFalse);
    });

    test('crossing Istanbul midnight locks after refresh even with a stale ACTIVE answer', () async {
      var now = DateTime.utc(2026, 1, 1, 20, 59);
      final repo = _FakeLifecycleRepository(lifecycle(ege.id, active: true, close: d(2026, 1, 2), remaining: 1));
      final container = ProviderContainer(
        overrides: [
          babyLifecycleRepositoryProvider.overrideWithValue(repo),
          lifecycleClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(container.dispose);
      expect((await container.read(babyLifecycleProvider(ege.id).future)).isActive, isTrue);
      now = DateTime.utc(2026, 1, 1, 21, 0, 1);
      container.read(lifecycleRevisionProvider.notifier).bump();
      expect((await container.read(babyLifecycleProvider(ege.id).future)).isLocked, isTrue);
      expect(repo.fetches, 2);
    });
  });

  group('widgets', () {
    testWidgets('ACTIVE home card shows the server countdown incl. approved extension', (tester) async {
      await tester.pumpWidget(
        _app(Scaffold(body: LifecycleCard(baby: ege)), [
          babyLifecycleProvider(ege.id).overrideWithValue(
            AsyncData(
              lifecycle(
                ege.id,
                active: true,
                close: d(2026, 7, 14),
                remaining: 33,
                approved: 30,
                extension: BabyExtensionStatus.approved,
              ),
            ),
          ),
        ]),
      );
      expect(find.bySemanticsLabel(RegExp('33 gün kaldı')), findsOneWidget);
      expect(find.textContaining('onaylı uzatma dahil'), findsOneWidget);
    });

    testWidgets('LOCKED home card says the first year is complete', (tester) async {
      await tester.pumpWidget(
        _app(Scaffold(body: LifecycleCard(baby: defne)), [
          babyLifecycleProvider(defne.id)
              .overrideWithValue(AsyncData(lifecycle(defne.id, active: false, close: d(2026, 9, 22)))),
        ]),
      );
      expect(find.text('İlk Yılı tamamlandı'), findsOneWidget);
    });

    testWidgets('form deep links cannot bypass a LOCKED archive', (tester) async {
      await tester.pumpWidget(
        _app(const LifecycleWriteGuard(babyId: 'baby-defne', child: Text('FORM')), [
          babyLifecycleProvider(defne.id)
              .overrideWithValue(AsyncData(lifecycle(defne.id, active: false, close: d(2026, 9, 22)))),
        ]),
      );
      expect(find.text('FORM'), findsNothing);
      expect(find.text('Arşiv kilitli'), findsOneWidget);
    });

    testWidgets('ACTIVE archive opens the form', (tester) async {
      await tester.pumpWidget(
        _app(const LifecycleWriteGuard(babyId: 'baby-ege', child: Text('FORM')), [
          babyLifecycleProvider(ege.id)
              .overrideWithValue(AsyncData(lifecycle(ege.id, active: true, close: d(2027, 6, 11), remaining: 200))),
        ]),
      );
      expect(find.text('FORM'), findsOneWidget);
    });

    List<dynamic> gateOverrides(Baby baby, BabyLifecycle l) => [
      babiesProvider.overrideWithValue(AsyncData([baby])),
      activeBabyIdProvider.overrideWithBuild((ref, _) => baby.id),
      babyLifecycleProvider(baby.id).overrideWithValue(AsyncData(l)),
    ];

    testWidgets('premium routes are closed for ACTIVE profiles', (tester) async {
      await tester.pumpWidget(
        _app(
          const PremiumRouteGate(child: Text('BOOK')),
          gateOverrides(ege, lifecycle(ege.id, active: true, close: d(2027, 6, 11), remaining: 200)),
        ),
      );
      expect(find.text('BOOK'), findsNothing);
      expect(find.text('İlk yıl devam ediyor'), findsOneWidget);
    });

    testWidgets('LOCKED profiles see a premium placeholder until entitlements exist', (tester) async {
      await tester.pumpWidget(
        _app(
          const PremiumRouteGate(child: Text('BOOK')),
          gateOverrides(defne, lifecycle(defne.id, active: false, close: d(2026, 9, 22))),
        ),
      );
      expect(find.text('BOOK'), findsNothing);
      expect(find.text('Yakında'), findsOneWidget);
    });

    List<dynamic> screenOverrides(BabyLifecycle l, FamilyMember m) => [
      currentUserIdProvider.overrideWithValue('user-anne'),
      babiesProvider.overrideWithValue(AsyncData([ege])),
      membersProvider(ege.id).overrideWithValue(AsyncData([m])),
      babyLifecycleProvider(ege.id).overrideWithValue(AsyncData(l)),
    ];

    testWidgets('parent can request an extension once, with 1-30 day slider', (tester) async {
      await tester.pumpWidget(
        _app(
          const BabyLifecycleScreen(babyId: 'baby-ege'),
          screenOverrides(
            lifecycle(ege.id, active: true, close: d(2027, 6, 11), remaining: 20, canRequest: true),
            member(ege.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Uzatma talep et'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 1);
      expect(slider.max, 30);
      expect(find.text('Bu hak yalnızca bir kez kullanılabilir.'), findsOneWidget);
    });

    testWidgets('an existing request never opens a second form', (tester) async {
      await tester.pumpWidget(
        _app(
          const BabyLifecycleScreen(babyId: 'baby-ege'),
          screenOverrides(
            lifecycle(
              ege.id,
              active: true,
              close: d(2027, 6, 11),
              remaining: 20,
              extension: BabyExtensionStatus.pending,
            ),
            member(ege.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Uzatma talep et'), findsNothing);
      expect(find.text('Uzatma talebi değerlendiriliyor.'), findsOneWidget);
    });

    testWidgets('non-parents cannot request an extension', (tester) async {
      await tester.pumpWidget(
        _app(
          const BabyLifecycleScreen(babyId: 'baby-ege'),
          screenOverrides(
            lifecycle(ege.id, active: true, close: d(2027, 6, 11), remaining: 20, canRequest: true),
            member(ege.id, relation: 'teyze', admin: false, perms: const ['view_memories']),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Uzatma talep et'), findsNothing);
      expect(find.text('Uzatma talebini Anne veya Baba oluşturabilir.'), findsOneWidget);
    });

    // The server reports can_request_extension = false for non-parents
    // (decision P-6); the screen must not blame the closing date.
    Future<void> expectParentsOnlyMessage(WidgetTester tester, FamilyMember m) async {
      await tester.pumpWidget(
        _app(
          const BabyLifecycleScreen(babyId: 'baby-ege'),
          screenOverrides(lifecycle(ege.id, active: true, close: d(2027, 6, 11), remaining: 20), m),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Uzatma talep et'), findsNothing);
      expect(find.text('Uzatma talebini Anne veya Baba oluşturabilir.'), findsOneWidget);
      expect(find.text('Uzatma talebi yalnızca standart kapanış tarihinden önce oluşturulabilir.'), findsNothing);
    }

    testWidgets('a refused non-parent member is told who can request', (tester) async {
      await expectParentsOnlyMessage(
        tester,
        member(ege.id, relation: 'teyze', admin: false, perms: const ['view_memories']),
      );
    });

    testWidgets('a refused legacy non-parent admin is told who can request', (tester) async {
      await expectParentsOnlyMessage(tester, member(ege.id, relation: 'teyze'));
    });
  });
}
