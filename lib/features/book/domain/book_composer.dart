import 'package:collection/collection.dart';

import '../../../core/utils/dates.dart';
import '../../../core/utils/first_year.dart';
import '../../babies/domain/baby.dart';
import '../../letters/domain/letter.dart';
import '../../media/domain/media_item.dart';
import '../../memories/domain/memory.dart';
import '../../milestones/domain/milestone.dart';
import 'book_models.dart';

/// Everything that may end up in the book.
class BookSource {
  const BookSource({
    required this.baby,
    required this.memories,
    required this.media,
    required this.milestones,
    required this.milestoneTypes,
    required this.letters,
    this.favoriteIds = const {},
    this.closeDate,
  });

  final Baby baby;
  final List<Memory> memories;
  final List<MediaItem> media;
  final List<Milestone> milestones;
  final Map<String, MilestoneType> milestoneTypes;
  final List<Letter> letters;
  final Set<String> favoriteIds;

  /// Exclusive close date of the archive (decision P-1): the effective close
  /// date incl. an approved extension. `null` = the standard 375 days.
  final DateTime? closeDate;
}

/// A page slot of the default structure plus the items that belong to it.
class PlannedPage {
  PlannedPage({required this.type, this.monthIndex, required this.title});

  final BookPageType type;
  final int? monthIndex;
  final String title;
  final List<PlannedItem> items = [];

  String get slot => type == BookPageType.month ? 'month:$monthIndex' : type.key;
}

class PlannedItem {
  const PlannedItem({required this.type, required this.refId, required this.date, this.hidden = false});

  final BookItemType type;
  final String refId;
  final DateTime date;
  final bool hidden;

  PlannedItem withHidden(bool h) => PlannedItem(type: type, refId: refId, date: date, hidden: h);
}

class BookPlan {
  const BookPlan({required this.pages, required this.coverMediaId});

  final List<PlannedPage> pages;
  final String? coverMediaId;

  PlannedPage page(String slot) => pages.firstWhere((p) => p.slot == slot);

  int get visibleItemCount => pages.fold(0, (n, p) => n + p.items.where((i) => !i.hidden).length);
}

/// Items to add to an existing project ("Taslağı yenile" / "Kitabı güncelle").
class BookSyncResult {
  const BookSyncResult({required this.missingPages, required this.newItems});

  /// Structural pages that do not exist yet (e.g. deleted before).
  final List<PlannedPage> missingPages;

  /// slot → new items to append to that page.
  final Map<String, List<PlannedItem>> newItems;

  int get newItemCount => newItems.values.fold(0, (n, l) => n + l.length);

  bool get isEmpty => missingPages.isEmpty && newItemCount == 0;
}

/// Pure logic that decides which content goes to which chapter.
class BookComposer {
  const BookComposer({this.maxVisiblePhotosPerMonth = 12, this.maxVisiblePhotosOther = 8});

  final int maxVisiblePhotosPerMonth;
  final int maxVisiblePhotosOther;

  /// Default chapter order of the "İlk Yılım" book.
  List<PlannedPage> structure(Baby baby) => [
    PlannedPage(type: BookPageType.cover, title: BookPageType.cover.defaultTitle(baby.firstName)),
    PlannedPage(type: BookPageType.welcome, title: BookPageType.welcome.defaultTitle(baby.firstName)),
    PlannedPage(type: BookPageType.birth, title: BookPageType.birth.defaultTitle(baby.firstName)),
    for (var m = 1; m <= 12; m++)
      PlannedPage(type: BookPageType.month, monthIndex: m, title: BookPageType.month.defaultTitle(baby.firstName, m)),
    PlannedPage(type: BookPageType.milestones, title: BookPageType.milestones.defaultTitle(baby.firstName)),
    PlannedPage(type: BookPageType.letters, title: BookPageType.letters.defaultTitle(baby.firstName)),
    PlannedPage(type: BookPageType.oneYear, title: BookPageType.oneYear.defaultTitle(baby.firstName)),
    PlannedPage(type: BookPageType.backCover, title: BookPageType.backCover.defaultTitle(baby.firstName)),
  ];

