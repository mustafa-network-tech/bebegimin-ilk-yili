import '../../../core/utils/dates.dart';

enum MediaKind { photo, video }

class MediaItem {
  const MediaItem({
    required this.id,
    required this.babyId,
    required this.uploaderId,
    required this.memoryId,
    required this.milestoneId,
    required this.letterId,
    required this.kind,
    required this.storagePath,
    required this.thumbPath,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.caption,
    required this.takenOn,
    required this.tags,
    required this.includeInBook,
    required this.status,
    required this.createdAt,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    uploaderId: j['uploader_id'] as String?,
    memoryId: j['memory_id'] as String?,
    milestoneId: j['milestone_id'] as String?,
    letterId: j['letter_id'] as String?,
    kind: MediaKind.values.byName(j['kind'] as String),
    storagePath: j['storage_path'] as String,
    thumbPath: j['thumb_path'] as String?,
    mimeType: j['mime_type'] as String,
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    durationMs: (j['duration_ms'] as num?)?.toInt(),
    caption: j['caption'] as String?,
    takenOn: Dates.fromSql(j['taken_on'] as String),
    tags: ((j['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
    includeInBook: j['include_in_book'] as bool? ?? true,
    status: j['status'] as String? ?? 'ready',
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String babyId;
  final String? uploaderId;
  final String? memoryId;
  final String? milestoneId;
  final String? letterId;
  final MediaKind kind;
  final String storagePath;
  final String? thumbPath;
  final String mimeType;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? caption;
  final DateTime takenOn;
  final List<String> tags;
  final bool includeInBook;
  final String status;
  final DateTime createdAt;

  bool get isVideo => kind == MediaKind.video;

  /// Small image for grids (videos fall back to a placeholder).
  String? get previewPath => thumbPath ?? (isVideo ? null : storagePath);

  double get aspectRatio => (width != null && height != null && height! > 0) ? width! / height! : 1;

  bool get isLandscape => aspectRatio > 1.05;

  Map<String, dynamic> toJson() => {
    'id': id,
    'baby_id': babyId,
    'uploader_id': uploaderId,
    'memory_id': memoryId,
    'milestone_id': milestoneId,
    'letter_id': letterId,
    'kind': kind.name,
    'storage_path': storagePath,
    'thumb_path': thumbPath,
    'mime_type': mimeType,
    'width': width,
    'height': height,
    'duration_ms': durationMs,
    'caption': caption,
    'taken_on': Dates.toSql(takenOn),
    'tags': tags,
    'include_in_book': includeInBook,
    'status': status,
    'created_at': createdAt.toIso8601String(),
  };

  String? get durationLabel {
    if (durationMs == null) return null;
    final s = durationMs! ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
