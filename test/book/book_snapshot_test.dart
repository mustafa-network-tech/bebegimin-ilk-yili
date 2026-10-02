import 'dart:convert';
import 'dart:io';

import 'package:bebegimin_ilk_yili/core/utils/dates.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_composer.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_models.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_render.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_snapshot.dart';
import 'package:bebegimin_ilk_yili/features/book/pdf/book_pdf_builder.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/family_member.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/relation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../support/fixtures.dart';
import 'book_composer_test.dart' show projectFromPlan;
import 'book_pdf_test.dart' show loadFonts;

const people = {'user-anne': (name: 'Ayşe', relation: 'anne'), 'user-teyze': (name: 'Zeynep', relation: 'teyze')};

List<FamilyMember> liveMembers() => [
  for (final e in people.entries)
    FamilyMember(
      id: 'fm-${e.key}',
      babyId: defne.id,
      userId: e.key,
      relation: Relation.fromKey(e.value.relation),
      relationLabel: null,
      isAdmin: false,
      permissions: const {},
      joinedAt: DateTime.utc(2025),
      displayName: e.value.name,
      avatarPath: null,
    ),
];

/// The canonical archive JSON as build_archive_snapshot_content() seals it.
Map<String, dynamic> snapshotFor(BookSource s) {
  Map<String, dynamic>? person(String? id) => id == null
      ? null
      : {'user_id': id, 'name': people[id]?.name ?? '', 'relation': people[id]?.relation, 'relation_label': null};
  return {
    'schema_version': 1,
    'baby': s.baby.toJson()..remove('created_at'),
    'lifecycle': {'extension_days': 0},
    'members': [
      for (final e in people.entries)
        {'user_id': e.key, 'name': e.value.name, 'relation': e.value.relation, 'relation_label': null},
    ],
    'milestones': [
      for (final m in s.milestones)
        {
          'id': m.id,
          'type_key': s.milestoneTypes[m.typeId]?.key,
          'title': s.milestoneTypes[m.typeId]?.title,
          'emoji': s.milestoneTypes[m.typeId]?.emoji,
          'achieved_on': Dates.toSql(m.achievedOn),
          'achieved_time': m.achievedTime,
          'description': m.description,
          'include_in_book': m.includeInBook,
          'author': person(m.createdBy),
        },
    ],
    'memories': [
      for (final m in s.memories)
        {
          'id': m.id,
          'title': m.title,
          'body': m.body,
          'memory_date': Dates.toSql(m.date),
          'memory_time': m.time,
          'category': m.category.key,
          'milestone_id': m.milestoneId,
          'include_in_book': m.includeInBook,
          'author': person(m.authorId),
        },
    ],
    'letters': [
      for (final l in s.letters)
        {
          'id': l.id,
          'title': l.title,
          'body': l.body,
          'written_on': Dates.toSql(l.writtenOn),
          'include_in_book': l.includeInBook,
          'author': {...?person(l.authorId), 'name': l.authorName, 'relation': l.authorRelation.key},
        },
    ],
    // Only ready media is sealed.
    'media': [
      for (final m in s.media.where((m) => m.status == 'ready'))
        {
          'id': m.id,
          'kind': m.kind.name,
          'storage_path': m.storagePath,
          'thumb_path': m.thumbPath,
          'mime_type': m.mimeType,
          'width': m.width,
          'height': m.height,
          'duration_ms': m.durationMs,
          'size_bytes': null,
          'caption': m.caption,
          'taken_on': Dates.toSql(m.takenOn),
          'tags': m.tags,
          'include_in_book': m.includeInBook,
          'sort_order': 0,
          'memory_id': m.memoryId,
          'milestone_id': m.milestoneId,
          'letter_id': m.letterId,
          'uploader': person(m.uploaderId),
        },
    ],
    'comments': <Object>[],
  };
}

/// The frozen configuration as build_book_manifest() seals it.
Map<String, dynamic> manifestFor(BookProject p) => {
  'manifest_version': 1,
  'id': p.id,
  'baby_id': p.babyId,
  'kind': 'first_year',
  'title': p.title,
  'subtitle': p.subtitle,
  'format': p.format.key,
  'theme': 'classic',
  'cover_media_id': p.coverMediaId,
  'back_cover_text': p.backCoverText,
  'current_version': p.currentVersion,
  'last_synced_at': null,
  'updated_at': p.updatedAt.toUtc().toIso8601String(),
  'book_pages': [
    for (final page in p.pages)
      {
        ...page.toRow(p.babyId),
        'book_items': [for (final i in page.items) i.toRow(p.babyId)],
      },
  ],
};

