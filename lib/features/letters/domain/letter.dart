import '../../../core/utils/dates.dart';
import '../../family/domain/relation.dart';

class Letter {
  const Letter({
    required this.id,
    required this.babyId,
    required this.authorId,
    required this.authorName,
    required this.authorRelation,
    required this.authorRelationLabel,
    required this.title,
    required this.body,
    required this.writtenOn,
    required this.includeInBook,
    required this.createdAt,
  });

  factory Letter.fromJson(Map<String, dynamic> j) => Letter(
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    authorId: j['author_id'] as String?,
    authorName: j['author_name'] as String? ?? '',
    authorRelation: Relation.fromKey(j['author_relation'] as String?),
    authorRelationLabel: j['author_relation_label'] as String?,
    title: j['title'] as String?,
    body: j['body'] as String,
    writtenOn: Dates.fromSql(j['written_on'] as String),
    includeInBook: j['include_in_book'] as bool? ?? true,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String babyId;
  final String? authorId;
  final String authorName;
  final Relation authorRelation;
  final String? authorRelationLabel;
  final String? title;
  final String body;
  final DateTime writtenOn;
  final bool includeInBook;
  final DateTime createdAt;

  /// "Teyzesi Zeynep"
  /// "Esra Teyzesi" – the signature in the official outputs (decision P-11).
  String get outputSignature => outputPersonName(authorName, authorRelation, authorRelationLabel);

  String get signature {
    final rel = relationPossessive(authorRelation, authorRelationLabel);
    return authorName.trim().isEmpty ? rel : '$rel $authorName';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'baby_id': babyId,
    'author_id': authorId,
    'author_name': authorName,
    'author_relation': authorRelation.key,
    'author_relation_label': authorRelationLabel,
    'title': title,
    'body': body,
    'written_on': Dates.toSql(writtenOn),
    'include_in_book': includeInBook,
    'created_at': createdAt.toIso8601String(),
  };
}
