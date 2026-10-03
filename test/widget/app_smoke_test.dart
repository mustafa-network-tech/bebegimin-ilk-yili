import 'package:bebegimin_ilk_yili/app/app.dart';
import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/cache/local_cache.dart';
import 'package:bebegimin_ilk_yili/core/widgets/states.dart';
import 'package:bebegimin_ilk_yili/features/auth/presentation/auth_screens.dart';
import 'package:bebegimin_ilk_yili/features/family/application/family_providers.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/family_member.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/permission.dart';
import 'package:bebegimin_ilk_yili/features/family/presentation/permission_editor.dart';
import 'package:bebegimin_ilk_yili/features/memories/domain/timeline_entry.dart';
import 'package:bebegimin_ilk_yili/features/memories/presentation/timeline_entry_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';

Widget _wrap(Widget child, {List<dynamic> overrides = const []}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  testWidgets('without Supabase configuration the app shows setup instructions', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)], child: const BebegiminApp()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Yapılandırma eksik'), findsOneWidget);
    expect(find.textContaining('--dart-define-from-file'), findsOneWidget);
  });

  testWidgets('timeline card shows age, first-year badge and author relation', (tester) async {
    final entry = TimelineEntry(
      type: EntryType.memory,
      id: 'm1',
      babyId: defne.id,
      date: d(2025, 12, 24),
      time: '09:15:00',
      title: 'İlk kar',
      body: 'Pencereden karı izledin.',
      authorId: 'user-teyze',
      category: 'first',
      milestoneId: null,
      milestoneTypeId: null,
      includeInBook: true,
      createdAt: DateTime.utc(2026, 9, 1),
    );
    final teyze = FamilyMember.fromJson({
      'id': 'fm',
      'baby_id': defne.id,
      'user_id': 'user-teyze',
      'relation': 'teyze',
      'relation_label': null,
      'is_admin': false,
      'permissions': ['view_memories'],
      'joined_at': '2025-09-20T10:00:00Z',
      'profiles': {'display_name': 'Zeynep', 'avatar_path': null},
    });
    await tester.pumpWidget(
      _wrap(
        TimelineEntryCard(entry: entry, baby: defne),
        overrides: [
          membersProvider(defne.id).overrideWithValue(AsyncData([teyze])),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('İlk kar'), findsOneWidget);
    expect(find.text('3 aylık 12 günlük'), findsOneWidget);
    expect(find.text('İlk Yılım'), findsOneWidget);
    expect(find.textContaining('Teyzesi Zeynep'), findsOneWidget);
    expect(find.textContaining('09:15'), findsOneWidget);
  });

  testWidgets('non-admins cannot toggle management permissions', (tester) async {
    var value = <AppPermission>{AppPermission.viewMemories};
    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) =>
              PermissionEditor(value: value, canGrantManagement: false, onChanged: (v) => setState(() => value = v)),
        ),
      ),
    );
    final manage = find.widgetWithText(SwitchListTile, AppPermission.manageMembers.label);
    expect(tester.widget<SwitchListTile>(manage).onChanged, isNull);
    await tester.tap(find.widgetWithText(SwitchListTile, AppPermission.addMemory.label));
    await tester.pump();
    expect(value, containsAll([AppPermission.addMemory, AppPermission.viewMemories]));
  });

  testWidgets('empty & error states render with retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            const EmptyState(icon: Icons.photo, title: 'Henüz fotoğraf yok'),
            ErrorView(error: Exception('x'), onRetry: () => retried = true),
          ],
        ),
      ),
    );
    expect(find.text('Henüz fotoğraf yok'), findsOneWidget);
    await tester.tap(find.text('Tekrar dene'));
    expect(retried, isTrue);
  });

  testWidgets('logo renders in dark mode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: AppLogo()),
      ),
    );
    expect(find.textContaining('İlk Yılı'), findsOneWidget);
  });
}
