import 'dart:io';

import 'package:bebegimin_ilk_yili/features/book/domain/book_composer.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_models.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_render.dart';
import 'package:bebegimin_ilk_yili/features/book/pdf/book_pdf_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';
import 'book_composer_test.dart' show projectFromPlan;

BookFonts loadFonts() {
  List<int> f(String name) => File('assets/fonts/$name').readAsBytesSync();
  return BookFonts(
    sansRegular: f('Nunito-Regular.ttf') as dynamic,
    sansBold: f('Nunito-Bold.ttf') as dynamic,
    serifRegular: f('Lora-Regular.ttf') as dynamic,
    serifSemiBold: f('Lora-SemiBold.ttf') as dynamic,
    serifItalic: f('Lora-Italic.ttf') as dynamic,
  );
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  BookRenderData render(BookFormat format) {
    final src = demoSource();
    final plan = const BookComposer().plan(src);
    final project = projectFromPlan(plan);
    return const BookRenderResolver().resolve(
      project: BookProject(
        id: project.id,
        babyId: project.babyId,
        title: 'Defne’nin İlk Yılı — ğüşıöç İĞÜŞÖÇ',
        subtitle: 'Sevgiyle 🤍',
        format: format,
        coverMediaId: project.coverMediaId,
        backCoverText: null,
        currentVersion: 0,
        lastSyncedAt: null,
        updatedAt: project.updatedAt,
        pages: project.pages,
      ),
      source: src,
      members: const [],
    );
  }

  test('resolver builds chapters, stats and photo list', () {
    final data = render(BookFormat.square21);
    expect(data.pages.first.type, BookPageType.welcome);
    expect(data.pages.where((p) => p.type == BookPageType.month).length, 12);
    expect(data.stats.milestones, 2);
    expect(data.stats.letters, 1);
    expect(data.cover?.mediaId, 'p-birthday');
    final month1 = data.pages.firstWhere((p) => p.monthIndex == 1);
    expect(month1.summary, contains('fotoğraf'));
    // a memory's own photo is rendered with it, the other one in the grid
    expect(month1.memories.single.photos.map((p) => p.mediaId), ['p-m1-a']);
    expect(month1.loosePhotos.map((p) => p.mediaId), ['p-m1-b']);
    expect(data.backCoverText, contains("Defne'nin"));
  });

  for (final format in BookFormat.values) {
    test('renders a print-ready ${format.key} PDF with an even page count', () async {
      final data = render(format);
      final jpegP = File('test/fixtures/portrait.jpg').readAsBytesSync();
      final jpegL = File('test/fixtures/landscape.jpg').readAsBytesSync();
      final images = {for (final p in data.allPhotos) p.mediaId: p.aspect > 1 ? jpegL : jpegP};
      final result = await buildBookPdf(BookBuildJob(data: data, fonts: loadFonts(), images: images, compress: false));
      final text = String.fromCharCodes(result.bytes);
      expect(text.startsWith('%PDF-'), isTrue);
      expect(result.pageCount.isEven, isTrue);
      expect(result.pageCount, greaterThanOrEqualTo(18)); // cover + chapters + back
      final pageObjects = RegExp(r'/Type\s*/Page\b').allMatches(text).length;
      expect(pageObjects, result.pageCount);
      expect(text, contains('/TrimBox'));
      expect(text, contains('/BleedBox'));
      // Embedded TrueType fonts (Turkish glyphs come from them)
      expect(text, contains('/FontFile2'));
    });
  }

  test('works without any images (placeholders) and strips emoji', () async {
    final data = render(BookFormat.a4Portrait);
    final result = await buildBookPdf(BookBuildJob(data: data, fonts: loadFonts(), images: const {}));
    expect(result.pageCount, greaterThan(10));
    expect(BookPdfBuilder.clean('Doğum günü 🎂 partisi ❤️'), 'Doğum günü partisi');
  });
}
