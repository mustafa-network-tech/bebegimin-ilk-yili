import 'package:collection/collection.dart';

import '../../../core/utils/baby_age.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/turkish.dart';
import '../../family/domain/family_member.dart';
import '../../media/domain/media_item.dart';
import 'book_composer.dart';
import 'book_models.dart';

/// Fully resolved, serialisable book content. Built on the UI isolate,
/// rendered to PDF on a background isolate.
class BookRenderData {
  const BookRenderData({
    required this.title,
    required this.subtitle,
    required this.babyName,
    required this.format,
    required this.cover,
    required this.backCoverText,
    required this.yearsLabel,
    required this.birth,
    required this.stats,
    required this.pages,
  });

  final String title;
  final String? subtitle;
  final String babyName;
  final BookFormat format;
  final RenderPhoto? cover;
  final String backCoverText;
  final String yearsLabel;
  final BirthInfo birth;
  final BookStats stats;

  /// Content pages in order (cover/back cover are rendered separately).
  final List<RenderPage> pages;

  /// Every photo that needs to be downloaded.
  Iterable<RenderPhoto> get allPhotos sync* {
    if (cover != null) yield cover!;
    for (final p in pages) {
      yield* p.loosePhotos;
      for (final m in p.memories) {
        yield* m.photos;
      }
      for (final m in p.milestones) {
        yield* m.photos;
      }
      for (final l in p.letters) {
        yield* l.photos;
      }
    }
  }
}

class RenderPhoto {
  const RenderPhoto({required this.mediaId, required this.path, required this.aspect, this.caption});

  final String mediaId;

  /// Storage path of the image to print (thumbnail for videos).
  final String path;
  final double aspect;
  final String? caption;
}

class RenderMemory {
  const RenderMemory({
    required this.title,
    required this.body,
    required this.dateLabel,
    required this.author,
    required this.photos,
  });

  final String title;
  final String? body;
  final String dateLabel;
  final String? author;
  final List<RenderPhoto> photos;
}

class RenderMilestone {
  const RenderMilestone({
    required this.title,
    required this.dateLabel,
    required this.description,
    required this.photos,
  });

  final String title;
  final String dateLabel;
  final String? description;
  final List<RenderPhoto> photos;
}

class RenderLetter {
  const RenderLetter({
    required this.title,
    required this.body,
    required this.signature,
    required this.dateLabel,
    required this.photos,
  });

  final String? title;
  final String body;
  final String signature;
  final String dateLabel;
  final List<RenderPhoto> photos;
}

class RenderPage {
  RenderPage({required this.type, required this.title, this.monthIndex, this.subtitle, this.summary, this.note});

  final BookPageType type;
  final int? monthIndex;
  final String title;
  final String? subtitle;
  final String? summary;
  final String? note;
  final List<RenderMemory> memories = [];
  final List<RenderPhoto> loosePhotos = [];
  final List<RenderMilestone> milestones = [];
  final List<RenderLetter> letters = [];

  bool get isEmpty =>
      memories.isEmpty && loosePhotos.isEmpty && milestones.isEmpty && letters.isEmpty && (note?.isEmpty ?? true);
}

class BirthInfo {
  const BirthInfo({required this.dateLabel, this.time, this.place, this.weight, this.length, this.story});

  final String dateLabel;
  final String? time;
  final String? place;
  final String? weight;
  final String? length;
  final String? story;
}

class BookStats {
  const BookStats({required this.memories, required this.photos, required this.milestones, required this.letters});

  final int memories;
  final int photos;
  final int milestones;
  final int letters;
}

/// Turns the editable project + source content into [BookRenderData].
class BookRenderResolver {
  const BookRenderResolver();

