import '../../../core/utils/dates.dart';
import 'memory.dart';

enum EntryType { memory, milestone, letter }

/// Row of the `timeline_entries` view.
class TimelineEntry {
  const TimelineEntry({
    required this.type,
    required this.id,
    required this.babyId,
    required this.date,
    required this.time,
    required this.title,
    required this.body,
    required this.authorId,
    required this.category,
    required this.milestoneId,
    required this.milestoneTypeId,
    required this.includeInBook,
    required this.createdAt,
  });

  factory TimelineEntry.fromJson(Map<String, dynamic> j) => TimelineEntry(
    type: EntryType.values.byName(j['entry_type'] as String),
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    date: Dates.fromSql(j['entry_date'] as String),
    time: j['entry_time'] as String?,
    title: j['title'] as String,
    body: j['body'] as String?,
    authorId: j['author_id'] as String?,
    category: j['category'] as String?,
    milestoneId: j['milestone_id'] as String?,
    milestoneTypeId: j['milestone_type_id'] as String?,
    includeInBook: j['include_in_book'] as bool? ?? true,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final EntryType type;
  final String id;
  final String babyId;
  final DateTime date;
  final String? time;
  final String title;
  final String? body;
  final String? authorId;
  final String? category;
  final String? milestoneId;
  final String? milestoneTypeId;
  final bool includeInBook;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'entry_type': type.name,
    'id': id,
    'baby_id': babyId,
    'entry_date': Dates.toSql(date),
    'entry_time': time,
    'title': title,
    'body': body,
    'author_id': authorId,
    'category': category,
    'milestone_id': milestoneId,
    'milestone_type_id': milestoneTypeId,
    'include_in_book': includeInBook,
    'created_at': createdAt.toIso8601String(),
  };

  MemoryCategory get memoryCategory => MemoryCategory.fromKey(category);

  /// Newest first; same day → by time, then creation.
  static int compareDesc(TimelineEntry a, TimelineEntry b) {
    final d = b.date.compareTo(a.date);
    if (d != 0) return d;
    final t = (b.time ?? '').compareTo(a.time ?? '');
    if (t != 0) return t;
    return b.createdAt.compareTo(a.createdAt);
  }
}
