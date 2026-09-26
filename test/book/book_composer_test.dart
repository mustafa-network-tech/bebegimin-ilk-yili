import 'package:bebegimin_ilk_yili/core/utils/dates.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_composer.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  const composer = BookComposer();

  Set<String> refs(BookPlan plan, String slot, {bool visibleOnly = false}) =>
      plan.page(slot).items.where((i) => !visibleOnly || !i.hidden).map((i) => i.refId).toSet();

  test('default structure: cover, welcome, birth, 12 months, firsts, letters, one year, back cover', () {
    final plan = composer.plan(demoSource());
    expect(plan.pages.map((p) => p.slot).toList(), [
      'cover',
      'welcome',
      'birth',
      for (var m = 1; m <= 12; m++) 'month:$m',
      'milestones',
      'letters',
      'one_year',
      'back_cover',
    ]);
    expect(plan.page('month:3').title, '3. Ayım');
    expect(plan.page('welcome').title, 'Hoş geldin, Defne');
  });

  test('content is assigned to the right chapter by date', () {
    final plan = composer.plan(demoSource());
    expect(refs(plan, 'welcome'), {'m-pregnancy'});
    expect(refs(plan, 'birth'), {'m-birth', 'p-birth'});
    expect(refs(plan, 'month:1'), containsAll(['m-month1', 'p-m1-a', 'p-m1-b']));
    expect(refs(plan, 'month:3'), contains('m-month3'));
    expect(refs(plan, 'month:12'), contains('m-month12-last-day'));
    expect(refs(plan, 'one_year'), {'m-birthday', 'p-birthday'});
  });

  test('content outside the first year is never a candidate (archive continues separately)', () {
    final plan = composer.plan(demoSource());
    final all = {for (final p in plan.pages) ...p.items.map((i) => i.refId)};
    expect(all, isNot(contains('m-after')));
    expect(all, isNot(contains('p-after')));
    expect(all, isNot(contains('ms-late')));
  });

  test('a first-year memory added after the first birthday is included', () {
    final plan = composer.plan(demoSource());
    final fy = defne.firstYear;
    final slot = 'month:${fy.monthIndex(Dates.addDays(defne.birthDate, 200))}';
    expect(refs(plan, slot), contains('m-late-added'));
  });

  test('user exclusions and unfinished uploads are respected', () {
    final plan = composer.plan(demoSource());
    final all = {for (final p in plan.pages) ...p.items.map((i) => i.refId)};
    expect(all, isNot(contains('m-excluded')));
    expect(all, isNot(contains('p-excluded')));
    expect(all, isNot(contains('p-uploading')));
    expect(all, isNot(contains('v-video')), reason: 'videos without a thumbnail cannot be printed');
  });

  test('milestones and letters get their own chapters with their photos', () {
    final plan = composer.plan(demoSource());
    expect(refs(plan, 'milestones'), {'ms-steps', 'ms-tooth', 'p-steps'});
    expect(refs(plan, 'letters'), {'l-teyze', 'p-letter'});
    // milestones are chronological
    final ms = plan
        .page('milestones')
        .items
        .where((i) => i.type == BookItemType.milestone)
        .map((i) => i.refId)
        .toList();
    expect(ms, ['ms-tooth', 'ms-steps']);
  });

  test('photo cap keeps big months readable but hides (not drops) the rest', () {
    final src = demoSource();
    final many = [for (var i = 0; i < 30; i++) photo('bulk-$i', Dates.addDays(defne.birthDate, 35 + (i % 20)))];
    final plan = const BookComposer(maxVisiblePhotosPerMonth: 12)
        .plan(BookSourceCopy.withMedia(src, [...src.media, ...many], favorites: {'bulk-29'}));
    final month2 = plan.page('month:2').items.where((i) => i.type == BookItemType.media).toList();
    expect(month2.length, 30);
    expect(month2.where((i) => !i.hidden).length, 12);
    expect(month2.firstWhere((i) => i.refId == 'bulk-29').hidden, isFalse, reason: 'favourites win');
  });

  test('cover suggestion prefers the first birthday photo', () {
    expect(composer.suggestCover(demoSource()), 'p-birthday');
  });

  test('sync ("Kitabı güncelle") only adds content that is new to the project', () {
    final src = demoSource();
    final plan = composer.plan(src);
    final project = projectFromPlan(plan);
    // nothing new
    expect(composer.sync(project, composer.plan(src)).isEmpty, isTrue);

    // A forgotten first-year memory is added when the child is 2 years old
    final newer = BookSourceCopy.withMemories(src, [
      ...src.memories,
      memory('m-forgotten', Dates.addDays(defne.birthDate, 100)),
    ]);
    final result = composer.sync(project, composer.plan(newer));
    expect(result.newItemCount, 1);
    final slot = 'month:${defne.firstYear.monthIndex(Dates.addDays(defne.birthDate, 100))}';
    expect(result.newItems[slot]!.single.refId, 'm-forgotten');
  });

  test('sync keeps items the user removed and restores deleted structural pages', () {
    final src = demoSource();
    final plan = composer.plan(src);
    final project = projectFromPlan(plan, dropSlots: {'letters'});
    final result = composer.sync(project, plan, removedRefIds: {'m-month3'});
    expect(result.missingPages.map((p) => p.slot), ['letters']);
    expect(result.newItems.values.expand((l) => l).map((i) => i.refId), isNot(contains('m-month3')));
  });

  test('month summary text', () {
    expect(monthSummary(memories: 4, photos: 12, milestones: 1), 'Bu ay 4 anı, 12 fotoğraf ve 1 ilk biriktirdik.');
    expect(monthSummary(memories: 0, photos: 3, milestones: 0), 'Bu ay 3 fotoğraf biriktirdik.');
    expect(monthSummary(memories: 0, photos: 0, milestones: 0), 'Bu ay sessiz ve huzurlu geçti.');
  });
}