  /// Which page slot a dated piece of content belongs to (null = not in book).
  /// After the 365 days and before the archive closed ([closeDate], see
  /// [BookSource.closeDate]) content belongs to "Bir Yaşındayım".
  String? slotForDate(FirstYearPeriod fy, DateTime date, {DateTime? closeDate}) {
    if (fy.isPregnancy(date)) return BookPageType.welcome.key;
    if (Dates.isSameDay(date, fy.start)) return BookPageType.birth.key;
    if (fy.contains(date)) return 'month:${fy.monthIndex(date)}';
    if (fy.isClosingWindow(date, closeDate: closeDate)) return BookPageType.oneYear.key;
    return null;
  }

  /// Letters are family messages: written any time before the archive
  /// closed (pregnancy included).
  bool letterIsCandidate(FirstYearPeriod fy, Letter l, {DateTime? closeDate}) =>
      Dates.dateOnly(l.writtenOn).isBefore(Dates.dateOnly(closeDate ?? fy.standardClose));

  BookPlan plan(BookSource src) {
    final fy = src.baby.firstYear;
    final pages = structure(src.baby);
    final bySlot = {for (final p in pages) p.slot: p};

    final includedMemoryIds = <String>{};
    for (final m in src.memories.where((m) => m.includeInBook)) {
      final slot = slotForDate(fy, m.date, closeDate: src.closeDate);
      if (slot == null) continue;
      bySlot[slot]!.items.add(PlannedItem(type: BookItemType.memory, refId: m.id, date: m.date));
      includedMemoryIds.add(m.id);
    }

    final includedMilestoneIds = <String>{};
    for (final ms in src.milestones.where((m) => m.includeInBook)) {
      if (slotForDate(fy, ms.achievedOn, closeDate: src.closeDate) == null) continue;
      bySlot[BookPageType.milestones.key]!.items.add(
        PlannedItem(type: BookItemType.milestone, refId: ms.id, date: ms.achievedOn),
      );
      includedMilestoneIds.add(ms.id);
    }

    final includedLetterIds = <String>{};
    for (final l in src.letters.where((l) => l.includeInBook && letterIsCandidate(fy, l, closeDate: src.closeDate))) {
      bySlot[BookPageType.letters.key]!.items.add(
        PlannedItem(type: BookItemType.letter, refId: l.id, date: l.writtenOn),
      );
      includedLetterIds.add(l.id);
    }

    // Photos: videos cannot be printed; only their thumbnails are usable.
    final photoCandidates = src.media.where(
      (m) => m.status == 'ready' && m.includeInBook && (!m.isVideo || m.thumbPath != null),
    );
    for (final media in photoCandidates) {
      String? slot;
      if (media.milestoneId != null) {
        if (!includedMilestoneIds.contains(media.milestoneId)) continue;
        slot = BookPageType.milestones.key;
      } else if (media.letterId != null) {
        if (!includedLetterIds.contains(media.letterId)) continue;
        slot = BookPageType.letters.key;
      } else {
        final memory = media.memoryId == null ? null : src.memories.firstWhereOrNull((m) => m.id == media.memoryId);
        if (memory != null && !memory.includeInBook) continue;
        slot = slotForDate(fy, memory?.date ?? media.takenOn, closeDate: src.closeDate);
      }
      if (slot == null) continue;
      bySlot[slot]!.items.add(PlannedItem(type: BookItemType.media, refId: media.id, date: media.takenOn));
    }

    for (final p in pages) {
      p.items.sort((a, b) {
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.type.index.compareTo(b.type.index);
      });
      _applyPhotoCap(p, src);
    }

    return BookPlan(pages: pages, coverMediaId: suggestCover(src));
  }

