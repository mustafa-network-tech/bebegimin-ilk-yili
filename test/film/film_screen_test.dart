import 'dart:typed_data';

import 'package:bebegimin_ilk_yili/app/theme.dart';
import 'package:bebegimin_ilk_yili/core/errors/app_exception.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_lifecycle_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/application/baby_providers.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby_lifecycle.dart';
import 'package:bebegimin_ilk_yili/features/film/application/film_providers.dart';
import 'package:bebegimin_ilk_yili/features/film/data/film_repository.dart';
import 'package:bebegimin_ilk_yili/features/film/domain/film_models.dart';
import 'package:bebegimin_ilk_yili/features/film/presentation/film_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fixtures.dart';

class _FakeFilmRepo implements FilmRepository {
  _FakeFilmRepo({
    this.accessValue = const FilmAccess(block: null, rendererEnabled: true),
    this.planValue = const FilmPlan(
      totalMs: 42500,
      maxMs: 600000,
      overLimit: false,
      excessMs: 0,
      photos: 1,
      videos: 1,
      memories: 1,
      milestones: 1,
      letters: 1,
    ),
    this.stateValue = FilmState.empty,
  });

  FilmAccess accessValue;
  FilmPlan planValue;
  FilmState stateValue;
  FilmSettings settingsValue = const FilmSettings();
  final saved = <FilmSettings>[];
  final renders = <String>[];
  var suggestions = 0;

  @override
  Future<FilmAccess> access(String babyId) async => accessValue;
  @override
  Future<FilmSettings> settings(String babyId) async => settingsValue;
  @override
  Future<FilmSettings> updateSettings(String babyId, FilmSettings settings) async {
    saved.add(settings);
    return settingsValue = settings;
  }

  @override
  Future<FilmPlan> plan(String babyId) async => planValue;
  @override
  Future<FilmSettings> suggest(String babyId) async {
    suggestions++;
    return const FilmSettings(excludedIds: ['a', 'b']);
  }

  @override
  Future<String> requestRender(String babyId, String idempotencyKey) async {
    renders.add(idempotencyKey);
    return 'job-1';
  }

  @override
  Future<FilmState> state(String babyId) async => stateValue;
  @override
  Future<Uint8List> download(FilmState state) async => Uint8List(0);
}

Widget _app(Widget child, _FakeFilmRepo repo, {bool active = false}) => ProviderScope(
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
    filmRepositoryProvider.overrideWithValue(repo),
    filmPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
  ],
  child: MaterialApp(theme: AppTheme.light(), home: child),
);

