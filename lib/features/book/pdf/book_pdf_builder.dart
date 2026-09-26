import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
// TrimBox / BleedBox need the low-level array type, which the package does
// not re-export.
// ignore: implementation_imports
import 'package:pdf/src/pdf/format/array.dart' show PdfArray;
import 'package:pdf/widgets.dart' as pw;

import '../domain/book_models.dart';
import '../domain/book_render.dart';

/// Font files (TTF) needed by the builder – passed in so the builder can
/// run on a background isolate and in tests without Flutter bindings.
class BookFonts {
  const BookFonts({
    required this.sansRegular,
    required this.sansBold,
    required this.serifRegular,
    required this.serifSemiBold,
    required this.serifItalic,
  });

  final Uint8List sansRegular;
  final Uint8List sansBold;
  final Uint8List serifRegular;
  final Uint8List serifSemiBold;
  final Uint8List serifItalic;
}

/// Input of a PDF build job (all plain data => isolate friendly).
class BookBuildJob {
  const BookBuildJob({
    required this.data,
    required this.fonts,
    required this.images,
    this.compress = true,
  });

  final BookRenderData data;
  final BookFonts fonts;

  /// mediaId → JPEG bytes (already resized for the chosen quality).
  final Map<String, Uint8List> images;
  final bool compress;
}

class BookBuildResult {
  const BookBuildResult(this.bytes, this.pageCount);

  final Uint8List bytes;
  final int pageCount;
}

/// Lays out the "İlk Yılım" photo book.
///
/// * Page size = trim size + 3 mm bleed on every side, TrimBox/BleedBox set
///   so print shops can cut correctly.
/// * Backgrounds and cover photos run into the bleed; text stays inside a
///   safe margin.
/// * Page numbers on every inner page, covers unnumbered, total page count
///   padded to an even number (printed spreads).
class BookPdfBuilder {
  BookPdfBuilder(this.job)
    : format = job.data.format,
      _sans = pw.Font.ttf(ByteData.sublistView(job.fonts.sansRegular)),
      _sansBold = pw.Font.ttf(ByteData.sublistView(job.fonts.sansBold)),
      _serifBold = pw.Font.ttf(ByteData.sublistView(job.fonts.serifSemiBold)),
      _serifItalic = pw.Font.ttf(ByteData.sublistView(job.fonts.serifItalic));

  final BookBuildJob job;
  final BookFormat format;
  final pw.Font _sans;
  final pw.Font _sansBold;
  final pw.Font _serifBold;
  final pw.Font _serifItalic;
  final _imageCache = <String, pw.ImageProvider>{};

  static final _ink = PdfColor.fromInt(0xFF2F2A26);
  static final _muted = PdfColor.fromInt(0xFF7A6E64);
  static final _accent = PdfColor.fromInt(0xFFC7785B);
  static final _paper = PdfColor.fromInt(0xFFFFFCF8);
  static final _sand = PdfColor.fromInt(0xFFF3E9DC);
  static final _sage = PdfColor.fromInt(0xFF7FA38E);

  double get _bleed => BookFormat.bleedMm * PdfPageFormat.mm;
  double get _margin => format.marginMm * PdfPageFormat.mm;
  double get _pageW => format.widthMm * PdfPageFormat.mm + 2 * _bleed;
  double get _pageH => format.heightMm * PdfPageFormat.mm + 2 * _bleed;
  double get _contentW => _pageW - 2 * (_bleed + _margin);
  double get _contentH => _pageH - 2 * (_bleed + _margin) - _footerH;
  double get _footerH => 18;
  double get _scale => format.widthMm / 210; // typography scales with format

  PdfPageFormat get _pageFormat => PdfPageFormat(_pageW, _pageH);

  pw.ThemeData get _theme => pw.ThemeData.withFont(
    base: _sans,
    bold: _sansBold,
    italic: _serifItalic,
    boldItalic: _serifBold,
  );

  pw.PageTheme _innerTheme({PdfColor? background}) => pw.PageTheme(
    pageFormat: _pageFormat,
    theme: _theme,
    margin: pw.EdgeInsets.all(_bleed + _margin),
    buildBackground: (ctx) => pw.FullPage(
      ignoreMargins: true,
      child: pw.Container(color: background ?? _paper),
    ),
  );

