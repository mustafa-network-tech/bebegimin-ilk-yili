import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby.dart';
import 'package:bebegimin_ilk_yili/features/babies/presentation/route_baby.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Plan 2.4: the active baby is a UI convenience, never the implicit target
// of a write. A create form keeps the baby it was opened for.

final defne = Baby(id: 'baby-defne', firstName: 'Defne', birthDate: DateTime(2026, 1, 1));
final ece = Baby(id: 'baby-ece', firstName: 'Ece', birthDate: DateTime(2026, 3, 1));

class _Selection extends Notifier<Baby?> {
  @override
  Baby? build() => defne;

  void select(Baby b) => state = b;
}

final _selection = NotifierProvider<_Selection, Baby?>(_Selection.new);

void main() {
  testWidgets('a create route keeps the baby it was opened for', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeBabyProvider.overrideWith((ref) => ref.watch(_selection))],
        child: MaterialApp(home: PinnedActiveBaby(builder: (babyId) => Text('form:$babyId'))),
      ),
    );
    expect(find.text('form:baby-defne'), findsOneWidget);

    final container = ProviderScope.containerOf(tester.element(find.byType(PinnedActiveBaby)));
    container.read(_selection.notifier).select(ece);
    await tester.pump();
    expect(find.text('form:baby-defne'), findsOneWidget, reason: 'switching babies never retargets an open form');
    expect(find.text('form:baby-ece'), findsNothing);
  });

  testWidgets('a baby-scoped route of an unknown baby shows a neutral not-found page', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          babiesProvider.overrideWithValue(AsyncData([defne])),
        ],
        child: const MaterialApp(home: RouteBabyMissing()),
      ),
    );
    expect(find.text('Sayfa bulunamadı'), findsOneWidget);
  });
}
