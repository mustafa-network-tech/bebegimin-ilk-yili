import '../../../core/utils/dates.dart';

/// Physical formats. Sizes are the TRIM size in millimetres; the PDF adds
/// [bleedMm] on every side for professional printing.
enum BookFormat {
  a4Portrait('a4_portrait', 'A4 dikey', '21 × 29,7 cm', 210, 297, 14),
  square21('square_21', 'Kare', '21 × 21 cm', 210, 210, 12),
  square30('square_30', 'Büyük kare', '30 × 30 cm', 300, 300, 16);

  const BookFormat(this.key, this.label, this.sizeLabel, this.widthMm, this.heightMm, this.marginMm);

  final String key;
  final String label;
  final String sizeLabel;
  final double widthMm;
  final double heightMm;

  /// Safe area inside the trim line.
  final double marginMm;

  static const double bleedMm = 3;

  static BookFormat fromKey(String? k) => values.firstWhere((f) => f.key == k, orElse: () => BookFormat.square21);

  bool get isSquare => widthMm == heightMm;
}

enum BookQuality {
  /// Fast preview / sharing on phones (short image side in px).
  screen('screen', 'Paylaşım kalitesi', 1000, 80),

  /// High resolution for printing (~300 dpi on a 17 cm wide photo).
  print('print', 'Baskı kalitesi', 2000, 90);

  const BookQuality(this.key, this.label, this.maxImagePx, this.jpegQuality);

  final String key;
  final String label;
  final int maxImagePx;
  final int jpegQuality;
}

enum BookPageType {
  cover('cover'),
  welcome('welcome'),
  birth('birth'),
  month('month'),
  milestones('milestones'),
  letters('letters'),
  oneYear('one_year'),
  backCover('back_cover'),
  custom('custom');

  const BookPageType(this.key);

  final String key;

  static BookPageType fromKey(String k) => values.firstWhere((t) => t.key == k);

  String defaultTitle(String babyName, [int? monthNo]) => switch (this) {
    cover => 'Kapak',
    welcome => 'Hoş geldin, $babyName',
    birth => 'Doğum bilgilerim',
    month => '$monthNo. Ayım',
    milestones => 'İlklerim',
    letters => 'Ailemden Bana',
    oneYear => 'Bir Yaşındayım',
    backCover => 'Arka kapak',
    custom => 'Özel sayfa',
  };

  /// Pages the user cannot delete (only hide / reorder).
  bool get isStructural => this != custom;

  bool get holdsContent => this != cover && this != backCover;
}

enum BookItemType { media, memory, milestone, letter }

class BookItem {
  const BookItem({
    required this.id,
    required this.pageId,
    required this.type,
    required this.refId,
    required this.sortOrder,
    required this.isHidden,
    this.caption,
  });

  factory BookItem.fromJson(Map<String, dynamic> j) {
    final type = BookItemType.values.byName(j['item_type'] as String);
    return BookItem(
      id: j['id'] as String,
      pageId: j['page_id'] as String,
      type: type,
      refId: (j['${type.name}_id'] as String?)!,
      sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      isHidden: j['is_hidden'] as bool? ?? false,
      caption: j['caption'] as String?,
    );
  }

  final String id;
  final String pageId;
  final BookItemType type;
  final String refId;
  final int sortOrder;
  final bool isHidden;
  final String? caption;

  BookItem copyWith({int? sortOrder, bool? isHidden, String? caption, String? pageId}) => BookItem(
    id: id,
    pageId: pageId ?? this.pageId,
    type: type,
    refId: refId,
    sortOrder: sortOrder ?? this.sortOrder,
    isHidden: isHidden ?? this.isHidden,
    caption: caption ?? this.caption,
  );

  Map<String, dynamic> toRow(String babyId) => {
    'id': id,
    'page_id': pageId,
    'baby_id': babyId,
    'item_type': type.name,
    'media_id': type == BookItemType.media ? refId : null,
    'memory_id': type == BookItemType.memory ? refId : null,
    'milestone_id': type == BookItemType.milestone ? refId : null,
    'letter_id': type == BookItemType.letter ? refId : null,
    'sort_order': sortOrder,
    'is_hidden': isHidden,
    'caption': caption,
  };
}

class BookPage {
  const BookPage({
    required this.id,
    required this.projectId,
    required this.type,
    required this.monthIndex,
    required this.title,
    required this.body,
    required this.sortOrder,
    required this.isHidden,
    required this.items,
  });

  factory BookPage.fromJson(Map<String, dynamic> j) {
    final items =
        ((j['book_items'] as List?) ?? const []).map((e) => BookItem.fromJson(e as Map<String, dynamic>)).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return BookPage(
      id: j['id'] as String,
      projectId: j['project_id'] as String,
      type: BookPageType.fromKey(j['page_type'] as String),
      monthIndex: (j['month_index'] as num?)?.toInt(),
      title: j['title'] as String,
      body: j['body'] as String?,
      sortOrder: (j['sort_order'] as num).toInt(),
      isHidden: j['is_hidden'] as bool? ?? false,
      items: items,
    );
  }

  final String id;
  final String projectId;
  final BookPageType type;
  final int? monthIndex;
  final String title;
  final String? body;
  final int sortOrder;
  final bool isHidden;
  final List<BookItem> items;

  /// Identity of a structural page inside a project ("month:3").
  String get slot => type == BookPageType.month ? 'month:$monthIndex' : type.key;

  List<BookItem> get visibleItems => items.where((i) => !i.isHidden).toList();

