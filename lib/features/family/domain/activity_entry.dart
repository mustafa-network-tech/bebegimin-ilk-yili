class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.actorId,
    required this.action,
    required this.details,
    required this.createdAt,
  });

  factory ActivityEntry.fromJson(Map<String, dynamic> j) => ActivityEntry(
    id: (j['id'] as num).toInt(),
    actorId: j['actor_id'] as String?,
    action: j['action'] as String,
    details: (j['details'] as Map?)?.cast<String, dynamic>() ?? const {},
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final int id;
  final String? actorId;
  final String action;
  final Map<String, dynamic> details;
  final DateTime createdAt;

  String get description => switch (action) {
    'member_joined' => 'aileye katıldı',
    'member_left' => 'aileden ayrıldı',
    'member_removed' => 'bir üyeyi aileden çıkardı',
    'member_updated' => 'bir üyenin rolünü veya yetkilerini değiştirdi',
    'invitation_created' => 'davet oluşturdu',
    'invitation_accepted' => 'daveti kabul etti',
    'invitation_revoked' => 'bir daveti iptal etti',
    'invitation_expired' => 'davetin süresi doldu',
    'memory_created' => 'anı ekledi: ${details['title'] ?? ''}',
    'milestone_created' => 'ilk kaydetti: ${details['title'] ?? ''}',
    'letter_created' => 'mektup yazdı',
    'book_generated' => 'İlk Yılım kitabını oluşturdu (sürüm ${details['version'] ?? ''})',
    _ => action,
  };
}
