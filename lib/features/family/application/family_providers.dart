import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../../babies/application/baby_lifecycle_providers.dart';
import '../../babies/application/baby_providers.dart';
import '../data/family_repository.dart';
import '../domain/activity_entry.dart';
import '../domain/family_member.dart';
import '../domain/invitation.dart';
import '../domain/permission.dart';

final membersProvider = FutureProvider.family<List<FamilyMember>, String>(
  (ref, babyId) => ref.watch(familyRepositoryProvider).members(babyId),
);

/// The current user's membership for a baby.
final myMembershipProvider = Provider.family<FamilyMember?, String>((ref, babyId) {
  final uid = ref.watch(currentUserIdProvider);
  final members = ref.watch(membersProvider(babyId)).value;
  return members?.firstWhereOrNull((m) => m.userId == uid);
});

/// Membership permissions combined with the server lifecycle: once the
/// archive is LOCKED every archive-writing permission is switched off, so
/// "+", add, edit and delete actions disappear everywhere at once.
final accessProvider = Provider.family<MemberAccess, String>((ref, babyId) {
  final membership = ref.watch(myMembershipProvider(babyId));
  if (membership == null) return MemberAccess.none;
  return membership.access.withArchiveLocked(ref.watch(babyArchiveLockedProvider(babyId)));
});

/// Access for the active baby (UI convenience).
final activeAccessProvider = Provider<MemberAccess>((ref) {
  final baby = ref.watch(activeBabyProvider);
  return baby == null ? MemberAccess.none : ref.watch(accessProvider(baby.id));
});

final invitationsProvider = FutureProvider.autoDispose.family<List<Invitation>, String>(
  (ref, babyId) => ref.watch(familyRepositoryProvider).invitations(babyId),
);

final activityProvider = FutureProvider.autoDispose.family<List<ActivityEntry>, String>(
  (ref, babyId) => ref.watch(familyRepositoryProvider).activity(babyId),
);

/// Display name for an author id inside a baby's family.
final authorNameProvider = Provider.family<String, (String babyId, String? userId)>((ref, key) {
  final (babyId, userId) = key;
  if (userId == null) return 'Eski bir aile üyesi';
  final members = ref.watch(membersProvider(babyId)).value;
  final m = members?.firstWhereOrNull((m) => m.userId == userId);
  if (m == null) return 'Eski bir aile üyesi';
  return m.introduction;
});
