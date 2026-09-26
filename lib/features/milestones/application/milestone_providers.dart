import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../data/milestone_repository.dart';
import '../domain/milestone.dart';

final milestoneTypesProvider = FutureProvider.autoDispose.family<List<MilestoneType>, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(milestoneRepositoryProvider).types(babyId);
});

final milestonesProvider = FutureProvider.autoDispose.family<List<Milestone>, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(milestoneRepositoryProvider).forBaby(babyId);
});

/// Achieved firsts (chronological) followed by the ones still to come.
final milestoneSlotsProvider = FutureProvider.autoDispose.family<List<MilestoneSlot>, String>((ref, babyId) async {
  final types = await ref.watch(milestoneTypesProvider(babyId).future);
  final milestones = await ref.watch(milestonesProvider(babyId).future);
  final byType = {for (final m in milestones) m.typeId: m};
  final achieved = types.where((t) => byType.containsKey(t.id)).map((t) => MilestoneSlot(t, byType[t.id])).toList()
    ..sort((a, b) => a.milestone!.achievedOn.compareTo(b.milestone!.achievedOn));
  final upcoming = types.where((t) => !byType.containsKey(t.id)).map((t) => MilestoneSlot(t, null)).toList();
  return [...achieved, ...upcoming];
});

final milestoneDetailProvider = FutureProvider.autoDispose.family<MilestoneSlot?, (String babyId, String id)>((
  ref,
  key,
) async {
  final slots = await ref.watch(milestoneSlotsProvider(key.$1).future);
  return slots.firstWhereOrNull((s) => s.milestone?.id == key.$2);
});
