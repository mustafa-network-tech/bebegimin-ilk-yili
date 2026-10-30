import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/features/app_config/app_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, {required int build, ClientRequirements? req}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appBuildProvider.overrideWithValue(build),
        clientRequirementsProvider.overrideWith((ref) async => req),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const UpgradeGate(child: Text('APP')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('supported build opens the app', (tester) async {
    await _pump(tester, build: 7, req: const ClientRequirements(minSupportedBuild: 7, latestBuild: 9));
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('a build below the server minimum must upgrade', (tester) async {
    await _pump(tester, build: 6, req: const ClientRequirements(minSupportedBuild: 7, latestBuild: 9));
    expect(find.text('APP'), findsNothing);
    expect(find.text('Güncelleme gerekiyor'), findsOneWidget);
  });

  testWidgets('unknown requirements (offline) never block the app', (tester) async {
    await _pump(tester, build: 1);
    expect(find.text('APP'), findsOneWidget);
  });
}
