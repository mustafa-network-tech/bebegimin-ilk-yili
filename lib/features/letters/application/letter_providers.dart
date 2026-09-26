import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../data/letter_repository.dart';
import '../domain/letter.dart';

final lettersProvider = FutureProvider.autoDispose.family<List<Letter>, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(letterRepositoryProvider).forBaby(babyId);
});

final letterDetailProvider = FutureProvider.autoDispose.family<Letter?, String>((ref, id) {
  ref.watch(contentRevisionProvider);
  return ref.watch(letterRepositoryProvider).get(id);
});
