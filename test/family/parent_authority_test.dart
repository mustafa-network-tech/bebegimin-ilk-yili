import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/supabase_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:bebegimin_ilk_yili/features/family/application/family_providers.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/family_member.dart';
import 'package:bebegimin_ilk_yili/features/family/presentation/member_screens.dart';
import 'package:bebegimin_ilk_yili/features/settings/presentation/settings_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

// Decisions P-3 / P-5 / P-9 / P-10 (2026-10-02): only Anne / Baba are admins,
// nobody removes or demotes the other parent, a sole parent deletes the
// babies before the account.

final ege = Baby(id: 'baby-ege', firstName: 'Ege', birthDate: DateTime(2026, 6, 1));

FamilyMember member(String userId, String relation, {bool admin = false, List<String> perms = const []}) =>
    FamilyMember.fromJson({
      'id': 'fm-$userId',
      'baby_id': ege.id,
      'user_id': userId,
      'relation': relation,
      'relation_label': null,
      'is_admin': admin,
      'permissions': perms,
      'joined_at': '2025-09-20T10:00:00Z',
      'profiles': {'display_name': userId, 'avatar_path': null},
    });

final anne = member('user-anne', 'anne', admin: true);
final baba = member('user-baba', 'baba', admin: true);
final teyze = member('user-teyze', 'teyze', perms: const ['view_memories']);

final active = BabyLifecycle(
  babyId: ege.id,
  status: BabyLifecycleStatus.active,
  businessDate: DateTime(2026, 9, 1),
  baseCloseDate: DateTime(2027, 6, 11),
  effectiveCloseDate: DateTime(2027, 6, 11),
  remainingDays: 283,
  extensionStatus: null,
  approvedExtensionDays: 0,
  canRequestExtension: false,
);

Widget _app(Widget child, List<dynamic> overrides) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(theme: AppTheme.light(), home: child),
);

List<dynamic> memberOverrides() => [
  currentUserIdProvider.overrideWithValue('user-anne'),
  activeBabyProvider.overrideWithValue(ege),
  babiesProvider.overrideWithValue(AsyncData([ege])),
  membersProvider(ege.id).overrideWithValue(AsyncData([anne, baba, teyze])),
  babyLifecycleProvider(ege.id).overrideWithValue(AsyncData(active)),
];

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('domain', () {
    test('only an Anne / Baba admin is a parent admin', () {
      expect(anne.isParentAdmin, isTrue);
      expect(member('u', 'baba').isParentAdmin, isFalse, reason: 'Baba without admin rights');
      expect(member('u', 'dede', admin: true).isParentAdmin, isFalse, reason: 'legacy non-parent admin');
    });

    test('a parent is protected from everybody but themselves', () {
      expect(baba.protectedFrom('user-anne'), isTrue);
      expect(baba.protectedFrom('user-baba'), isFalse);
      expect(teyze.protectedFrom('user-anne'), isFalse);
    });
  });

  group('member screen', () {
    testWidgets('the other parent cannot be removed or edited', (tester) async {
      await tester.pumpWidget(_app(MemberEditScreen(babyId: ege.id, memberId: 'fm-user-baba'), memberOverrides()));
      await tester.pumpAndSettle();
      expect(find.text('Aileden çıkar'), findsNothing);
      expect(find.text('Kaydet'), findsNothing);
      expect(
        find.text('Anne veya Babanın aile üyeliği ve yetkileri yalnızca kendisi tarafından değiştirilebilir.'),
        findsOneWidget,
      );
    });

    testWidgets('a parent still manages relatives, without making them admin', (tester) async {
      await tester.pumpWidget(_app(MemberEditScreen(babyId: ege.id, memberId: 'fm-user-teyze'), memberOverrides()));
      await tester.pumpAndSettle();
      expect(find.text('Yönetici'), findsNothing, reason: 'a teyze can never be an admin');
      await tester.scrollUntilVisible(find.text('Aileden çıkar'), 300);
      expect(find.text('Aileden çıkar'), findsOneWidget);
      expect(find.text('Kaydet'), findsOneWidget);
    });
  });

  group('account deletion', () {
    testWidgets('a sole parent is told which babies to delete first', (tester) async {
      await tester.pumpWidget(
        _app(const DeleteAccountScreen(), [
          accountDeletionBlockersProvider.overrideWith((ref) async => ['Defne', 'Ege']),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Önce şu bebek profillerini silin: Defne, Ege'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Hesabımı kalıcı olarak sil'));
      expect(button.onPressed, isNull);
    });

    testWidgets('without blocking babies the account can be deleted', (tester) async {
      await tester.pumpWidget(
        _app(const DeleteAccountScreen(), [accountDeletionBlockersProvider.overrideWith((ref) async => <String>[])]),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Önce şu bebek profillerini silin'), findsNothing);
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Hesabımı kalıcı olarak sil'));
      expect(button.onPressed, isNotNull);
    });
  });
}
