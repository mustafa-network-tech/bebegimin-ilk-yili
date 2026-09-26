class Comment {
  const Comment({required this.id, required this.authorId, required this.body, required this.createdAt});

  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
    id: j['id'] as String,
    authorId: j['author_id'] as String?,
    body: j['body'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String? authorId;
  final String body;
  final DateTime createdAt;
}

/// What a comment / favorite is attached to.
enum TargetKind { memory, milestone, media, letter }

extension TargetKindColumn on TargetKind {
  String get column => switch (this) {
    TargetKind.memory => 'memory_id',
    TargetKind.milestone => 'milestone_id',
    TargetKind.media => 'media_id',
    TargetKind.letter => 'letter_id',
  };
}
