import '../../../core/utils/dates.dart';

/// Server-side film gate for the signed-in user (`film_access_state`).
class FilmAccess {
  const FilmAccess({required this.block, required this.rendererEnabled});

  factory FilmAccess.fromJson(Map<String, dynamic> j) =>
      FilmAccess(block: j['access_block'] as String?, rendererEnabled: j['renderer_enabled'] as bool? ?? false);

  /// null = LOCKED + live family subscription + film entitlement + parent.
  final String? block;
  final bool rendererEnabled;

  bool get canEdit => block == null;

  /// Purchased, but the caller is a Family Member: the ready film only.
  bool get isFamilyMemberView => block == 'not_parent';

  bool get canView => canEdit || isFamilyMemberView;
}

/// Film project choices (`film_update_settings`).
class FilmSettings {
  const FilmSettings({
    this.includeVideos = true,
    this.includeMilestones = true,
    this.includeMemoryTexts = true,
    this.includeLetters = true,
    this.excludedIds = const [],
    this.title,
  });

  factory FilmSettings.fromJson(Map<String, dynamic> j) => FilmSettings(
    includeVideos: j['include_videos'] as bool? ?? true,
    includeMilestones: j['include_milestones'] as bool? ?? true,
    includeMemoryTexts: j['include_memory_texts'] as bool? ?? true,
    includeLetters: j['include_letters'] as bool? ?? true,
    excludedIds: ((j['excluded_ids'] as List?) ?? const []).map((e) => e.toString()).toList(),
    title: j['title'] as String?,
  );

  final bool includeVideos;
  final bool includeMilestones;
  final bool includeMemoryTexts;
  final bool includeLetters;
  final List<String> excludedIds;
  final String? title;

  FilmSettings copyWith({
    bool? includeVideos,
    bool? includeMilestones,
    bool? includeMemoryTexts,
    bool? includeLetters,
    List<String>? excludedIds,
  }) => FilmSettings(
    includeVideos: includeVideos ?? this.includeVideos,
    includeMilestones: includeMilestones ?? this.includeMilestones,
    includeMemoryTexts: includeMemoryTexts ?? this.includeMemoryTexts,
    includeLetters: includeLetters ?? this.includeLetters,
    excludedIds: excludedIds ?? this.excludedIds,
    title: title,
  );

  Map<String, dynamic> toJson() => {
    'include_videos': includeVideos,
    'include_milestones': includeMilestones,
    'include_memory_texts': includeMemoryTexts,
    'include_letters': includeLetters,
    'excluded_ids': excludedIds,
    'title': title,
  };
}

/// Server-computed duration estimate for the current settings (`film_plan`).
class FilmPlan {
  const FilmPlan({
    required this.totalMs,
    required this.maxMs,
    required this.overLimit,
    required this.excessMs,
    required this.photos,
    required this.videos,
    required this.memories,
    required this.milestones,
    required this.letters,
  });

  factory FilmPlan.fromJson(Map<String, dynamic> j) => FilmPlan(
    totalMs: (j['total_duration_ms'] as num).toInt(),
    maxMs: (j['max_duration_ms'] as num?)?.toInt() ?? 600000,
    overLimit: j['over_limit'] as bool? ?? false,
    excessMs: (j['excess_ms'] as num?)?.toInt() ?? 0,
    photos: (j['photos'] as num?)?.toInt() ?? 0,
    videos: (j['videos'] as num?)?.toInt() ?? 0,
    memories: (j['memories'] as num?)?.toInt() ?? 0,
    milestones: (j['milestones'] as num?)?.toInt() ?? 0,
    letters: (j['letters'] as num?)?.toInt() ?? 0,
  );

  final int totalMs;
  final int maxMs;
  final bool overLimit;
  final int excessMs;
  final int photos;
  final int videos;
  final int memories;
  final int milestones;
  final int letters;

  bool get isEmpty => photos + videos + memories + milestones + letters == 0;
}

