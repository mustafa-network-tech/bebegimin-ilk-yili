import 'package:flutter/material.dart';

import '../../../core/utils/dates.dart';

enum MemoryCategory {
  moment('moment', 'An', Icons.auto_awesome_outlined),
  photo('photo', 'Fotoğraf', Icons.photo_outlined),
  video('video', 'Video', Icons.videocam_outlined),
  specialDay('special_day', 'Özel gün', Icons.celebration_outlined),
  family('family', 'Aile', Icons.family_restroom_outlined),
  travel('travel', 'Seyahat', Icons.luggage_outlined),
  health('health', 'Sağlık', Icons.favorite_border_rounded),
  growth('growth', 'Gelişim', Icons.trending_up_rounded),
  first('first', 'İlk', Icons.star_outline_rounded),
  other('other', 'Diğer', Icons.more_horiz_rounded);

  const MemoryCategory(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;

  static MemoryCategory fromKey(String? key) =>
      values.firstWhere((c) => c.key == key, orElse: () => MemoryCategory.moment);
}

class Memory {
  const Memory({
    required this.id,
    required this.babyId,
    required this.authorId,
    required this.title,
    required this.body,
    required this.date,
    required this.time,
    required this.category,
    required this.milestoneId,
    required this.includeInBook,
    required this.createdAt,
  });

  factory Memory.fromJson(Map<String, dynamic> j) => Memory(
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    authorId: j['author_id'] as String?,
    title: j['title'] as String,
    body: j['body'] as String?,
    date: Dates.fromSql(j['memory_date'] as String),
    time: j['memory_time'] as String?,
    category: MemoryCategory.fromKey(j['category'] as String?),
    milestoneId: j['milestone_id'] as String?,
    includeInBook: j['include_in_book'] as bool? ?? true,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String babyId;
  final String? authorId;
  final String title;
  final String? body;
  final DateTime date;
  final String? time;
  final MemoryCategory category;
  final String? milestoneId;
  final bool includeInBook;
  final DateTime createdAt;
}

/// Payload used for create / update.
class MemoryDraft {
  const MemoryDraft({
    required this.babyId,
    required this.title,
    required this.date,
    this.body,
    this.time,
    this.category = MemoryCategory.moment,
    this.milestoneId,
    this.includeInBook = true,
  });

  final String babyId;
  final String title;
  final String? body;
  final DateTime date;
  final TimeOfDay? time;
  final MemoryCategory category;
  final String? milestoneId;
  final bool includeInBook;

  Map<String, dynamic> toJson() => {
    'baby_id': babyId,
    'title': title.trim(),
    'body': (body?.trim().isEmpty ?? true) ? null : body!.trim(),
    'memory_date': Dates.toSql(date),
    'memory_time': time == null
        ? null
        : '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}:00',
    'category': category.key,
    'milestone_id': milestoneId,
    'include_in_book': includeInBook,
  };
}