BookRenderPayload payloadFor(Map<String, dynamic> snapshot, Map<String, dynamic> manifest) {
  final s = jsonEncode(snapshot);
  final m = jsonEncode(manifest);
  return BookRenderPayload(
    snapshotContent: s,
    snapshotChecksum: sha256Hex(s),
    manifestContent: m,
    manifestChecksum: sha256Hex(m),
  );
}

/// Comparable outline of a rendered book.
List<String> outline(BookRenderData d) => [
  'title:${d.title}|cover:${d.cover?.mediaId}|back:${d.backCoverText}|years:${d.yearsLabel}',
  'birth:${d.birth.dateLabel}|${d.birth.time}|${d.birth.place}|${d.birth.weight}|${d.birth.length}|${d.birth.story}',
  'stats:${d.stats.memories}/${d.stats.photos}/${d.stats.milestones}/${d.stats.letters}',
  for (final p in d.pages) ...[
    'page:${p.type.key}:${p.monthIndex}:${p.title}:${p.subtitle}:${p.summary}:${p.note}',
    for (final m in p.memories) '  memory:${m.title}:${m.dateLabel}:${m.author}:${m.photos.map((x) => x.mediaId)}',
    for (final m in p.milestones) '  milestone:${m.title}:${m.dateLabel}:${m.photos.map((x) => x.mediaId)}',
    for (final l in p.letters) '  letter:${l.signature}:${l.dateLabel}:${l.photos.map((x) => x.mediaId)}',
    for (final x in p.loosePhotos) '  photo:${x.mediaId}:${x.caption}:${x.path}',
  ],
];

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  final source = demoSource();
  final project = projectFromPlan(const BookComposer().plan(source));

  test('snapshot + manifest render exactly like the live archive (no regression)', () {
    final inputs = BookRenderInputs.fromPayload(payloadFor(snapshotFor(source), manifestFor(project)));
    const resolver = BookRenderResolver();
    final live = resolver.resolve(project: project, source: source, members: liveMembers());
    final sealed = resolver.resolve(project: inputs.project, source: inputs.source, members: inputs.members);
    expect(outline(sealed), outline(live));
    // Chapter distribution and "Bir Yaşındayım".
    expect(sealed.pages.where((p) => p.type == BookPageType.month).length, 12);
    final oneYear = sealed.pages.singleWhere((p) => p.type == BookPageType.oneYear);
    expect(oneYear.title, 'Bir Yaşındayım');
    expect(oneYear.memories.map((m) => m.title), contains('Doğum günü partisi'));
    expect(sealed.pages.first.type, BookPageType.welcome);
    expect(sealed.pages.last.type, BookPageType.oneYear);
  });

  test('the book uses the close date the server sealed the snapshot at (decision P-1)', () {
    final content = snapshotFor(source)..['lifecycle'] = {'extension_days': 30, 'effective_close_date': '2026-10-22'};
    final inputs = BookRenderInputs.fromPayload(payloadFor(content, manifestFor(project)));
    expect(inputs.source.closeDate, DateTime(2026, 10, 22));
  });

  test('author names and relations come from the snapshot, not live profiles', () {
    final inputs = BookRenderInputs.fromPayload(payloadFor(snapshotFor(source), manifestFor(project)));
    final data = const BookRenderResolver().resolve(
      project: inputs.project,
      source: inputs.source,
      members: inputs.members,
    );
    final memories = data.pages.expand((p) => p.memories).toList();
    expect(memories.first.author, 'Annesi Ayşe');
    final letter = data.pages.expand((p) => p.letters).single;
    expect(letter.signature, 'Teyzesi Zeynep');
    expect(data.pages.expand((p) => p.milestones).map((m) => m.title), containsAll(['İlk adımım', 'İlk dişim']));
  });

  test('editor configuration is honoured: order, hidden pages/items, custom page, captions, cover, format', () {
    final pages = [...project.pages];
    final milestones = pages.indexWhere((p) => p.type == BookPageType.milestones);
    pages[milestones] = pages[milestones].copyWith(isHidden: true);
    final month1 = pages.indexWhere((p) => p.monthIndex == 1);
    pages[month1] = pages[month1].copyWith(
      items: [
        for (final i in pages[month1].items)
          i.refId == 'p-m1-b'
              ? i.copyWith(caption: 'Uykucu')
              : (i.refId == 'm-month1' ? i.copyWith(isHidden: true) : i),
      ],
    );
    final custom = BookPage(
      id: 'page-custom',
      projectId: project.id,
      type: BookPageType.custom,
      monthIndex: null,
      title: 'Dedemin bahçesi',
      body: 'Her pazar oradaydık.',
      sortOrder: 4,
      isHidden: false,
      items: const [],
    );
    pages.insert(4, custom);
    final edited = BookProject(
      id: project.id,
      babyId: project.babyId,
      title: 'Defne’nin İlk Yılı',
      subtitle: 'Sevgiyle',
      format: BookFormat.a4Portrait,
      coverMediaId: 'p-m1-b',
      backCoverText: 'Arka kapak notu',
      currentVersion: 2,
      lastSyncedAt: null,
      updatedAt: project.updatedAt,
      pages: [for (var i = 0; i < pages.length; i++) pages[i].copyWith(sortOrder: i)],
    );
    final inputs = BookRenderInputs.fromPayload(payloadFor(snapshotFor(source), manifestFor(edited)));
    expect(inputs.project.format, BookFormat.a4Portrait);
    final data = const BookRenderResolver().resolve(
      project: inputs.project,
      source: inputs.source,
      members: inputs.members,
    );
    expect(data.title, 'Defne’nin İlk Yılı');
    expect(data.cover?.mediaId, 'p-m1-b');
    expect(data.backCoverText, 'Arka kapak notu');
    expect(data.pages.any((p) => p.type == BookPageType.milestones), isFalse);
    final customPage = data.pages.singleWhere((p) => p.type == BookPageType.custom);
    expect(customPage.note, 'Her pazar oradaydık.');
    expect(data.pages.indexOf(customPage), lessThan(data.pages.indexWhere((p) => p.monthIndex == 3)));
    final m1 = data.pages.singleWhere((p) => p.monthIndex == 1);
    expect(m1.memories, isEmpty);
    expect(m1.loosePhotos.singleWhere((x) => x.mediaId == 'p-m1-b').caption, 'Uykucu');
  });

  test('a tampered or foreign payload is refused before decoding', () {
    final ok = payloadFor(snapshotFor(source), manifestFor(project));
    expect(
      () => BookRenderInputs.fromPayload(
        BookRenderPayload(
          snapshotContent: ok.snapshotContent.replaceFirst('Defne', 'Deniz'),
          snapshotChecksum: ok.snapshotChecksum,
          manifestContent: ok.manifestContent,
          manifestChecksum: ok.manifestChecksum,
        ),
      ),
      throwsA(isA<BookIntegrityException>().having((e) => e.part, 'part', 'snapshot')),
    );
    expect(
      () => BookRenderInputs.fromPayload(
        BookRenderPayload(
          snapshotContent: ok.snapshotContent,
          snapshotChecksum: ok.snapshotChecksum,
          manifestContent: ok.manifestContent.replaceFirst('first_year', 'other'),
          manifestChecksum: ok.manifestChecksum,
        ),
      ),
      throwsA(isA<BookIntegrityException>().having((e) => e.part, 'part', 'manifest')),
    );
    final v2 = snapshotFor(source)..['schema_version'] = 2;
    expect(
      () => BookRenderInputs.fromPayload(payloadFor(v2, manifestFor(project))),
      throwsA(isA<BookIntegrityException>()),
    );
    final otherBaby = manifestFor(project)..['baby_id'] = 'baby-other';
    expect(
      () => BookRenderInputs.fromPayload(payloadFor(snapshotFor(source), otherBaby)),
      throwsA(isA<BookIntegrityException>().having((e) => e.part, 'part', 'baby')),
    );
  });

  for (final format in BookFormat.values) {
    test('official ${format.key} PDF from the snapshot is print-ready and passes the server PDF check', () async {
      final manifest = manifestFor(project)..['format'] = format.key;
      final inputs = BookRenderInputs.fromPayload(payloadFor(snapshotFor(source), manifest));
      final data = const BookRenderResolver().resolve(
        project: inputs.project,
        source: inputs.source,
        members: inputs.members,
      );
      final jpegP = File('test/fixtures/portrait.jpg').readAsBytesSync();
      final jpegL = File('test/fixtures/landscape.jpg').readAsBytesSync();
      final images = {for (final p in data.allPhotos) p.mediaId: p.aspect > 1 ? jpegL : jpegP};
      final result = await buildBookPdf(BookBuildJob(data: data, fonts: loadFonts(), images: images));
      final bytes = result.bytes;
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      // book-artifact-finalize requires %%EOF in the last kilobyte.
      expect(String.fromCharCodes(bytes.skip(bytes.length - 1024)), contains('%%EOF'));
      expect(result.pageCount.isEven, isTrue);
      final text = latin1.decode(bytes, allowInvalid: true);
      expect(text, contains('/TrimBox'));
      expect(text, contains('/BleedBox'));
    });
  }
}
