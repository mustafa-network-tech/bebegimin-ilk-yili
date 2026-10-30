import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../data/film_repository.dart';
import '../domain/film_models.dart';

final filmAccessProvider = FutureProvider.autoDispose.family<FilmAccess, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(filmRepositoryProvider).access(babyId);
});

final filmSettingsProvider = FutureProvider.autoDispose.family<FilmSettings, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(filmRepositoryProvider).settings(babyId);
});

/// Recomputed on the server whenever the settings change.
final filmPlanProvider = FutureProvider.autoDispose.family<FilmPlan, String>((ref, babyId) async {
  await ref.watch(filmSettingsProvider(babyId).future);
  return ref.watch(filmRepositoryProvider).plan(babyId);
});

/// How often a queued / running render is polled.
final filmPollIntervalProvider = Provider<Duration>((ref) => const Duration(seconds: 5));

/// Latest job + ready film; polls while the server is still rendering.
final filmStateProvider = FutureProvider.autoDispose.family<FilmState, String>((ref, babyId) async {
  ref.watch(lifecycleRevisionProvider);
  final state = await ref.watch(filmRepositoryProvider).state(babyId);
  if (state.isWorking) {
    final timer = Timer(ref.watch(filmPollIntervalProvider), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return state;
});
