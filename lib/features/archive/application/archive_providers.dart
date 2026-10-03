import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../data/archive_repository.dart';
import '../domain/archive_models.dart';

final archiveAccessProvider = FutureProvider.autoDispose.family<ArchiveAccess, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(archiveRepositoryProvider).access(babyId);
});

/// How often a queued / running build is polled.
final archivePollIntervalProvider = Provider<Duration>((ref) => const Duration(seconds: 5));

/// Latest job + ready archive; polls while the server is still building.
final archiveStateProvider = FutureProvider.autoDispose.family<ArchiveState, String>((ref, babyId) async {
  ref.watch(lifecycleRevisionProvider);
  final state = await ref.watch(archiveRepositoryProvider).state(babyId);
  if (state.isWorking) {
    final timer = Timer(ref.watch(archivePollIntervalProvider), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return state;
});
