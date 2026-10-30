import 'dart:async';

import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/features/admin/application/admin_providers.dart';
import 'package:bebegimin_ilk_yili/features/admin/data/admin_repository.dart';
import 'package:bebegimin_ilk_yili/features/admin/domain/admin_models.dart';
import 'package:bebegimin_ilk_yili/features/admin/presentation/admin_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

class _FakeAdminRepository implements AdminRepository {
  final decisions = <(String, bool, String?)>[];
  Completer<String>? pending;

  @override
  Future<String> decide({required String requestId, required bool approve, String? note}) {
    decisions.add((requestId, approve, note));
    pending = Completer<String>();
    return pending!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdminExtensionRequest request({String status = 'pending', String? decidedBy, String? note}) =>
    AdminExtensionRequest.fromJson({
      'request_id': 'req-1',
      'baby_id': 'baby-1',
      'baby_first_name': 'Ece',
      'requested_days': 12,
      'status': status,
      'requested_by_name': 'Elif',
      'requested_at': '2026-09-20T09:00:00Z',
      'base_close_date': '2026-10-01',
      'days_until_base_close': 2,
      'sla': status == 'pending' ? 'urgent' : null,
      'decided_by_name': decidedBy,
      'decided_at': decidedBy == null ? null : '2026-09-21T10:00:00Z',
      'decision_note': note,
      'total_count': 1,
    });

Widget _app(Widget child, {List<dynamic> overrides = const []}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  ),
);

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('gate', () {
    testWidgets('family admins and other users never see the console', (tester) async {
      await tester.pumpWidget(
        _app(
          const AdminGate(child: Text('CONSOLE')),
          overrides: [adminSessionProvider.overrideWithValue(const AsyncData(AdminSession.none))],
        ),
      );
      expect(find.text('CONSOLE'), findsNothing);
      expect(find.text('Erişim yok'), findsOneWidget);
    });

    testWidgets('a disabled console stays closed for Super Admins', (tester) async {
      await tester.pumpWidget(
        _app(
          const AdminGate(child: Text('CONSOLE')),
          overrides: [
            adminSessionProvider.overrideWithValue(
              const AsyncData(AdminSession(isSuperAdmin: true, consoleEnabled: false)),
            ),
          ],
        ),
      );
      expect(find.text('CONSOLE'), findsNothing);
      expect(find.text('Yönetim paneli kapalı'), findsOneWidget);
    });

    testWidgets('Super Admin with an enabled console gets in', (tester) async {
      await tester.pumpWidget(
        _app(
          const AdminGate(child: Text('CONSOLE')),
          overrides: [
            adminSessionProvider.overrideWithValue(
              const AsyncData(AdminSession(isSuperAdmin: true, consoleEnabled: true)),
            ),
          ],
        ),
      );
      expect(find.text('CONSOLE'), findsOneWidget);
    });
  });

  group('models', () {
    test('queue row parses SLA and status', () {
      final r = request();
      expect(r.isPending, isTrue);
      expect(r.sla, ExtensionSla.urgent);
      expect(r.requestedDays, 12);
      expect(request(status: 'expired').statusLabel, 'Süresi doldu');
    });

    test('audit summary shows only allow-listed facts', () {
      final e = AdminAuditEntry.fromJson({
        'id': 7,
        'created_at': '2026-09-21T10:00:00Z',
        'action': 'birth_date_corrected',
        'baby_id': 'baby-1',
        'baby_first_name': 'Ece',
        'actor_name': 'Operasyon',
        'details': {'birth_date_before': '2025-09-01', 'birth_date_after': '2025-09-03', 'reason': 'Nüfus kaydı'},
        'total_count': 1,
      });
      expect(e.label, 'Doğum tarihi düzeltmesi');
      expect(e.summary, contains('Gerekçe: Nüfus kaydı'));
      expect(e.summary, contains('→'));
    });

    test('birth date preview flags a reopen', () {
      final p = BirthDatePreview.fromJson({
        'birth_date_before': '2025-08-01',
        'birth_date_after': '2025-11-01',
        'status_before': 'LOCKED',
        'status_after': 'ACTIVE',
        'base_close_before': '2026-08-11',
        'base_close_after': '2026-11-11',
        'effective_close_before': '2026-08-11',
        'effective_close_after': '2026-11-11',
        'approved_extension_days': 0,
        'would_reopen': true,
        'would_lock': false,
      });
      expect(p.wouldReopen, isTrue);
      expect(p.lockedAfter, isFalse);
    });
  });

  group('decision sheet', () {
    testWidgets('expired requests are read-only', (tester) async {
      await tester.pumpWidget(_app(ExtensionDecisionSheet(request: request(status: 'expired'))));
      expect(find.text('Onayla'), findsNothing);
      expect(find.text('Süresi dolan talep onaylanamaz; profil yeniden açılmaz.'), findsOneWidget);
    });

    testWidgets('decided requests show the immutable result', (tester) async {
      await tester.pumpWidget(
        _app(
          ExtensionDecisionSheet(
            request: request(status: 'approved', decidedBy: 'Operasyon', note: 'Tamam'),
          ),
        ),
      );
      expect(find.text('Onayla'), findsNothing);
      expect(find.text('Bu talep karara bağlandı; karar değiştirilemez.'), findsOneWidget);
      expect(find.text('Operasyon'), findsOneWidget);
    });

    testWidgets('rejecting requires a note', (tester) async {
      final repo = _FakeAdminRepository();
      await tester.pumpWidget(
        _app(ExtensionDecisionSheet(request: request()), overrides: [adminRepositoryProvider.overrideWithValue(repo)]),
      );
      await tester.tap(find.text('Reddet'));
      await tester.pump();
      expect(repo.decisions, isEmpty);
      expect(find.text('Reddetmek için karar notu yazın.'), findsOneWidget);
    });

    testWidgets('double submit is blocked while the decision is in flight', (tester) async {
      final repo = _FakeAdminRepository();
      await tester.pumpWidget(
        _app(ExtensionDecisionSheet(request: request()), overrides: [adminRepositoryProvider.overrideWithValue(repo)]),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Onayla'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Onayla').last); // confirm dialog
      await tester.pump();
      expect(repo.decisions, hasLength(1));
      final buttons = tester.widgetList<ButtonStyleButton>(find.byType(ButtonStyleButton));
      expect(buttons.every((b) => b.onPressed == null), isTrue);
      repo.pending!.complete('approved');
      await tester.pumpAndSettle();
      expect(find.text('Onaylandı. Karar kesindir.'), findsOneWidget);
      expect(repo.decisions, hasLength(1));
    });

    testWidgets('SLA badge announces the time left', (tester) async {
      await tester.pumpWidget(_app(const SlaBadge(sla: ExtensionSla.urgent, days: 2)));
      expect(find.bySemanticsLabel('Kapanışa 2 gün kaldı, Acil'), findsOneWidget);
    });
  });
}