  pw.PageTheme get _fullBleedTheme => pw.PageTheme(
    pageFormat: _pageFormat,
    theme: _theme,
    margin: pw.EdgeInsets.zero,
  );

  pw.TextStyle _t(double size, {pw.Font? font, PdfColor? color, double? spacing, double letter = 0}) =>
      pw.TextStyle(
        font: font ?? _sans,
        fontSize: size * _scale,
        color: color ?? _ink,
        lineSpacing: spacing == null ? null : spacing * _scale,
        letterSpacing: letter,
      );

  pw.ImageProvider? _image(RenderPhoto? p) {
    if (p == null) return null;
    final bytes = job.images[p.mediaId];
    if (bytes == null) return null;
    return _imageCache[p.mediaId] ??= pw.MemoryImage(bytes);
  }

  /// PDF fonts have no colour emoji – strip them so no "tofu" boxes appear.
  static String clean(String s) => s
      .replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{20E3}]', unicode: true), '')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();

  // ---------------------------------------------------------------------------

  Future<BookBuildResult> build() async {
    final d = job.data;
    final doc = pw.Document(
      compress: job.compress,
      version: job.compress ? PdfVersion.pdf_1_5 : PdfVersion.pdf_1_4,
      theme: _theme,
      title: clean(d.title),
      author: clean(d.babyName),
      creator: 'Bebeğimin İlk Yılı',
      subject: 'İlk Yılım fotoğraf kitabı',
    );

    doc.addPage(_cover());
    for (final page in d.pages) {
      switch (page.type) {
        case BookPageType.welcome:
          if (!page.isEmpty) doc.addPage(_contentPages(page, intro: _welcomeIntro(page)));
        case BookPageType.birth:
          doc.addPage(_birthPage(page));
          // Short birth-day memories fit on the birth page itself; only
          // longer content / extra photos continue on following pages.
          final hero = BookRenderResolver.heroOf(page);
          final extraPhotos = page.loosePhotos.where((p) => p.mediaId != hero?.mediaId).length +
              page.memories.expand((m) => m.photos).where((p) => p.mediaId != hero?.mediaId).length;
          if (page.memories.length > 2 || extraPhotos > 0) {
            doc.addPage(_contentPages(
              page,
              intro: [],
              exclude: {?hero?.mediaId},
              continued: true,
              showMemories: page.memories.length > 2,
            ));
          }
        case BookPageType.month:
          doc.addPage(_contentPages(page, intro: _monthIntro(page)));
        case BookPageType.milestones:
          if (page.milestones.isNotEmpty) doc.addPage(_milestonesPages(page));
        case BookPageType.letters:
          if (page.letters.isNotEmpty) doc.addPage(_lettersPages(page));
        case BookPageType.oneYear:
          doc.addPage(_oneYearPage(page));
          final hero = BookRenderResolver.heroOf(page) ?? job.data.cover;
          if (page.memories.isNotEmpty) {
            doc.addPage(_contentPages(page, intro: [], continued: true, exclude: {?hero?.mediaId}));
          }
        case BookPageType.custom:
          doc.addPage(_contentPages(page, intro: _sectionTitle(page.title, subtitle: page.subtitle, note: page.note)));
        case BookPageType.cover:
        case BookPageType.backCover:
          break;
      }
    }

    // Print books are bound in spreads: keep an even page count.
    if ((doc.document.pdfPageList.pages.length + 1).isOdd) {
      doc.addPage(_notesPage());
    }
    doc.addPage(_backCover());

    final pages = doc.document.pdfPageList.pages;
    for (final p in pages) {
      p.params['/TrimBox'] = PdfArray.fromNum([_bleed, _bleed, _pageW - _bleed, _pageH - _bleed]);
      p.params['/BleedBox'] = PdfArray.fromNum([0, 0, _pageW, _pageH]);
    }
    final bytes = await doc.save();
    return BookBuildResult(bytes, pages.length);
  }

  // Footer with page number (cover is page 1 and not numbered).
  pw.Widget _footer(pw.Context ctx) => pw.Container(
    height: _footerH,
    alignment: pw.Alignment.bottomCenter,
    child: pw.Text('${ctx.pageNumber - 1}', style: _t(8.5, color: _muted)),
  );

  // Cover ---------------------------------------------------------------------
  pw.Page _cover() {
    final d = job.data;
    final img = _image(d.cover);
    return pw.Page(
      pageTheme: _fullBleedTheme,
      build: (ctx) => pw.Stack(
        fit: pw.StackFit.expand,
        children: [
          if (img != null)
            pw.Image(img, fit: pw.BoxFit.cover)
          else
            pw.Container(color: _sand),
          if (img == null)
            pw.Positioned(
              right: -_pageW * 0.15,
              top: -_pageW * 0.1,
              child: pw.Container(
                width: _pageW * 0.7,
                height: _pageW * 0.7,
                decoration: pw.BoxDecoration(shape: pw.BoxShape.circle, color: PdfColor.fromInt(0x33C7785B)),
              ),
            ),
          // Title panel: an opaque cream band keeps the text readable on any
          // photo (PDF gradients cannot fade to transparent reliably).
          pw.Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: pw.Container(
              height: _pageH * (img == null ? 0.42 : 0.3),
              color: img == null ? null : _paper,
              padding: pw.EdgeInsets.fromLTRB(_bleed + _margin, _margin * 0.9, _bleed + _margin, _bleed + _margin),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Text(clean(d.title), style: _t(28, font: _serifBold), maxLines: 2),
                  pw.SizedBox(height: 6 * _scale),
                  pw.Text(
                    clean(d.subtitle?.isNotEmpty ?? false ? d.subtitle! : d.babyName),
                    style: _t(13, font: _serifItalic, color: _muted),
                  ),
                  pw.SizedBox(height: 10 * _scale),
                  pw.Row(children: [
                    pw.Container(width: 36 * _scale, height: 2, color: _accent),
                    pw.SizedBox(width: 10 * _scale),
                    pw.Text(d.yearsLabel, style: _t(9.5, color: _muted, letter: 2)),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Back cover ------------------------------------------------------------------
  pw.Page _backCover() => pw.Page(
    pageTheme: _fullBleedTheme,
    build: (ctx) => pw.Container(
      color: _sand,
      padding: pw.EdgeInsets.all(_bleed + _margin * 2),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          pw.Container(width: 30 * _scale, height: 2, color: _accent),
          pw.SizedBox(height: 18 * _scale),
          pw.Text(
            clean(job.data.backCoverText),
            textAlign: pw.TextAlign.center,
            style: _t(13, font: _serifItalic, spacing: 5),
          ),
          pw.SizedBox(height: 18 * _scale),
          pw.Container(width: 30 * _scale, height: 2, color: _accent),
          pw.Spacer(),
          pw.Text('Bebeğimin İlk Yılı', style: _t(8.5, color: _muted, letter: 1.5)),
        ],
      ),
    ),
  );

  pw.Page _notesPage() => pw.Page(
    pageTheme: _innerTheme(),
    build: (ctx) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Notlar', style: _t(22, font: _serifBold)),
        pw.SizedBox(height: 16 * _scale),
        for (var i = 0; i < 12; i++)
          pw.Container(
            height: 26 * _scale,
            decoration: pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: _sand, width: 0.8)),
            ),
          ),
        pw.Spacer(),
        _footer(ctx),
      ],
    ),
  );

  // Section headers -----------------------------------------------------------------
  List<pw.Widget> _sectionTitle(String title, {String? subtitle, String? summary, String? note, String? kicker}) => [
    if (kicker != null) pw.Text(kicker, style: _t(9, font: _sansBold, color: _accent, letter: 2)),
    if (kicker != null) pw.SizedBox(height: 4 * _scale),
    pw.Text(clean(title), style: _t(26, font: _serifBold)),
    if (subtitle != null) ...[
      pw.SizedBox(height: 4 * _scale),
      pw.Text(subtitle, style: _t(10, color: _muted)),
    ],
    pw.SizedBox(height: 10 * _scale),
    pw.Container(width: 36 * _scale, height: 2, color: _accent),
    if (summary != null) ...[
      pw.SizedBox(height: 10 * _scale),
      pw.Text(summary, style: _t(11, font: _serifItalic, color: _muted)),
    ],
    if (note?.trim().isNotEmpty ?? false) ...[
      pw.SizedBox(height: 10 * _scale),
      pw.Text(clean(note!), style: _t(11, spacing: 3)),
    ],
    pw.SizedBox(height: 18 * _scale),
  ];

  List<pw.Widget> _monthIntro(RenderPage p) => _sectionTitle(
    p.title,
    kicker: '${p.monthIndex}. AY',
    subtitle: p.subtitle,
    summary: p.summary,
    note: p.note,
  );

  List<pw.Widget> _welcomeIntro(RenderPage p) => _sectionTitle(
    p.title,
    kicker: 'HOŞ GELDİN',
    note: p.note,
  );

  // Generic flowing content (memories + photo grid) ------------------------------------
  pw.MultiPage _contentPages(
    RenderPage page, {
    required List<pw.Widget> intro,
    Set<String> exclude = const {},
    bool continued = false,
    bool showMemories = true,
  }) {
    final loose = [
      ...page.loosePhotos,
      // memories rendered elsewhere still contribute their photos
      if (!showMemories) ...page.memories.expand((m) => m.photos),
    ].where((p) => !exclude.contains(p.mediaId)).toList();
    List<RenderPhoto> own(RenderMemory m) => m.photos.where((p) => !exclude.contains(p.mediaId)).toList();
    return pw.MultiPage(
      pageTheme: _innerTheme(),
      maxPages: 200,
      footer: _footer,
      build: (ctx) => [
        ...intro,
        if (continued) ...[
          pw.Text(clean(page.title), style: _t(14, font: _serifBold, color: _muted)),
          pw.SizedBox(height: 12 * _scale),
        ],
        if (showMemories)
          for (final m in page.memories) ..._memoryBlock(m, own(m)),
        if (loose.isNotEmpty) ..._photoGrid(loose),
        if ((page.memories.isEmpty || !showMemories) && loose.isEmpty && intro.isNotEmpty)
          pw.Padding(
            padding: pw.EdgeInsets.only(top: 20 * _scale),
            child: pw.Text('Bu sayfaya henüz içerik eklenmedi.', style: _t(10, color: _muted, font: _serifItalic)),
          ),
      ],
    );
  }

  List<pw.Widget> _memoryBlock(RenderMemory m, List<RenderPhoto> photos) => [
    pw.Text(clean(m.title), style: _t(15, font: _serifBold)),
    pw.SizedBox(height: 3 * _scale),
    pw.Text(
      [m.dateLabel, if (m.author != null) m.author!].join('  ·  '),
      style: _t(8.5, color: _muted),
    ),
    if (m.body?.trim().isNotEmpty ?? false) ...[
      pw.SizedBox(height: 6 * _scale),
      pw.Paragraph(text: clean(m.body!), style: _t(10.5, spacing: 3)),
    ],
    if (photos.isNotEmpty) ...[
      pw.SizedBox(height: 8 * _scale),
      _photoRow(photos.take(3).toList()),
      if (photos.length > 3) ...[
        pw.SizedBox(height: 6 * _scale),
        ..._photoGrid(photos.skip(3).toList(), captions: false),
      ],
    ],
    pw.SizedBox(height: 20 * _scale),
  ];

  pw.Widget _photoBox(RenderPhoto p, double w, double h, {bool rounded = true}) {
    final img = _image(p);
    return pw.ClipRRect(
      horizontalRadius: rounded ? 6 * _scale : 0,
      verticalRadius: rounded ? 6 * _scale : 0,
      child: pw.Container(
        width: w,
        height: h,
        color: _sand,
        child: img == null ? pw.SizedBox() : pw.Image(img, fit: pw.BoxFit.cover, width: w, height: h),
      ),
    );
  }

  pw.Widget _photoRow(List<RenderPhoto> photos) {
    const gap = 6.0;
    if (photos.length == 1) {
      final p = photos.first;
      final h = math.min(_contentW / p.aspect.clamp(0.5, 2.5), _contentH * 0.55);
      final w = math.min(_contentW, h * p.aspect.clamp(0.5, 2.5));
      return pw.Center(child: _photoBox(p, w, h));
    }
    final w = (_contentW - gap * (photos.length - 1)) / photos.length;
    final h = math.min(w * (photos.length == 2 ? 1.1 : 1.0), _contentH * 0.4);
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [for (final p in photos) _photoBox(p, w, h)],
    );
  }

  List<pw.Widget> _photoGrid(List<RenderPhoto> photos, {bool captions = true}) {
    const gap = 8.0;
    final cols = photos.length == 1 ? 1 : 2;
    final w = (_contentW - gap * (cols - 1)) / cols;
    final cellAspect = format.isSquare ? 1.0 : 0.8; // w/h
    final h = cols == 1
        ? math.min(_contentW / photos.first.aspect.clamp(0.6, 2.0), _contentH * 0.7)
        : w / cellAspect;
    final rows = <pw.Widget>[];
    for (var i = 0; i < photos.length; i += cols) {
      final chunk = photos.sublist(i, math.min(i + cols, photos.length));
      rows.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(bottom: gap),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (var k = 0; k < chunk.length; k++) ...[
                if (k > 0) pw.SizedBox(width: gap),
                pw.SizedBox(
                  width: w,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      _photoBox(chunk[k], w, math.min(h, _contentH - 30)),
                      if (captions && (chunk[k].caption?.trim().isNotEmpty ?? false)) ...[
                        pw.SizedBox(height: 3),
                        pw.Text(clean(chunk[k].caption!), style: _t(8, color: _muted, font: _serifItalic), maxLines: 2),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return rows;
  }

  // Birth page -------------------------------------------------------------------------
  pw.Page _birthPage(RenderPage page) {
    final b = job.data.birth;
    final hero = BookRenderResolver.heroOf(page);
    final rows = <(String, String)>[
      ('Doğum tarihi', b.dateLabel),
      if (b.time != null) ('Saat', b.time!),
      if (b.place?.isNotEmpty ?? false) ('Doğum yeri', b.place!),
      if (b.weight != null) ('Kilo', b.weight!),
      if (b.length != null) ('Boy', b.length!),
    ];
    return pw.Page(
      pageTheme: _innerTheme(),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          ..._sectionTitle(page.title, kicker: 'MERHABA DÜNYA'),
          if (hero != null) ...[
            pw.Center(child: _photoBox(hero, _contentW, math.min(_contentW / hero.aspect.clamp(0.6, 2.0), _contentH * 0.42))),
            pw.SizedBox(height: 14 * _scale),
          ],
          pw.Container(
            padding: pw.EdgeInsets.all(12 * _scale),
            decoration: pw.BoxDecoration(color: _sand, borderRadius: pw.BorderRadius.circular(8 * _scale)),
            child: pw.Column(
              children: [
                for (final r in rows)
                  pw.Padding(
                    padding: pw.EdgeInsets.symmetric(vertical: 3 * _scale),
                    child: pw.Row(
                      children: [
                        pw.SizedBox(width: 90 * _scale, child: pw.Text(r.$1, style: _t(9.5, color: _muted))),
                        pw.Expanded(child: pw.Text(clean(r.$2), style: _t(10.5, font: _sansBold))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (b.story?.trim().isNotEmpty ?? false) ...[
            pw.SizedBox(height: 14 * _scale),
            pw.Text(clean(b.story!), style: _t(11, font: _serifItalic, spacing: 3), maxLines: 6),
          ],
          if (page.memories.length <= 2)
            for (final m in page.memories) ...[
              pw.SizedBox(height: 12 * _scale),
              pw.Text(clean(m.title), style: _t(12.5, font: _serifBold)),
              if (m.body?.trim().isNotEmpty ?? false)
                pw.Text(clean(m.body!), style: _t(10, spacing: 2.5), maxLines: 4),
            ],
          pw.Spacer(),
          _footer(ctx),
        ],
      ),
    );
  }

  // Milestones -------------------------------------------------------------------------
  pw.MultiPage _milestonesPages(RenderPage page) => pw.MultiPage(
    pageTheme: _innerTheme(),
    maxPages: 100,
    footer: _footer,
    build: (ctx) => [
      ..._sectionTitle(page.title, kicker: 'İLKLERİM', note: page.note),
      for (var i = 0; i < page.milestones.length; i++) _milestoneBlock(i + 1, page.milestones[i]),
      if (page.loosePhotos.isNotEmpty) ..._photoGrid(page.loosePhotos),
    ],
  );

  pw.Widget _milestoneBlock(int n, RenderMilestone m) {
    final badge = 26 * _scale;
    return pw.Padding(
      padding: pw.EdgeInsets.only(bottom: 16 * _scale),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                width: badge,
                height: badge,
                alignment: pw.Alignment.center,
                decoration: pw.BoxDecoration(shape: pw.BoxShape.circle, color: _sage),
                child: pw.Text('$n', style: _t(10, font: _sansBold, color: PdfColors.white)),
              ),
              pw.SizedBox(width: 10 * _scale),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(clean(m.title), style: _t(14, font: _serifBold)),
                    pw.SizedBox(height: 2),
                    pw.Text(m.dateLabel, style: _t(8.5, color: _muted)),
                    if (m.description?.trim().isNotEmpty ?? false) ...[
                      pw.SizedBox(height: 4 * _scale),
                      pw.Text(clean(m.description!), style: _t(10.5, spacing: 3)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (m.photos.isNotEmpty) ...[
            pw.SizedBox(height: 8 * _scale),
            _photoRow(m.photos.take(3).toList()),
          ],
        ],
      ),
    );
  }

  // Letters ------------------------------------------------------------------------------
  pw.MultiPage _lettersPages(RenderPage page) => pw.MultiPage(
    pageTheme: _innerTheme(background: PdfColor.fromInt(0xFFFBF6EF)),
    maxPages: 100,
    footer: _footer,
    build: (ctx) => [
      ..._sectionTitle(page.title, kicker: 'AİLEMDEN BANA', note: page.note),
      for (final l in page.letters) ...[
        if (l.title?.trim().isNotEmpty ?? false) ...[
          pw.Text(clean(l.title!), style: _t(15, font: _serifBold)),
          pw.SizedBox(height: 6 * _scale),
        ],
        pw.Paragraph(text: clean(l.body), style: _t(11.5, font: _serifItalic, spacing: 4)),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('— ${clean(l.signature)}, ${l.dateLabel}', style: _t(9.5, color: _muted)),
        ),
        if (l.photos.isNotEmpty) ...[pw.SizedBox(height: 8 * _scale), _photoRow(l.photos.take(2).toList())],
        pw.SizedBox(height: 14 * _scale),
        pw.Center(child: pw.Container(width: 24 * _scale, height: 1, color: _accent)),
        pw.SizedBox(height: 18 * _scale),
      ],
      if (page.loosePhotos.isNotEmpty) ..._photoGrid(page.loosePhotos),
    ],
  );

  // One year -------------------------------------------------------------------------------
  pw.Page _oneYearPage(RenderPage page) {
    final s = job.data.stats;
    final hero = BookRenderResolver.heroOf(page) ?? job.data.cover;
    final img = _image(hero);
    pw.Widget stat(String value, String label) => pw.Expanded(
      child: pw.Column(
        children: [
          pw.Text(value, style: _t(20, font: _serifBold, color: _accent)),
          pw.Text(label, style: _t(8.5, color: _muted)),
        ],
      ),
    );
    return pw.Page(
      pageTheme: _innerTheme(),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.SizedBox(height: 6 * _scale),
          pw.Text('BİR YAŞINDAYIM', style: _t(9, font: _sansBold, color: _accent, letter: 2)),
          pw.SizedBox(height: 6 * _scale),
          pw.Text(clean(page.title), style: _t(28, font: _serifBold)),
          pw.SizedBox(height: 14 * _scale),
          if (img != null && hero != null)
            _photoBox(hero, _contentW * 0.8, math.min(_contentW * 0.8 / hero.aspect.clamp(0.6, 1.8), _contentH * 0.5)),
          pw.SizedBox(height: 18 * _scale),
          pw.Row(children: [
            stat('365', 'gün'),
            stat('${s.memories}', 'anı'),
            stat('${s.photos}', 'fotoğraf'),
            stat('${s.milestones}', 'ilk'),
          ]),
          if (page.note?.trim().isNotEmpty ?? false) ...[
            pw.SizedBox(height: 16 * _scale),
            pw.Text(clean(page.note!), textAlign: pw.TextAlign.center, style: _t(11.5, font: _serifItalic, spacing: 4)),
          ],
          pw.Spacer(),
          _footer(ctx),
        ],
      ),
    );
  }
}

/// Top-level entry point for `Isolate.run`.
Future<BookBuildResult> buildBookPdf(BookBuildJob job) => BookPdfBuilder(job).build();
