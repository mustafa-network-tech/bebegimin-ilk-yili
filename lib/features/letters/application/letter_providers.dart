import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_route.dart';
import '../../../core/content/content_revision.dart';
import '../data/letter_repository.dart';
import '../domain/letter.dart';

final lettersProvider = FutureProvider.autoDispose.family<List<Letter>, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(letterRepositoryProvider).forBaby(babyId);
});

final letterDetailProvider = FutureProvider.autoDispose.family<Letter?, (String babyId, String id)>((ref, key) async {
  ref.watch(contentRevisionProvider);
  final letter = await ref.watch(letterRepositoryProvider).get(key.$1, key.$2);
  if (letter == null) return null;
  return matchesBabyContext(routeBabyId: key.$1, modelBabyId: letter.babyId, contentId: key.$2) ? letter : null;
});