  /// Keeps big months readable: only the best N photos are visible by
  /// default, the rest are added as hidden items the user can re-enable.
  void _applyPhotoCap(PlannedPage page, BookSource src) {
    final cap = page.type == BookPageType.month ? maxVisiblePhotosPerMonth : maxVisiblePhotosOther;
    final photos = page.items.where((i) => i.type == BookItemType.media).toList();
    if (photos.length <= cap) return;
    final mediaById = {for (final m in src.media) m.id: m};
    int score(PlannedItem i) {
      final m = mediaById[i.refId];
      var s = 0;
      if (src.favoriteIds.contains(i.refId)) s += 4;
      if (m?.memoryId != null || m?.milestoneId != null) s += 2;
      if ((m?.caption?.isNotEmpty ?? false)) s += 1;
      return s;
    }

    // Best scored first; ties spread evenly across the month by date.
    final ranked = photos.toList()
      ..sort((a, b) {
        final s = score(b).compareTo(score(a));
        return s != 0 ? s : a.date.compareTo(b.date);
      });
    final keep = <String>{};
    final top = ranked.where((i) => score(i) > 0).take(cap).map((i) => i.refId).toSet();
    keep.addAll(top);
    final rest = photos.where((i) => !keep.contains(i.refId)).toList();
    final remaining = cap - keep.length;
    if (remaining > 0 && rest.isNotEmpty) {
      final step = rest.length / remaining;
      for (var k = 0; k < remaining; k++) {
        keep.add(rest[(k * step).floor().clamp(0, rest.length - 1)].refId);
      }
    }
    for (var idx = 0; idx < page.items.length; idx++) {
      final it = page.items[idx];
      if (it.type == BookItemType.media && !keep.contains(it.refId)) {
        page.items[idx] = it.withHidden(true);
      }
    }
  }

  /// Cover suggestion: a favourite photo from the first birthday or the
  /// last month, otherwise the latest first-year photo.
  String? suggestCover(BookSource src) {
    final fy = src.baby.firstYear;
    final photos =
        src.media
            .where(
              (m) =>
                  m.status == 'ready' &&
                  !m.isVideo &&
                  m.includeInBook &&
                  fy.isBookCandidate(m.takenOn, closeDate: src.closeDate),
            )
            .toList()
          ..sort((a, b) => b.takenOn.compareTo(a.takenOn));
    if (photos.isEmpty) return null;
    return (photos.firstWhereOrNull((m) => src.favoriteIds.contains(m.id) && !fy.isPregnancy(m.takenOn)) ??
            photos.firstWhereOrNull((m) => fy.isFirstBirthday(m.takenOn)) ??
            photos.first)
        .id;
  }

  /// Compares the current project with a fresh plan and returns what is new.
  /// User decisions (hidden items, removed items, order) are preserved:
  /// only content that has never been in the project is added.
  BookSyncResult sync(BookProject project, BookPlan fresh, {Set<String> removedRefIds = const {}}) {
    final existingSlots = {for (final p in project.pages) p.slot};
    final existingRefs = project.allRefIds;
    final missingPages = fresh.pages.where((p) => !existingSlots.contains(p.slot)).toList();
    final newItems = <String, List<PlannedItem>>{};
    for (final p in fresh.pages) {
      final add = p.items.where((i) => !existingRefs.contains(i.refId) && !removedRefIds.contains(i.refId)).toList();
      if (add.isNotEmpty) newItems[p.slot] = add;
    }
    return BookSyncResult(missingPages: missingPages, newItems: newItems);
  }
}

/// Short automatic month summary: "Bu ay 4 anı, 12 fotoğraf ve 1 ilk."
String monthSummary({required int memories, required int photos, required int milestones}) {
  final parts = <String>[
    if (memories > 0) '$memories anı',
    if (photos > 0) '$photos fotoğraf',
    if (milestones > 0) '$milestones ilk',
  ];
  if (parts.isEmpty) return 'Bu ay sessiz ve huzurlu geçti.';
  if (parts.length == 1) return 'Bu ay ${parts.first} biriktirdik.';
  return 'Bu ay ${parts.sublist(0, parts.length - 1).join(', ')} ve ${parts.last} biriktirdik.';
}
