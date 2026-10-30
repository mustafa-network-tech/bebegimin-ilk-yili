import 'dates.dart';

/// Age of a child on a given day, calendar based (like PostgreSQL `age()`).
class BabyAge {
  const BabyAge({
    required this.years,
    required this.months,
    required this.days,
    required this.totalDays,
    required this.totalMonths,
  });

  /// Age at [on] for a child born on [birthDate]. Returns `null` for days
  /// before the birth (e.g. pregnancy memories).
  static BabyAge? at(DateTime birthDate, DateTime on) {
    final birth = Dates.dateOnly(birthDate);
    final day = Dates.dateOnly(on);
    final totalDays = Dates.daysBetween(birth, day);
    if (totalDays < 0) return null;

    var totalMonths = (day.year - birth.year) * 12 + (day.month - birth.month);
    if (Dates.addMonths(birth, totalMonths).isAfter(day)) totalMonths--;
    final anchor = Dates.addMonths(birth, totalMonths);
    final days = Dates.daysBetween(anchor, day);
    return BabyAge(
      years: totalMonths ~/ 12,
      months: totalMonths % 12,
      days: days,
      totalDays: totalDays,
      totalMonths: totalMonths,
    );
  }

  final int years;
  final int months;
  final int days;
  final int totalDays;
  final int totalMonths;

  /// Short, human friendly age:
  ///   "Bugün doğdu", "18 günlük", "3 aylık 12 günlük", "11 aylık",
  ///   "1 yaş 4 aylık", "2 yaşında".
  String get label {
    if (years == 0) {
      if (totalMonths == 0) {
        return totalDays == 0 ? 'Bugün doğdu' : '$totalDays günlük';
      }
      return days == 0 ? '$months aylık' : '$months aylık $days günlük';
    }
    if (months == 0) return '$years yaşında';
    return '$years yaş $months aylık';
  }

  /// Used inside sentences: "Defne 3 aylık 12 günlükken", "1 yaş 4 aylıkken".
  String get whileLabel {
    if (years == 0 && totalMonths == 0 && totalDays == 0) return 'doğduğu gün';
    final l = label;
    if (l.endsWith('yaşında')) return l.replaceFirst('yaşında', 'yaşındayken');
    return '${l}ken';
  }

  @override
  String toString() => label;
}

/// Parts of the archive after the first year are grouped by age: 0–1, 1–2 …
class AgePeriod {
  const AgePeriod(this.index);

  /// 0 = before the first birthday ("İlk Yılım"), 1 = "1–2 yaş" …
  final int index;

  static AgePeriod? forDate(DateTime birthDate, DateTime date) {
    final age = BabyAge.at(birthDate, date);
    if (age == null) return null;
    return AgePeriod(age.years);
  }

  String get label => index == 0 ? 'İlk Yılım' : '$index–${index + 1} yaş';

  DateTime start(DateTime birthDate) => Dates.addYears(birthDate, index);

  /// Exclusive end.
  DateTime end(DateTime birthDate) => Dates.addYears(birthDate, index + 1);

  @override
  bool operator ==(Object other) => other is AgePeriod && other.index == index;

  @override
  int get hashCode => index.hashCode;
}
