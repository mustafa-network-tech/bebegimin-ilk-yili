import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../data/baby_lifecycle_repository.dart';
import '../domain/baby_lifecycle.dart';

/// Injectable clock so tests can cross the Istanbul midnight boundary.
final lifecycleClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Server-authoritative lifecycle of one baby (always keyed by baby id, never
/// by the active selection). Refetched on app resume, after a backend
/// "lifecycle locked" refusal and at the next Istanbul midnight.
final babyLifecycleProvider = FutureProvider.family<BabyLifecycle, String>((ref, babyId) async {
  ref.watch(lifecycleRevisionProvider);
  final now = ref.watch(lifecycleClockProvider);
  final summary = await ref.watch(babyLifecycleRepositoryProvider).summary(babyId);
  final timer = Timer(BabyLifecycle.untilNextBusinessDay(now()) + const Duration(seconds: 5), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return summary.tightenedFor(now());
});

/// `true` only when the server confirmed the archive is writable. Unknown
/// (loading / error without cache) is treated as locked so the UI never
/// offers an action the backend may refuse.
final babyArchiveLockedProvider = Provider.family<bool, String>(
  (ref, babyId) => ref.watch(babyLifecycleProvider(babyId)).value?.isLocked ?? true,
);
