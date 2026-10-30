import '../../../core/utils/dates.dart';

class MilestoneType {
  const MilestoneType({
    required this.id,
    required this.key,
    required this.babyId,
    required this.title,
    required this.emoji,
    required this.sortOrder,
    required this.createdBy,
  });

  factory MilestoneType.fromJson(Map<String, dynamic> j) => MilestoneType(
    id: j['id'] as String,
    key: j['key'] as String?,
    babyId: j['baby_id'] as String?,
    title: j['title'] as String,
    emoji: j['emoji'] as String?,
    sortOrder: (j['sort_order'] as num?)?.toInt() ?? 1000,
    createdBy: j['created_by'] as String?,
  );

  final String id;
  final String? key;
  final String? babyId;
  final String title;
  final String? emoji;
  final int sortOrder;
  final String? createdBy;

  bool get isCustom => babyId != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'key': key,
    'baby_id': babyId,
    'title': title,
    'emoji': emoji,
    'sort_order': sortOrder,
    'created_by': createdBy,
  };
}

class Milestone {
  const Milestone({
    required this.id,
    required this.babyId,
    required this.typeId,
    required this.achievedOn,
    required this.achievedTime,
    required this.description,
    required this.includeInBook,
    required this.createdBy,
    required this.createdAt,
  });

  factory Milestone.fromJson(Map<String, dynamic> j) => Milestone(
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    typeId: j['milestone_type_id'] as String,
    achievedOn: Dates.fromSql(j['achieved_on'] as String),
    achievedTime: j['achieved_time'] as String?,
    description: j['description'] as String?,
    includeInBook: j['include_in_book'] as bool? ?? true,
    createdBy: j['created_by'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String babyId;
  final String typeId;
  final DateTime achievedOn;
  final String? achievedTime;
  final String? description;
  final bool includeInBook;
  final String? createdBy;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'baby_id': babyId,
    'milestone_type_id': typeId,
    'achieved_on': Dates.toSql(achievedOn),
    'achieved_time': achievedTime,
    'description': description,
    'include_in_book': includeInBook,
    'created_by': createdBy,
    'created_at': createdAt.toIso8601String(),
  };
}

/// A milestone type together with the (optional) achievement.
class MilestoneSlot {
  const MilestoneSlot(this.type, this.milestone);

  final MilestoneType type;
  final Milestone? milestone;

  bool get achieved => milestone != null;
}