/// Builds a persisted-looking project from a plan (as the repository does).
BookProject projectFromPlan(BookPlan plan, {Set<String> dropSlots = const {}}) {
  var order = 0;
  final pages = <BookPage>[];
  for (final p in plan.pages.where((p) => !dropSlots.contains(p.slot))) {
    final pageId = 'page-${p.slot}';
    pages.add(
      BookPage(
        id: pageId,
        projectId: 'project',
        type: p.type,
        monthIndex: p.monthIndex,
        title: p.title,
        body: null,
        sortOrder: order++,
        isHidden: false,
        items: [
          for (var i = 0; i < p.items.length; i++)
            BookItem(
              id: 'item-${p.items[i].refId}',
              pageId: pageId,
              type: p.items[i].type,
              refId: p.items[i].refId,
              sortOrder: i,
              isHidden: p.items[i].hidden,
            ),
        ],
      ),
    );
  }
  return BookProject(
    id: 'project',
    babyId: defne.id,
    title: 'Bebeğimin İlk Yılı',
    subtitle: null,
    format: BookFormat.square21,
    coverMediaId: plan.coverMediaId,
    backCoverText: null,
    currentVersion: 1,
    lastSyncedAt: null,
    updatedAt: DateTime.utc(2026, 9, 20),
    pages: pages,
  );
}

extension BookSourceCopy on BookSource {
  static BookSource withMedia(BookSource s, List media, {Set<String> favorites = const {}}) => BookSource(
    baby: s.baby,
    memories: s.memories,
    media: media.cast(),
    milestones: s.milestones,
    milestoneTypes: s.milestoneTypes,
    letters: s.letters,
    favoriteIds: favorites,
  );

  static BookSource withMemories(BookSource s, List memories) => BookSource(
    baby: s.baby,
    memories: memories.cast(),
    media: s.media,
    milestones: s.milestones,
    milestoneTypes: s.milestoneTypes,
    letters: s.letters,
  );
}
