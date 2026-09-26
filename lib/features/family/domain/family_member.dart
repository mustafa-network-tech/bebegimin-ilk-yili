import 'permission.dart';
import 'relation.dart';

class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.babyId,
    required this.userId,
    required this.relation,
    required this.relationLabel,
    required this.isAdmin,
    required this.permissions,
    required this.joinedAt,
    required this.displayName,
    required this.avatarPath,
  });

  factory FamilyMember.fromJson(Map<String, dynamic> j) {
    final profile = j['profiles'] as Map<String, dynamic>?;
    return FamilyMember(
      id: j['id'] as String,
      babyId: j['baby_id'] as String,
      userId: j['user_id'] as String,
      relation: Relation.fromKey(j['relation'] as String?),
      relationLabel: j['relation_label'] as String?,
      isAdmin: j['is_admin'] as bool? ?? false,
      permissions: AppPermission.parse(j['permissions'] as List?),
      joinedAt: DateTime.parse(j['joined_at'] as String),
      displayName: (profile?['display_name'] as String?) ?? '',
      avatarPath: profile?['avatar_path'] as String?,
    );
  }

  final String id;
  final String babyId;
  final String userId;
  final Relation relation;
  final String? relationLabel;
  final bool isAdmin;
  final Set<AppPermission> permissions;
  final DateTime joinedAt;
  final String displayName;
  final String? avatarPath;

  Map<String, dynamic> toJson() => {
    'id': id,
    'baby_id': babyId,
    'user_id': userId,
    'relation': relation.key,
    'relation_label': relationLabel,
    'is_admin': isAdmin,
    'permissions': permissions.map((p) => p.key).toList(),
    'joined_at': joinedAt.toIso8601String(),
    'profiles': {'display_name': displayName, 'avatar_path': avatarPath},
  };

  String get relationName => relationText(relation, relationLabel);

  /// "Teyzesi Zeynep" – how the member is introduced in texts.
  String get introduction {
    final name = displayName.trim();
    final rel = relationPossessive(relation, relationLabel);
    return name.isEmpty ? rel : '$rel $name';
  }

  String get shownName => displayName.trim().isEmpty ? relationName : displayName.trim();

  MemberAccess get access => MemberAccess(isAdmin: isAdmin, permissions: permissions, userId: userId);
}
