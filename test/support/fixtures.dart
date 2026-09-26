import 'package:bebegimin_ilk_yili/core/utils/dates.dart';
import 'package:bebegimin_ilk_yili/features/babies/domain/baby.dart';
import 'package:bebegimin_ilk_yili/features/book/domain/book_composer.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/relation.dart';
import 'package:bebegimin_ilk_yili/features/letters/domain/letter.dart';
import 'package:bebegimin_ilk_yili/features/media/domain/media_item.dart';
import 'package:bebegimin_ilk_yili/features/memories/domain/memory.dart';
import 'package:bebegimin_ilk_yili/features/milestones/domain/milestone.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);

final defne = Baby(
  id: 'baby-defne',
  firstName: 'Defne',
  lastName: 'Yılmaz',
  birthDate: d(2025, 9, 12),
  birthTime: '04:35:00',
  birthPlace: 'İstanbul',
  birthWeightGrams: 3250,
  birthLengthCm: 50.5,
  story: 'Bir sonbahar sabahı geldin.',
);

Memory memory(String id, DateTime date, {bool include = true, String? milestoneId, String title = 'Anı'}) => Memory(
  id: id,
  babyId: defne.id,
  authorId: 'user-anne',
  title: title,
  body: 'Açıklama $id — çok güzel bir gündü, şimdi seni öpüyorum.',
  date: date,
  time: null,
  category: MemoryCategory.moment,
  milestoneId: milestoneId,
  includeInBook: include,
  createdAt: date,
);

MediaItem photo(
  String id,
  DateTime takenOn, {
  String? memoryId,
  String? milestoneId,
  String? letterId,
  bool include = true,
  bool video = false,
  String status = 'ready',
  int w = 3024,
  int h = 4032,
}) => MediaItem(
  id: id,
  babyId: defne.id,
  uploaderId: 'user-anne',
  memoryId: memoryId,
  milestoneId: milestoneId,
  letterId: letterId,
  kind: video ? MediaKind.video : MediaKind.photo,
  storagePath: '${defne.id}/$id/original.${video ? 'mp4' : 'jpg'}',
  thumbPath: video ? null : '${defne.id}/$id/thumb.jpg',
  mimeType: video ? 'video/mp4' : 'image/jpeg',
  width: w,
  height: h,
  durationMs: video ? 12000 : null,
  caption: null,
  takenOn: takenOn,
  tags: const [],
  includeInBook: include,
  status: status,
  createdAt: takenOn,
);

const firstStepsType = MilestoneType(
  id: 'type-steps',
  key: 'first_steps',
  babyId: null,
  title: 'İlk adımım',
  emoji: '👣',
  sortOrder: 80,
  createdBy: null,
);
const firstToothType = MilestoneType(
  id: 'type-tooth',
  key: 'first_tooth',
  babyId: null,
  title: 'İlk dişim',
  emoji: '🦷',
  sortOrder: 40,
  createdBy: null,
);

Milestone milestone(String id, String typeId, DateTime on, {bool include = true}) => Milestone(
  id: id,
  babyId: defne.id,
  typeId: typeId,
  achievedOn: on,
  achievedTime: null,
  description: 'Harika bir an',
  includeInBook: include,
  createdBy: 'user-anne',
  createdAt: on,
);

Letter letter(String id, DateTime on, {bool include = true}) => Letter(
  id: id,
  babyId: defne.id,
  authorId: 'user-teyze',
  authorName: 'Zeynep',
  authorRelation: Relation.teyze,
  authorRelationLabel: null,
  title: 'Sevgili Defne',
  body: 'Bugün seni ilk kez kucağıma aldım... Çığlık, gülüş ve ışık dolu bir gün.',
  writtenOn: on,
  includeInBook: include,
  createdAt: on,
);

/// A realistic first year for Defne (born 12 Sep 2025).
BookSource demoSource() {
  final birth = defne.birthDate;
  final memories = [
    memory('m-pregnancy', Dates.addDays(birth, -40), title: 'İlk tekme'),
    memory('m-birth', birth, title: 'Hoş geldin'),
    memory('m-month1', Dates.addDays(birth, 10)),
    memory('m-month3', Dates.addMonths(birth, 2)),
    memory('m-month12-last-day', Dates.addDays(birth, 364)),
    memory('m-birthday', Dates.addYears(birth, 1), title: 'Doğum günü partisi'),
    memory('m-after', Dates.addDays(birth, 400)),
    memory('m-excluded', Dates.addDays(birth, 50), include: false),
    // Added when she was 14 months old but dated inside the first year:
    memory('m-late-added', Dates.addDays(birth, 200)),
  ];
  final media = [
    photo('p-birth', birth, memoryId: 'm-birth'),
    photo('p-m1-a', Dates.addDays(birth, 10), memoryId: 'm-month1'),
    photo('p-m1-b', Dates.addDays(birth, 12), w: 4032, h: 3024),
    photo('p-steps', Dates.addDays(birth, 330), milestoneId: 'ms-steps'),
    photo('p-letter', Dates.addDays(birth, 2), letterId: 'l-teyze'),
    photo('p-birthday', Dates.addYears(birth, 1), memoryId: 'm-birthday'),
    photo('p-after', Dates.addDays(birth, 420)),
    photo('p-excluded', Dates.addDays(birth, 20), include: false),
    photo('p-uploading', Dates.addDays(birth, 21), status: 'uploading'),
    photo('v-video', Dates.addDays(birth, 22), video: true),
  ];
  return BookSource(
    baby: defne,
    memories: memories,
    media: media,
    milestones: [
      milestone('ms-steps', firstStepsType.id, Dates.addDays(birth, 330)),
      milestone('ms-tooth', firstToothType.id, Dates.addDays(birth, 190)),
      milestone('ms-late', firstToothType.id, Dates.addDays(birth, 500)),
    ],
    milestoneTypes: {firstStepsType.id: firstStepsType, firstToothType.id: firstToothType},
    letters: [letter('l-teyze', Dates.addDays(birth, 2)), letter('l-later', Dates.addDays(birth, 700))],
  );
}
