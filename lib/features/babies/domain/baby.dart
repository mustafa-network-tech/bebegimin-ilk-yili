import '../../../core/utils/baby_age.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/first_year.dart';

class Baby {
  const Baby({
    required this.id,
    required this.firstName,
    required this.birthDate,
    this.lastName,
    this.birthTime,
    this.birthPlace,
    this.birthWeightGrams,
    this.birthLengthCm,
    this.avatarPath,
    this.coverPath,
    this.story,
    this.createdAt,
  });

  factory Baby.fromJson(Map<String, dynamic> j) => Baby(
    id: j['id'] as String,
    firstName: j['first_name'] as String,
    lastName: j['last_name'] as String?,
    birthDate: Dates.fromSql(j['birth_date'] as String),
    birthTime: j['birth_time'] as String?,
    birthPlace: j['birth_place'] as String?,
    birthWeightGrams: (j['birth_weight_grams'] as num?)?.toInt(),
    birthLengthCm: (j['birth_length_cm'] as num?)?.toDouble(),
    avatarPath: j['avatar_path'] as String?,
    coverPath: j['cover_path'] as String?,
    story: j['story'] as String?,
    createdAt: j['created_at'] == null ? null : DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String firstName;
  final String? lastName;
  final DateTime birthDate;

  /// PostgreSQL `time` ("04:35:00").
  final String? birthTime;
  final String? birthPlace;
  final int? birthWeightGrams;
  final double? birthLengthCm;
  final String? avatarPath;
  final String? coverPath;
  final String? story;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'first_name': firstName,
    'last_name': lastName,
    'birth_date': Dates.toSql(birthDate),
    'birth_time': birthTime,
    'birth_place': birthPlace,
    'birth_weight_grams': birthWeightGrams,
    'birth_length_cm': birthLengthCm,
    'avatar_path': avatarPath,
    'cover_path': coverPath,
    'story': story,
    'created_at': createdAt?.toIso8601String(),
  };

  String get fullName => [firstName, if (lastName?.isNotEmpty ?? false) lastName].join(' ');

  BabyAge? ageOn(DateTime day) => BabyAge.at(birthDate, day);

  BabyAge ageToday([DateTime? now]) =>
      BabyAge.at(birthDate, Dates.today(now)) ??
      const BabyAge(years: 0, months: 0, days: 0, totalDays: 0, totalMonths: 0);

  FirstYearPeriod get firstYear => FirstYearPeriod(birthDate);

  String? get birthWeightLabel => birthWeightGrams == null
      ? null
      : '${(birthWeightGrams! / 1000).toStringAsFixed(2).replaceAll('.', ',')} kg';

  String? get birthLengthLabel => birthLengthCm == null
      ? null
      : '${birthLengthCm!.toStringAsFixed(birthLengthCm! % 1 == 0 ? 0 : 1).replaceAll('.', ',')} cm';
}

/// Upcoming important day shown on the home screen.
class UpcomingDay {
  const UpcomingDay({required this.date, required this.title, required this.kind});

  final DateTime date;
  final String title;
  final UpcomingKind kind;
}

enum UpcomingKind { monthiversary, birthday, firstYearComplete, capsule }

/// Next month-iversaries / birthdays (pure, testable).
List<UpcomingDay> upcomingDays(Baby baby, DateTime today, {int limit = 3}) {
  final t = Dates.dateOnly(today);
  final result = <UpcomingDay>[];
  // Month-iversaries during the first two years, then birthdays only.
  for (var m = 1; m <= 12 * 120 && result.length < limit; m++) {
    final date = Dates.addMonths(baby.birthDate, m);
    if (date.isBefore(t)) continue;
    if (m % 12 == 0) {
      result.add(UpcomingDay(date: date, title: '${m ~/ 12}. yaş günü 🎂', kind: UpcomingKind.birthday));
    } else if (m < 24) {
      result.add(UpcomingDay(date: date, title: '$m. ay dönümü', kind: UpcomingKind.monthiversary));
    }
  }
  final fy = baby.firstYear;
  if (!fy.isComplete(t)) {
    result.add(UpcomingDay(
      date: Dates.addDays(fy.end, 1),
      title: 'İlk Yılım kitabı hazır olacak 📖',
      kind: UpcomingKind.firstYearComplete,
    ));
  }
  result.sort((a, b) => a.date.compareTo(b.date));
  return result.take(limit).toList();
}
