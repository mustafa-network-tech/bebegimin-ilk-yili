import '../../../core/utils/dates.dart';
import 'media_item.dart';

enum UploadState { queued, uploading, failed }

/// A photo / video waiting to be uploaded. Persisted locally so an upload
/// interrupted by a lost connection or a killed app resumes later.
class PendingUpload {
  const PendingUpload({
    required this.id,
    required this.babyId,
    required this.kind,
    required this.localPath,
    required this.mimeType,
    required this.takenOn,
    this.memoryId,
    this.milestoneId,
    this.letterId,
    this.caption,
    this.tags = const [],
    this.durationMs,
    this.attempts = 0,
    this.state = UploadState.queued,
    this.error,
    this.rowCreated = false,
  });

  factory PendingUpload.fromJson(Map<String, dynamic> j) => PendingUpload(
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    kind: MediaKind.values.byName(j['kind'] as String),
    localPath: j['local_path'] as String,
    mimeType: j['mime_type'] as String,
    takenOn: Dates.fromSql(j['taken_on'] as String),
    memoryId: j['memory_id'] as String?,
    milestoneId: j['milestone_id'] as String?,
    letterId: j['letter_id'] as String?,
    caption: j['caption'] as String?,
    tags: ((j['tags'] as List?) ?? const []).cast<String>(),
    durationMs: j['duration_ms'] as int?,
    attempts: j['attempts'] as int? ?? 0,
    state: UploadState.values.byName(j['state'] as String? ?? 'queued'),
    error: j['error'] as String?,
    rowCreated: j['row_created'] as bool? ?? false,
  );

  /// Media id (generated on the device, so retries are idempotent).
  final String id;
  final String babyId;
  final MediaKind kind;
  final String localPath;
  final String mimeType;
  final DateTime takenOn;
  final String? memoryId;
  final String? milestoneId;
  final String? letterId;
  final String? caption;
  final List<String> tags;
  final int? durationMs;
  final int attempts;
  final UploadState state;
  final String? error;
  final bool rowCreated;

  String get extension => kind == MediaKind.photo ? 'jpg' : localPath.split('.').last.toLowerCase();

  String get storagePath => '$babyId/$id/original.$extension';

  String? get thumbPath => kind == MediaKind.photo ? '$babyId/$id/thumb.jpg' : null;

  PendingUpload copyWith({
    int? attempts,
    UploadState? state,
    String? error,
    bool clearError = false,
    bool? rowCreated,
  }) => PendingUpload(
    id: id,
    babyId: babyId,
    kind: kind,
    localPath: localPath,
    mimeType: mimeType,
    takenOn: takenOn,
    memoryId: memoryId,
    milestoneId: milestoneId,
    letterId: letterId,
    caption: caption,
    tags: tags,
    durationMs: durationMs,
    attempts: attempts ?? this.attempts,
    state: state ?? this.state,
    error: clearError ? null : (error ?? this.error),
    rowCreated: rowCreated ?? this.rowCreated,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'baby_id': babyId,
    'kind': kind.name,
    'local_path': localPath,
    'mime_type': mimeType,
    'taken_on': Dates.toSql(takenOn),
    'memory_id': memoryId,
    'milestone_id': milestoneId,
    'letter_id': letterId,
    'caption': caption,
    'tags': tags,
    'duration_ms': durationMs,
    'attempts': attempts,
    'state': state.name,
    'error': error,
    'row_created': rowCreated,
  };
}
