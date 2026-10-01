import '../../../core/utils/dates.dart';

/// Server-side offline archive gate for the signed-in user (`html_access_state`).
class ArchiveAccess {
  const ArchiveAccess({required this.block, required this.rendererEnabled});

  factory ArchiveAccess.fromJson(Map<String, dynamic> j) =>
      ArchiveAccess(block: j['access_block'] as String?, rendererEnabled: j['renderer_enabled'] as bool? ?? false);

  /// null = LOCKED + live family subscription + HTML entitlement + parent.
  final String? block;
  final bool rendererEnabled;

  bool get canCreate => block == null;

  /// Purchased, but the caller is a Family Member: the ready archive only.
  bool get isFamilyMemberView => block == 'not_parent';

  bool get canView => canCreate || isFamilyMemberView;
}

/// Latest archive job and latest ready archive (`html_state`).
class ArchiveState {
  const ArchiveState({
    this.jobId,
    this.jobStatus,
    this.lastErrorCode,
    this.progressPercent = 0,
    this.progressStage,
    this.artifactId,
    this.artifactSizeBytes,
    this.artifactSha256,
    this.entryCount,
    this.skippedMedia = 0,
    this.readyAt,
    this.downloadBlock,
  });

  factory ArchiveState.fromJson(Map<String, dynamic> j) => ArchiveState(
    jobId: j['job_id'] as String?,
    jobStatus: j['job_status'] as String?,
    lastErrorCode: j['last_error_code'] as String?,
    progressPercent: (j['progress_percent'] as num?)?.toInt() ?? 0,
    progressStage: j['progress_stage'] as String?,
    artifactId: j['artifact_id'] as String?,
    artifactSizeBytes: (j['artifact_size_bytes'] as num?)?.toInt(),
    artifactSha256: j['artifact_sha256'] as String?,
    entryCount: (j['entry_count'] as num?)?.toInt(),
    skippedMedia: (j['skipped_media'] as num?)?.toInt() ?? 0,
    readyAt: j['ready_at'] == null ? null : DateTime.parse(j['ready_at'] as String),
    downloadBlock: j['download_block'] as String?,
  );

  static const empty = ArchiveState();

  final String? jobId;
  final String? jobStatus;
  final String? lastErrorCode;
  final int progressPercent;
  final String? progressStage;
  final String? artifactId;
  final int? artifactSizeBytes;
  final String? artifactSha256;
  final int? entryCount;
  final int skippedMedia;
  final DateTime? readyAt;
  final String? downloadBlock;

  bool get isWorking => jobStatus == 'queued' || jobStatus == 'running';

  bool get hasFailed => jobStatus == 'poison';

  bool get hasArchive => artifactId != null && artifactSha256 != null;

  bool get canDownload => hasArchive && downloadBlock == null;

  String get readyLabel => readyAt == null ? '' : Dates.long(readyAt!.toLocal());

  String get sizeLabel {
    final b = artifactSizeBytes;
    if (b == null) return '';
    if (b >= 1024 * 1024 * 1024) return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} GB';
    return '${(b / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
}

String archiveStageLabel(String? stage) => switch (stage) {
  'queued' => 'Sırada bekliyor',
  'media' => 'Fotoğraf ve videolar hazırlanıyor',
  'pages' => 'Sayfalar oluşturuluyor',
  'packing' || 'verifying' => 'Paket hazırlanıyor ve doğrulanıyor',
  'uploading' => 'Arşiv kaydediliyor',
  _ => 'Hazırlanıyor',
};

String archiveErrorText(String? code) => switch (code) {
  'bundle_too_large' => 'Arşiv 2 GB sınırını aştığı için hazırlanamadı. Lütfen destek ile iletişime geçin.',
  'subscription_inactive' => 'Aile paketi etkin olmadığı için hazırlama durduruldu.',
  'entitlement_revoked' => 'Arşiv satın alımı etkin olmadığı için hazırlama durduruldu.',
  'lifecycle_reopened' => 'Arşiv yeniden açıldığı için hazırlama durduruldu.',
  _ => 'Arşiv hazırlanamadı. Lütfen tekrar deneyin.',
};
