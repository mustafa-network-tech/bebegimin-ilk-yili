import '../../../core/content/content_route.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.babyId,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.readAt,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: j['id'] as String,
    babyId: j['baby_id'] as String?,
    type: j['type'] as String,
    title: j['title'] as String,
    body: j['body'] as String?,
    data: (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    readAt: j['read_at'] == null ? null : DateTime.parse(j['read_at'] as String),
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String? babyId;
  final String type;
  final String title;
  final String? body;
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;

  /// In-app route this notification points to.
  String? get route {
    final target = data['target_type'] as String?;
    final id = data['target_id'] as String?;
    switch (type) {
      case 'book_ready':
      case 'book_generated':
        return babyId == null ? '/home' : '/babies/$babyId/book';
      case 'time_capsule_opened':
        return '/capsules';
      case 'member_joined':
        return '/family';
      case 'memories_of_the_day':
        final date = data['date'] as String?;
        return date == null ? '/timeline' : '/calendar?date=$date';
    }
    if (id == null || babyId == null) return null;
    return switch (target) {
      'memories' => contentRoute(ContentRouteKind.memory, babyId!, id),
      'milestones' => contentRoute(ContentRouteKind.milestone, babyId!, id),
      'letters' => contentRoute(ContentRouteKind.letter, babyId!, id),
      _ => null,
    };
  }
}