  BookRenderData resolve({
    required BookProject project,
    required BookSource source,
    required List<FamilyMember> members,
  }) {
    final baby = source.baby;
    final fy = baby.firstYear;
    final memories = {for (final m in source.memories) m.id: m};
    final media = {for (final m in source.media) m.id: m};
    final milestones = {for (final m in source.milestones) m.id: m};
    final letters = {for (final l in source.letters) l.id: l};
    final membersByUser = {for (final m in members) m.userId: m};

    RenderPhoto? photo(MediaItem? m, {String? caption}) {
      if (m == null) return null;
      final path = m.isVideo ? m.thumbPath : m.storagePath;
      if (path == null) return null;
      return RenderPhoto(mediaId: m.id, path: path, aspect: m.aspectRatio, caption: caption ?? m.caption);
    }

    String ageLabel(DateTime d) {
      final age = BabyAge.at(baby.birthDate, d);
      if (age == null) return 'Doğumundan önce';
      return age.totalDays == 0 ? 'Doğduğu gün' : age.label;
    }

    String dateLine(DateTime d) => '${Dates.long(d)} · ${ageLabel(d)}';

    final pages = <RenderPage>[];
    var statMemories = 0, statPhotos = 0, statMilestones = 0, statLetters = 0;

    for (final page in project.pages.where((p) => !p.isHidden)) {
      if (page.type == BookPageType.cover || page.type == BookPageType.backCover) continue;
      final visible = page.visibleItems;
      final visibleMediaIds = {for (final i in visible.where((i) => i.type == BookItemType.media)) i.refId};
      final captions = {for (final i in visible) i.refId: i.caption};
      final usedMedia = <String>{};

      List<RenderPhoto> attached(bool Function(MediaItem) test) {
        final list = <RenderPhoto>[];
        for (final item in visible.where((i) => i.type == BookItemType.media)) {
          final m = media[item.refId];
          if (m == null || usedMedia.contains(m.id) || !test(m)) continue;
          final p = photo(m, caption: captions[m.id]);
          if (p != null) {
            list.add(p);
            usedMedia.add(m.id);
          }
        }
        return list;
      }

      String? subtitle;
      String? summary;
      if (page.type == BookPageType.month && page.monthIndex != null) {
        final (from, to) = fy.monthRange(page.monthIndex!);
        subtitle = '${Dates.dayMonth(from)} – ${Dates.long(to)}';
        final monthMilestones = source.milestones
            .where((m) => m.includeInBook && fy.monthIndex(m.achievedOn) == page.monthIndex)
            .length;
        summary = monthSummary(
          memories: visible.where((i) => i.type == BookItemType.memory).length,
          photos: visibleMediaIds.length,
          milestones: monthMilestones,
        );
      }

      final rp = RenderPage(
        type: page.type,
        monthIndex: page.monthIndex,
        title: page.title,
        subtitle: subtitle,
        summary: summary,
        note: page.body,
      );

      for (final item in visible) {
        switch (item.type) {
          case BookItemType.memory:
            final m = memories[item.refId];
            if (m == null) continue;
            final author = m.authorId == null ? null : membersByUser[m.authorId]?.introduction;
            rp.memories.add(
              RenderMemory(
                title: m.title,
                body: m.body,
                dateLabel: dateLine(m.date),
                author: author,
                photos: attached((x) => x.memoryId == m.id),
              ),
            );
            statMemories++;
          case BookItemType.milestone:
            final ms = milestones[item.refId];
            if (ms == null) continue;
            final type = source.milestoneTypes[ms.typeId];
            rp.milestones.add(
              RenderMilestone(
                title: type?.title ?? 'İlk',
                dateLabel: dateLine(ms.achievedOn),
                description: ms.description,
                photos: attached((x) => x.milestoneId == ms.id),
              ),
            );
            statMilestones++;
          case BookItemType.letter:
            final l = letters[item.refId];
            if (l == null) continue;
            rp.letters.add(
              RenderLetter(
                title: l.title,
                body: l.body,
                signature: l.signature,
                dateLabel: Dates.long(l.writtenOn),
                photos: attached((x) => x.letterId == l.id),
              ),
            );
            statLetters++;
          case BookItemType.media:
            break;
        }
      }
      // Photos that were not rendered next to their memory / milestone.
      for (final item in visible.where((i) => i.type == BookItemType.media)) {
        if (usedMedia.contains(item.refId)) continue;
        final p = photo(media[item.refId], caption: captions[item.refId]);
        if (p != null) {
          rp.loosePhotos.add(p);
          usedMedia.add(item.refId);
        }
      }
      statPhotos += usedMedia.length;
      pages.add(rp);
    }

    final coverMedia = media[project.coverMediaId] ?? media[const BookComposer().suggestCover(source)];
    final lastYear = fy.firstBirthday.year;
    return BookRenderData(
      title: project.title,
      subtitle: project.subtitle,
      babyName: baby.fullName,
      format: project.format,
      cover: photo(coverMedia),
      backCoverText: (project.backCoverText?.trim().isNotEmpty ?? false)
          ? project.backCoverText!.trim()
          : 'Bu kitap, ${Turkish.genitive(baby.firstName)} ilk yılının en güzel anlarıyla, sevgiyle hazırlandı.',
      yearsLabel: baby.birthDate.year == lastYear ? '${baby.birthDate.year}' : '${baby.birthDate.year} – $lastYear',
      birth: BirthInfo(
        dateLabel: Dates.longWithWeekday(baby.birthDate),
        time: Dates.timeLabel(baby.birthTime),
        place: baby.birthPlace,
        weight: baby.birthWeightLabel,
        length: baby.birthLengthLabel,
        story: baby.story,
      ),
      stats: BookStats(memories: statMemories, photos: statPhotos, milestones: statMilestones, letters: statLetters),
      pages: pages,
    );
  }

  /// First available photo of a page (used for the "Bir Yaşındayım" hero).
  static RenderPhoto? heroOf(RenderPage p) =>
      p.loosePhotos.firstOrNull ?? p.memories.expand((m) => m.photos).firstOrNull;
}
