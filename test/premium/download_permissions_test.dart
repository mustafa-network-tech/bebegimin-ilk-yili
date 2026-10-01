import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/errors/app_exception.dart';
import 'package:bebegimin_ilk_yili/features/premium/data/premium_repository.dart';
import 'package:bebegimin_ilk_yili/features/premium/domain/premium_models.dart';
import 'package:bebegimin_ilk_yili/features/premium/presentation/download_permissions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRepo implements PremiumRepository {
  _FakeRepo(this.rows);

  List<DownloadPermission> rows;
  final calls = <(String, PremiumProduct, bool)>[];

  @override
  Future<List<DownloadPermission>> downloadPermissions(String babyId) async => rows;

  @override
  Future<void> setDownloadPermission({
    required String babyId,
    required String memberUserId,
    required PremiumProduct product,
    required bool allowed,
  }) async {
    calls.add((memberUserId, product, allowed));
    rows = [
      for (final r in rows)
        r.memberUserId == memberUserId && r.product == product
            ? DownloadPermission(
                memberUserId: r.memberUserId,
                displayName: r.displayName,
                relation: r.relation,
                relationLabel: r.relationLabel,
                product: r.product,
                granted: allowed,
                productOwned: r.productOwned,
              )
            : r,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadPermission row(
  String member,
  String name,
  String relation,
  PremiumProduct p, {
  bool granted = false,
  bool owned = true,
}) => DownloadPermission(
  memberUserId: member,
  displayName: name,
  relation: relation,
  relationLabel: null,
  product: p,
  granted: granted,
  productOwned: owned,
);

Future<_FakeRepo> _pump(WidgetTester tester, List<DownloadPermission> rows) async {
  final repo = _FakeRepo(rows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [premiumRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const DownloadPermissionsScreen(babyId: 'baby-defne'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('one card per Family Member with a switch per product', (tester) async {
    await _pump(tester, [
      for (final p in PremiumProduct.values) row('u-teyze', 'Zeynep', 'teyze', p, granted: p == PremiumProduct.book),
      for (final p in PremiumProduct.values) row('u-dede', '', 'dede', p, owned: p != PremiumProduct.html),
    ]);
    expect(find.text('Zeynep · Teyze'), findsOneWidget);
    expect(find.text('Dede'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(6));
    expect(find.textContaining('Anne ve Baba satın alınan dosyaları her zaman indirebilir'), findsOneWidget);
    // A product the family did not buy cannot be shared.
    final notOwned = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).where((s) => s.onChanged == null);
    expect(notOwned.length, 1);
    expect(find.text('Satın alınmadı'), findsOneWidget);
  });

  testWidgets('sharing and revoking call the server per member and product', (tester) async {
    final repo = await _pump(tester, [
      for (final p in PremiumProduct.values) row('u-teyze', 'Zeynep', 'teyze', p, granted: p == PremiumProduct.book),
    ]);
    await tester.tap(find.widgetWithText(SwitchListTile, PremiumProduct.film.title));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, PremiumProduct.book.title));
    await tester.pumpAndSettle();
    expect(repo.calls, [('u-teyze', PremiumProduct.film, true), ('u-teyze', PremiumProduct.book, false)]);
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, PremiumProduct.film.title)).value, isTrue);
  });

  testWidgets('no Family Members yet', (tester) async {
    await _pump(tester, const []);
    expect(find.text('Aile üyesi yok'), findsOneWidget);
  });

  test('sharing refusals map to Turkish messages', () {
    final e = AppException.from(const PostgrestException(message: 'x', code: 'P0002', hint: 'member_not_found'));
    expect(e.message, 'Bu kişi bu bebeğin aile üyesi değil.');
  });
}