/// Latest film job and latest ready film (`film_state`).
class FilmState {
  const FilmState({
    this.jobId,
    this.jobStatus,
    this.attempts = 0,
    this.lastErrorCode,
    this.failedMediaId,
    this.progressPercent = 0,
    this.progressStage,
    this.plannedDurationMs,
    this.artifactId,
    this.artifactSizeBytes,
    this.artifactSha256,
    this.durationMs,
    this.width,
    this.height,
    this.readyAt,
    this.downloadBlock,
  });

  factory FilmState.fromJson(Map<String, dynamic> j) => FilmState(
    jobId: j['job_id'] as String?,
    jobStatus: j['job_status'] as String?,
    attempts: (j['attempts'] as num?)?.toInt() ?? 0,
    lastErrorCode: j['last_error_code'] as String?,
    failedMediaId: j['failed_media_id'] as String?,
    progressPercent: (j['progress_percent'] as num?)?.toInt() ?? 0,
    progressStage: j['progress_stage'] as String?,
    plannedDurationMs: (j['planned_duration_ms'] as num?)?.toInt(),
    artifactId: j['artifact_id'] as String?,
    artifactSizeBytes: (j['artifact_size_bytes'] as num?)?.toInt(),
    artifactSha256: j['artifact_sha256'] as String?,
    durationMs: (j['duration_ms'] as num?)?.toInt(),
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    readyAt: j['ready_at'] == null ? null : DateTime.parse(j['ready_at'] as String),
    downloadBlock: j['download_block'] as String?,
  );

  static const empty = FilmState();

  final String? jobId;
  final String? jobStatus;
  final int attempts;
  final String? lastErrorCode;
  final String? failedMediaId;
  final int progressPercent;
  final String? progressStage;
  final int? plannedDurationMs;
  final String? artifactId;
  final int? artifactSizeBytes;
  final String? artifactSha256;
  final int? durationMs;
  final int? width;
  final int? height;
  final DateTime? readyAt;
  final String? downloadBlock;

  bool get isWorking => jobStatus == 'queued' || jobStatus == 'running';

  bool get hasFailed => jobStatus == 'poison';

  bool get hasFilm => artifactId != null && artifactSha256 != null;

  bool get canDownload => hasFilm && downloadBlock == null;

  String get readyLabel => readyAt == null ? '' : Dates.long(readyAt!.toLocal());

  String get sizeLabel {
    final b = artifactSizeBytes;
    if (b == null) return '';
    return '${(b / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
}

/// "4 dk 05 sn" / "42 sn".
String filmDurationLabel(int ms) {
  final total = (ms / 1000).round();
  final m = total ~/ 60;
  final s = total % 60;
  if (m == 0) return '$s sn';
  return '$m dk ${s.toString().padLeft(2, '0')} sn';
}

String filmStageLabel(String? stage) => switch (stage) {
  'queued' => 'Sırada bekliyor',
  'downloading' => 'Fotoğraf ve videolar hazırlanıyor',
  'encoding' => 'Sahneler oluşturuluyor',
  'muxing' => 'Film birleştiriliyor',
  'uploading' || 'verifying' => 'Film kaydediliyor',
  _ => 'Hazırlanıyor',
};

String filmErrorText(String? code) => switch (code) {
  'media_corrupt' => 'Bir video veya fotoğraf bozuk olduğu için film hazırlanamadı.',
  'media_unsupported' => 'Bir video veya fotoğraf desteklenmeyen biçimde olduğu için film hazırlanamadı.',
  'media_missing' => 'Bir video veya fotoğraf bulunamadığı için film hazırlanamadı.',
  'duration_exceeded' ||
  'duration_mismatch' ||
  'profile_mismatch' => 'Film doğrulamadan geçemedi. Lütfen tekrar deneyin; sorun sürerse destek ile iletişime geçin.',
  'subscription_inactive' => 'Aile paketi etkin olmadığı için hazırlama durduruldu.',
  'entitlement_revoked' => 'Film satın alımı etkin olmadığı için hazırlama durduruldu.',
  'lifecycle_reopened' => 'Arşiv yeniden açıldığı için hazırlama durduruldu.',
  _ => 'Film hazırlanamadı. Lütfen tekrar deneyin.',
};
