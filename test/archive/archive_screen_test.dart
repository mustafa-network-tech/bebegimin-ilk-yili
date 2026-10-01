import 'dart:typed_data';

import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/errors/app_exception.dart';
import 'package:bebegimin_ilk_yili/features/archive/application/archive_providers.dart';
import 'package:bebegimin_ilk_yili/features/archive/data/archive_repository.dart';
import 'package:bebegimin_ilk_yili/features/archive/domain/archive_models.dart';
import 'package:bebegimin_ilk_yili/features/archive/presentation/archive_screen.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fixtures.dart';

class _FakeArchiveRepo implements ArchiveRepository {
  _FakeArchiveRepo({
    this.accessValue = const ArchiveAccess(block: null, rendererEnabled: true),
    this.stateValue = ArchiveState.empty,
  });

  ArchiveAccess accessValue;
  ArchiveState stateValue;
  final requests = <String>[];

  @override
  Future<ArchiveAccess> access(String babyId) async => accessValue;
  @override
  Future<String> request(String babyId, String idempotencyKey) async {
    requests.add(idempotencyKey);
    return 'job-1';
  }

  @override
  Future<ArchiveState> state(String babyId) async => stateValue;
  @override
  Future<Uint8List> download(ArchiveState state) async => Uint8List(0);
}

Future<void> _pump(WidgetTester tester, _FakeArchiveRepo repo, {bool active = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        babiesProvider.overrideWithValue(AsyncData([defne])),
        activeBabyIdProvider.overrideWithBuild((ref, _) => defne.id),
        babyLifecycleProvider(defne.id).overrideWithValue(
          AsyncData(
            BabyLifecycle(
              babyId: defne.id,
              status: active ? BabyLifecycleStatus.active : BabyLifecycleStatus.locked,
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
        archiveRepositoryProvider.overrideWithValue(repo),
        archivePollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const ArchiveRouteGate(child: ArchiveScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  testWidgets('ACTIVE archive: closed', (tester) async {
    await _pump(
      tester,
      _FakeArchiveRepo(accessValue: const ArchiveAccess(block: 'premium_requires_locked', rendererEnabled: true)),
      active: true,
    );
    expect(find.text('İlk yıl devam ediyor'), findsOneWidget);
    expect(find.text('Arşivi hazırla'), findsNothing);
  });

  testWidgets('not purchased: offer the store', (tester) async {
    await _pump(
      tester,
      _FakeArchiveRepo(accessValue: const ArchiveAccess(block: 'entitlement_required', rendererEnabled: true)),
    );
    expect(find.text('Dijital ürünleri gör'), findsOneWidget);
  });

  testWidgets('parent requests a build; instructions are always shown', (tester) async {
    final repo = _FakeArchiveRepo();
    await _pump(tester, repo);
    expect(find.text('Nasıl açılır?'), findsOneWidget);
    await tester.tap(find.text('Arşivi hazırla'));
    await tester.pumpAndSettle();
    expect(repo.requests.single, startsWith('html-'));
  });

  testWidgets('building: progress, no second request', (tester) async {
    await _pump(
      tester,
      _FakeArchiveRepo(
        stateValue: const ArchiveState(jobId: 'j', jobStatus: 'running', progressPercent: 40, progressStage: 'media'),
      ),
    );
    expect(find.text('Arşiv hazırlanıyor'), findsOneWidget);
    expect(find.text('Fotoğraf ve videolar hazırlanıyor'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Arşivi hazırla'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('ready archive: size, entries, skipped media note, download', (tester) async {
    await _pump(
      tester,
      _FakeArchiveRepo(
        stateValue: ArchiveState(
          jobId: 'j',
          jobStatus: 'succeeded',
          artifactId: 'a',
          artifactSha256: 'e' * 64,
          artifactSizeBytes: 250 * 1024 * 1024,
          entryCount: 812,
          skippedMedia: 2,
          readyAt: DateTime.utc(2026, 10, 1),
        ),
      ),
    );
    expect(find.text('Arşiviniz hazır'), findsOneWidget);
    expect(find.textContaining('250,0 MB · 812 dosya'), findsOneWidget);
    expect(find.textContaining('2 fotoğraf / video dönüştürülemediği'), findsOneWidget);
    expect(find.text('İndir ve kaydet'), findsOneWidget);
    expect(find.text('Güncel kopyayı kontrol et'), findsOneWidget);
  });

  testWidgets('family member: ready archive only, no build button', (tester) async {
    await _pump(tester, _FakeArchiveRepo(accessValue: const ArchiveAccess(block: 'not_parent', rendererEnabled: true)));
    expect(find.text('Arşiv henüz hazır değil'), findsOneWidget);
    expect(find.text('Arşivi hazırla'), findsNothing);
  });

  test('archive refusals map to Turkish messages', () {
    for (final hint in ['html_renderer_disabled', 'html_render_in_progress']) {
      final e = AppException.from(PostgrestException(message: 'x', code: '55000', hint: hint));
      expect(e.message, isNot(startsWith('Sunucu hatası')), reason: hint);
    }
    expect(archiveErrorText('bundle_too_large'), contains('2 GB'));
    expect(const ArchiveState(artifactSizeBytes: 3 * 1024 * 1024 * 1024).sizeLabel, '3,0 GB');
  });
}