Future<void> _pump(WidgetTester tester, _FakeFilmRepo repo, {bool active = false}) async {
  await tester.pumpWidget(
    _app(
      FilmRouteGate(
        babyId: defne.id,
        child: FilmScreen(babyId: defne.id),
      ),
      repo,
      active: active,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  testWidgets('ACTIVE archive: the film is closed', (tester) async {
    await _pump(
      tester,
      _FakeFilmRepo(accessValue: const FilmAccess(block: 'premium_requires_locked', rendererEnabled: true)),
      active: true,
    );
    expect(find.text('İlk yıl devam ediyor'), findsOneWidget);
    expect(find.text('Filmi hazırla'), findsNothing);
  });

  testWidgets('LOCKED without the purchase: offer the store', (tester) async {
    await _pump(
      tester,
      _FakeFilmRepo(accessValue: const FilmAccess(block: 'entitlement_required', rendererEnabled: true)),
    );
    expect(find.text('Dijital ürünleri gör'), findsOneWidget);
    expect(find.text('Filmi hazırla'), findsNothing);
  });

  testWidgets('a Family Member never opens the film (decision P-12)', (tester) async {
    await _pump(tester, _FakeFilmRepo(accessValue: const FilmAccess(block: 'not_parent', rendererEnabled: true)));
    expect(find.text('Yalnızca Anne ve Baba'), findsOneWidget);
    expect(find.text('Filmi hazırla'), findsNothing);
    expect(find.text('Videolar'), findsNothing);
  });

  testWidgets('parent sees the server estimate and requests a render', (tester) async {
    final repo = _FakeFilmRepo();
    await _pump(tester, repo);
    expect(find.text('Tahmini süre: 43 sn'), findsOneWidget);
    expect(find.textContaining('az içerikte film uzatılmaz'), findsOneWidget);
    await tester.tap(find.text('Filmi hazırla'));
    await tester.pumpAndSettle();
    expect(repo.renders.single, startsWith('film-'));
  });

  testWidgets('over ten minutes: no render, the suggested selection can be applied', (tester) async {
    final repo = _FakeFilmRepo(
      planValue: const FilmPlan(
        totalMs: 600000,
        maxMs: 600000,
        overLimit: true,
        excessMs: 62000,
        photos: 331,
        videos: 1,
        memories: 1,
        milestones: 1,
        letters: 1,
      ),
    );
    await _pump(tester, repo);
    expect(find.text('10 dakikayı aşıyor'), findsOneWidget);
    expect(find.textContaining('1 dk 02 sn fazla'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Filmi hazırla'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.text('Önerilen seçimi uygula'));
    await tester.pumpAndSettle();
    expect(repo.suggestions, 1);
    expect(repo.saved.single.excludedIds, ['a', 'b']);
  });

  testWidgets('rendering: progress is shown and the planner is locked', (tester) async {
    await _pump(
      tester,
      _FakeFilmRepo(
        stateValue: const FilmState(jobId: 'j', jobStatus: 'running', progressPercent: 40, progressStage: 'encoding'),
      ),
    );
    expect(find.text('Film hazırlanıyor'), findsOneWidget);
    expect(find.text('Sahneler oluşturuluyor'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Filmi hazırla'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a broken media file can be excluded with one tap', (tester) async {
    final repo = _FakeFilmRepo(
      stateValue: const FilmState(
        jobId: 'j',
        jobStatus: 'poison',
        lastErrorCode: 'media_corrupt',
        failedMediaId: 'media-9',
      ),
    );
    await _pump(tester, repo);
    expect(find.textContaining('bozuk'), findsOneWidget);
    await tester.tap(find.text('Bu medyayı filmden çıkar'));
    await tester.pumpAndSettle();
    expect(repo.saved.single.excludedIds, ['media-9']);
  });

  testWidgets('ready film shows its probed duration and resolution', (tester) async {
    await _pump(
      tester,
      _FakeFilmRepo(
        stateValue: FilmState(
          jobId: 'j',
          jobStatus: 'succeeded',
          artifactId: 'art',
          artifactSha256: 'f' * 64,
          artifactSizeBytes: 12 * 1024 * 1024,
          durationMs: 245000,
          width: 1920,
          height: 1080,
          readyAt: DateTime.utc(2026, 10, 1),
        ),
      ),
    );
    expect(find.text('Filminiz hazır'), findsOneWidget);
    expect(find.textContaining('4 dk 05 sn · 1080p · 12,0 MB'), findsOneWidget);
    expect(find.text('İndir ve izle'), findsOneWidget);
  });

  test('film refusals map to Turkish messages', () {
    for (final hint in ['film_too_long', 'film_empty', 'film_renderer_disabled', 'film_render_in_progress']) {
      final e = AppException.from(PostgrestException(message: 'x', code: '55000', hint: hint));
      expect(e.message, isNot(startsWith('Sunucu hatası')), reason: hint);
    }
    expect(filmDurationLabel(42500), '43 sn');
    expect(filmDurationLabel(600000), '10 dk 00 sn');
    final s = FilmState.fromJson({'job_status': 'queued', 'progress_percent': 0, 'attempts': 0});
    expect([s.isWorking, s.hasFilm, s.canDownload], [true, false, false]);
  });
}
