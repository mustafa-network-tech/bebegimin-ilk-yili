import 'dates.dart';

/// The special "İlk Yılım" period: the first 365 days starting with the
/// birth date (day 1 = birth date, day 365 = birth date + 364 days).
///
/// It defines which content is a candidate for the official outputs.
/// Pregnancy memories (before birth) feed the "Hoş geldin" chapter. Content
/// after the 365 days and before the archive closed – the first birthday,
/// the final period of the standard 375 days and an approved extension
/// (decision P-1, at most 405 days) – feeds the "Bir Yaşındayım" chapter.
class FirstYearPeriod {
  FirstYearPeriod(DateTime birthDate)
    : start = Dates.dateOnly(birthDate),
      end = Dates.addDays(birthDate, lengthInDays - 1),
      firstBirthday = Dates.addYears(birthDate, 1),
      standardClose = Dates.addDays(birthDate, standardArchiveDays);

  static const int lengthInDays = 365;

  /// The archive is active for 375 days without an extension.
  static const int standardArchiveDays = 375;

  /// How far before the birth "Hoş geldin" (pregnancy) content may go.
  static const int pregnancyDays = 310;

  final DateTime start;

  /// Inclusive last day of the first 365 days.
  final DateTime end;
  final DateTime firstBirthday;

  /// Exclusive end of the archive without an extension (birth + 375 days).
  /// An approved extension moves it: pass `BabyLifecycle.effectiveCloseDate`
  /// (or the sealed snapshot's `effective_close_date`) as `closeDate`.
  final DateTime standardClose;

  /// 1-based day number ("184. gün"); `null` before birth.
  int? dayNumber(DateTime date) {
    final d = Dates.daysBetween(start, date);
    return d < 0 ? null : d + 1;
  }

  bool contains(DateTime date) {
    final d = Dates.dateOnly(date);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  bool isPregnancy(DateTime date) {
    final d = Dates.dateOnly(date);
    return d.isBefore(start) && !d.isBefore(Dates.addDays(start, -pregnancyDays));
  }

  bool isFirstBirthday(DateTime date) => Dates.isSameDay(Dates.dateOnly(date), firstBirthday);

  /// Days after the 365th day up to and including the first birthday
  /// (normally just the birthday; two days in leap years).
  bool isBirthdayWindow(DateTime date) {
    final d = Dates.dateOnly(date);
    return d.isAfter(end) && !d.isAfter(firstBirthday);
  }

  /// After the 365 days and before the archive closed ([closeDate] is
  /// exclusive, default [standardClose]): the "Bir Yaşındayım" chapter.
  bool isClosingWindow(DateTime date, {DateTime? closeDate}) {
    final d = Dates.dateOnly(date);
    return d.isAfter(end) && d.isBefore(Dates.dateOnly(closeDate ?? standardClose));
  }

  /// Everything that can appear in the official outputs: pregnancy, the 365
  /// days and the closing window up to the archive's close date.
  bool isBookCandidate(DateTime date, {DateTime? closeDate}) =>
      contains(date) || isPregnancy(date) || isClosingWindow(date, closeDate: closeDate);

  bool isComplete(DateTime today) => Dates.dateOnly(today).isAfter(end);

  /// 0.0 … 1.0 progress through the first year.
  double progress(DateTime today) {
    final n = dayNumber(today);
    if (n == null) return 0;
    return (n / lengthInDays).clamp(0.0, 1.0);
  }

  int daysRemaining(DateTime today) {
    final r = Dates.daysBetween(today, end);
    return r < 0 ? 0 : r;
  }

  /// 1…12 – which "N. Ayım" chapter a first-year date belongs to.
  /// Month N starts on birth date + (N-1) calendar months; days after the
  /// 12th month-iversary but still inside the 365 days belong to month 12.
  int? monthIndex(DateTime date) {
    if (!contains(date)) return null;
    var m = 1;
    while (m < 12 && !Dates.dateOnly(date).isBefore(Dates.addMonths(start, m))) {
      m++;
    }
    return m;
  }

  /// Inclusive date range of month chapter [index] (1…12).
  (DateTime, DateTime) monthRange(int index) {
    assert(index >= 1 && index <= 12);
    final from = Dates.addMonths(start, index - 1);
    final to = index == 12 ? end : Dates.addDays(Dates.addMonths(start, index), -1);
    return (from, to);
  }
}
