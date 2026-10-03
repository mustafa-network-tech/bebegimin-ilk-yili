// Manual helper: `SAMPLE_DIR=... flutter test test/book/render_sample.dart`
// writes sample PDFs for visual inspection. Skipped without SAMPLE_DIR.
import 'dart:io';

import 'package:bebegimin_ilk_yili/features/book/domain/book_composer.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_models.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_render.dart';
import 'package:bebegimin_ilk_yili/features/book/pdf/book_pdf_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';
import 'book_composer_test.dart' show projectFromPlan;
import 'book_pdf_test.dart' show loadFonts;

void main() {
  final dir = Platform.environment['SAMPLE_DIR'];
  test('render sample', () async {
    await initializeDateFormatting('tr_TR');
    final src = demoSource();
    final p = projectFromPlan(const BookComposer().plan(src));
    for (final format in BookFormat.values) {
      final data = const BookRenderResolver().resolve(
        project: BookProject(
          id: p.id,
          babyId: p.babyId,
          title: 'Defne\'nin İlk Yılı',
          subtitle: 'Defne Yılmaz',
          format: format,
          coverMediaId: p.coverMediaId,
          backCoverText: null,
          currentVersion: 0,
          lastSyncedAt: null,
          updatedAt: p.updatedAt,
          pages: p.pages,
        ),
        source: src,
        members: const [],
      );
      var i = 0;
      final images = {for (final ph in data.allPhotos) ph.mediaId: File('$dir/img${i++ % 6}.jpg').readAsBytesSync()};
      final r = await buildBookPdf(BookBuildJob(data: data, fonts: loadFonts(), images: images));
      File('$dir/sample-${format.key}.pdf').writeAsBytesSync(r.bytes);
    }
  }, skip: dir == null ? 'set SAMPLE_DIR to render samples' : false);
}