  BookPage copyWith({
    String? title,
    String? body,
    int? sortOrder,
    bool? isHidden,
    List<BookItem>? items,
    bool clearBody = false,
  }) => BookPage(
    id: id,
    projectId: projectId,
    type: type,
    monthIndex: monthIndex,
    title: title ?? this.title,
    body: clearBody ? null : (body ?? this.body),
    sortOrder: sortOrder ?? this.sortOrder,
    isHidden: isHidden ?? this.isHidden,
    items: items ?? this.items,
  );

  Map<String, dynamic> toRow(String babyId) => {
    'id': id,
    'project_id': projectId,
    'baby_id': babyId,
    'page_type': type.key,
    'month_index': monthIndex,
    'title': title,
    'body': body,
    'sort_order': sortOrder,
    'is_hidden': isHidden,
  };
}

class BookProject {
  const BookProject({
    required this.id,
    required this.babyId,
    required this.title,
    required this.subtitle,
    required this.format,
    required this.coverMediaId,
    required this.backCoverText,
    required this.currentVersion,
    required this.lastSyncedAt,
    required this.updatedAt,
    required this.pages,
  });

  factory BookProject.fromJson(Map<String, dynamic> j) {
    final pages =
        ((j['book_pages'] as List?) ?? const []).map((e) => BookPage.fromJson(e as Map<String, dynamic>)).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return BookProject(
      id: j['id'] as String,
      babyId: j['baby_id'] as String,
      title: j['title'] as String,
      subtitle: j['subtitle'] as String?,
      format: BookFormat.fromKey(j['format'] as String?),
      coverMediaId: j['cover_media_id'] as String?,
      backCoverText: j['back_cover_text'] as String?,
      currentVersion: (j['current_version'] as num?)?.toInt() ?? 0,
      lastSyncedAt: j['last_synced_at'] == null ? null : DateTime.parse(j['last_synced_at'] as String),
      updatedAt: DateTime.parse(j['updated_at'] as String),
      pages: pages,
    );
  }

  final String id;
  final String babyId;
  final String title;
  final String? subtitle;
  final BookFormat format;
  final String? coverMediaId;
  final String? backCoverText;
  final int currentVersion;
  final DateTime? lastSyncedAt;
  final DateTime updatedAt;
  final List<BookPage> pages;

  bool get hasBeenGenerated => currentVersion > 0;

  Set<String> get allRefIds => {
    for (final p in pages)
      for (final i in p.items) i.refId,
  };
}

/// One official, server-verified PDF version of the book (a ready artifact).
class BookVersion {
  const BookVersion({
    required this.exportId,
    required this.version,
    required this.format,
    required this.pageCount,
    required this.sizeBytes,
    required this.createdAt,
    required this.artifactId,
    required this.sha256,
    required this.downloadBlock,
  });

  factory BookVersion.fromJson(Map<String, dynamic> j) => BookVersion(
    exportId: j['export_id'] as String,
    version: (j['version'] as num).toInt(),
    format: BookFormat.fromKey(j['format'] as String?),
    pageCount: (j['page_count'] as num).toInt(),
    sizeBytes: (j['size_bytes'] as num?)?.toInt(),
    createdAt: DateTime.parse(j['created_at'] as String),
    artifactId: j['artifact_id'] as String,
    sha256: j['sha256'] as String,
    downloadBlock: j['download_block'] as String?,
  );

  final String exportId;
  final int version;
  final BookFormat format;
  final int pageCount;
  final int? sizeBytes;
  final DateTime createdAt;
  final String artifactId;
  final String sha256;

  /// Server reason why the caller cannot download right now (null = allowed).
  final String? downloadBlock;

  bool get canDownload => downloadBlock == null;

  String get sizeLabel {
    final b = sizeBytes;
    if (b == null) return '';
    if (b > 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
    return '${(b / 1024).round()} KB';
  }

  String get fileName => 'ilk-yil-kitabi-v$version.pdf';

  String get createdLabel => Dates.long(createdAt.toLocal());
}

/// Server-side book gate for the signed-in user (`book_access_state`).
class BookAccess {
  const BookAccess({required this.block, required this.rendererEnabled, required this.hasProject});

  factory BookAccess.fromJson(Map<String, dynamic> j) => BookAccess(
    block: j['access_block'] as String?,
    rendererEnabled: j['renderer_enabled'] as bool? ?? false,
    hasProject: j['has_project'] as bool? ?? false,
  );

  /// null = LOCKED + live family subscription + book entitlement + parent.
  final String? block;
  final bool rendererEnabled;
  final bool hasProject;

  bool get canEdit => block == null;

  /// Decision P-12: only Anne / Baba open and download the outputs.
  bool get canView => canEdit;
}

/// A render job leased to this device (`book_render_start`).
class BookRenderLease {
  const BookRenderLease({required this.jobId, required this.status, required this.attempt, required this.reused});

  factory BookRenderLease.fromJson(Map<String, dynamic> j) => BookRenderLease(
    jobId: j['job_id'] as String,
    status: j['job_status'] as String,
    attempt: (j['attempt'] as num).toInt(),
    reused: j['reused'] as bool? ?? false,
  );

  final String jobId;
  final String status;
  final int attempt;
  final bool reused;
}

/// The artifact row created before the upload (`book_artifact_begin`).
class BookArtifactSlot {
  const BookArtifactSlot({required this.artifactId, required this.stagingPath});

  factory BookArtifactSlot.fromJson(Map<String, dynamic> j) =>
      BookArtifactSlot(artifactId: j['artifact_id'] as String, stagingPath: j['staging_path'] as String);

  final String artifactId;
  final String stagingPath;
}
