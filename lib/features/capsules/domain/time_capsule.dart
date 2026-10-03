import '../../../core/utils/dates.dart';
import '../../family/domain/relation.dart';

enum CapsuleOccasion {
  age5('age_5', '5. yaş gününde', 5),
  age10('age_10', '10. yaş gününde', 10),
  age18('age_18', '18. yaş gününde', 18),
  custom('custom', 'Özel bir tarihte', null);

  const CapsuleOccasion(this.key, this.label, this.years);

  final String key;
  final String label;
  final int? years;

  static CapsuleOccasion fromKey(String? k) =>
      values.firstWhere((o) => o.key == k, orElse: () => CapsuleOccasion.custom);

  DateTime? openDateFor(DateTime birthDate) => years == null ? null : Dates.addYears(birthDate, years!);
}

class TimeCapsule {
  const TimeCapsule({
    required this.id,
    required this.babyId,
    required this.authorId,
    required this.authorName,
    required this.authorRelation,
    required this.authorRelationLabel,
    required this.title,
    required this.occasion,
    required this.openOn,
    required this.hasPhoto,
    required this.createdAt,
    this.body,
  });

  factory TimeCapsule.fromJson(Map<String, dynamic> j) {
    final contents = j['time_capsule_contents'];
    String? body;
    if (contents is Map) body = contents['body'] as String?;
    if (contents is List && contents.isNotEmpty) body = (contents.first as Map)['body'] as String?;
    return TimeCapsule(
      id: j['id'] as String,
      babyId: j['baby_id'] as String,
      authorId: j['author_id'] as String?,
      authorName: j['author_name'] as String? ?? '',
      authorRelation: Relation.fromKey(j['author_relation'] as String?),
      authorRelationLabel: j['author_relation_label'] as String?,
      title: j['title'] as String,
      occasion: CapsuleOccasion.fromKey(j['occasion'] as String?),
      openOn: Dates.fromSql(j['open_on'] as String),
      hasPhoto: j['has_photo'] as bool? ?? false,
      createdAt: DateTime.parse(j['created_at'] as String),
      body: body,
    );
  }

  final String id;
  final String babyId;
  final String? authorId;
  final String authorName;
  final Relation authorRelation;
  final String? authorRelationLabel;
  final String title;
  final CapsuleOccasion occasion;
  final DateTime openOn;
  final bool hasPhoto;
  final DateTime createdAt;

  /// Only present once the backend lets us read it (open_on <= today).
  final String? body;

  bool isOpen(DateTime today) => !Dates.dateOnly(today).isBefore(openOn);

  String get photoPath => '$babyId/capsules/$id/photo.jpg';

  String get signature {
    final rel = relationPossessive(authorRelation, authorRelationLabel);
    return authorName.trim().isEmpty ? rel : '$rel $authorName';
  }

  /// "3 yıl 2 ay sonra açılacak"
  String remainingLabel(DateTime today) {
    final t = Dates.dateOnly(today);
    if (isOpen(t)) return 'Açıldı';
    var months = (openOn.year - t.year) * 12 + (openOn.month - t.month);
    if (Dates.addMonths(t, months).isAfter(openOn)) months--;
    final years = months ~/ 12;
    final rem = months % 12;
    if (months <= 0) {
      final d = Dates.daysBetween(t, openOn);
      return '$d gün sonra açılacak';
    }
    final parts = [if (years > 0) '$years yıl', if (rem > 0) '$rem ay'];
    return '${parts.join(' ')} sonra açılacak';
  }
}
