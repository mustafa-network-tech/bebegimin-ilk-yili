import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/errors/app_exception.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:bebegimin_ilk_yili/features/book/application/book_providers.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_models.dart';
import 'package:bebegimin_ilk_yili/features/book/presentation/book_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fixtures.dart';

Widget _app(Widget child, String? block, {bool renderer = true}) => ProviderScope(
  overrides: [
    babiesProvider.overrideWithValue(AsyncData([defne])),
    activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
    babyLifecycleProvider(defne.id).overrideWithValue(
      AsyncData(
        BabyLifecycle(
          babyId: defne.id,
          status: block == 'premium_requires_locked' ? BabyLifecycleStatus.active : BabyLifecycleStatus.locked,
          businessDate: d(2026, 9, 1),
          baseCloseDate: d(2026, 9, 22),
          effectiveCloseDate: d(2026, 9, 22),
          remainingDays: 0,
          extensionStatus: null,
          approvedExtensionDays: 0,
          canRequestExtension: false,
        ),
      ),
    ),
    bookAccessProvider(defne.id)
        .overrideWithValue(AsyncData(BookAccess(block: block, rendererEnabled: renderer, hasProject: true))),
  ],
  child: MaterialApp(theme: AppTheme.light(), home: child),
);

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  testWidgets('ACTIVE archive: every book route is closed', (tester) async {
    await tester.pumpWidget(_app(const BookRouteGate(child: Text('BOOK')), 'premium_requires_locked'));
    expect(find.text('BOOK'), findsNothing);
    expect(find.text('İlk yıl devam ediyor'), findsOneWidget);
    expect(find.textContaining('22 Eylül 2026'), findsOneWidget);
  });

  testWidgets('LOCKED without the purchase: offer the store, never the editor', (tester) async {
    await tester.pumpWidget(_app(const BookRouteGate(child: Text('BOOK')), 'entitlement_required'));
    expect(find.text('BOOK'), findsNothing);
    expect(find.text('Dijital ürünleri gör'), findsOneWidget);
  });

  testWidgets('inactive family subscription closes the book but keeps it', (tester) async {
    await tester.pumpWidget(_app(const BookRouteGate(child: Text('BOOK')), 'subscription_required'));
    expect(find.text('BOOK'), findsNothing);
    expect(find.text('Aile paketi gerekiyor'), findsOneWidget);
  });

  testWidgets('entitled parent opens the book and its editor', (tester) async {
    await tester.pumpWidget(_app(const BookRouteGate(requireEdit: true, child: Text('EDITOR')), null));
    expect(find.text('EDITOR'), findsOneWidget);
  });

  testWidgets('family member sees the book home but not the editor', (tester) async {
    await tester.pumpWidget(_app(const BookRouteGate(child: Text('BOOK')), 'not_parent'));
    expect(find.text('BOOK'), findsOneWidget);
    await tester.pumpWidget(_app(const BookRouteGate(requireEdit: true, child: Text('EDITOR')), 'not_parent'));
    expect(find.text('EDITOR'), findsNothing);
    expect(find.text('Yalnızca Anne ve Baba'), findsOneWidget);
  });

  test('access model and download reasons', () {
    const parent = BookAccess(block: null, rendererEnabled: true, hasProject: true);
    const member = BookAccess(block: 'not_parent', rendererEnabled: true, hasProject: false);
    const locked = BookAccess(block: 'premium_requires_locked', rendererEnabled: true, hasProject: false);
    expect([parent.canEdit, parent.canView], [true, true]);
    expect([member.canEdit, member.canView], [false, true]);
    expect([locked.canEdit, locked.canView], [false, false]);
    expect(bookDownloadBlockText('subscription_required'), contains('aile paketi'));
    final v = BookVersion.fromJson({
      'export_id': 'e1',
      'version': 3,
      'format': 'square_30',
      'page_count': 48,
      'size_bytes': 5 * 1024 * 1024,
      'created_at': '2026-10-01T10:00:00Z',
      'artifact_id': 'a1',
      'sha256': 'f' * 64,
      'download_block': null,
    });
    expect(
      [v.canDownload, v.fileName, v.sizeLabel, v.format],
      [true, 'ilk-yil-kitabi-v3.pdf', '5,0 MB', BookFormat.square30],
    );
  });

  test('book refusals map to Turkish messages', () {
    for (final hint in ['entitlement_required', 'book_render_in_progress', 'book_renderer_disabled', 'lease_lost']) {
      final e = AppException.from(PostgrestException(message: 'x', code: '55000', hint: hint));
      expect(e.message, isNot(startsWith('Sunucu hatası')), reason: hint);
    }
    final legacy = AppException.from(
      const PostgrestException(message: 'x', code: '42501', hint: 'book_export_requires_artifact'),
    );
    expect(legacy.kind, AppErrorKind.permission);
  });
}
