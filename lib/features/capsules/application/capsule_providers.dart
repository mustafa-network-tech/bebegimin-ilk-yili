import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../data/capsule_repository.dart';
import '../domain/time_capsule.dart';

final capsulesProvider = FutureProvider.autoDispose.family<List<TimeCapsule>, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(capsuleRepositoryProvider).forBaby(babyId);
});
