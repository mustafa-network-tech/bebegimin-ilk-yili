import 'package:intl/intl.dart';

/// Calendar-date helpers. All archive dates are *calendar dates* (no time
/// zone), so we normalise every [DateTime] to a UTC midnight value before
/// doing arithmetic – this avoids DST off-by-one errors.
abstract final class Dates {
  static DateTime dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  static DateTime today([DateTime? now]) => dateOnly(now ?? DateTime.now());

  /// Whole days from [from] to [to] (calendar based, DST safe).
  static int daysBetween(DateTime from, DateTime to) =>
      dateOnly(to).difference(dateOnly(from)).inDays;

  static DateTime addDays(DateTime d, int days) {
    final base = dateOnly(d);
    return DateTime.utc(base.year, base.month, base.day + days);
  }

  static int daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  /// Adds calendar months, clamping the day to the end of the target month
  /// (31 Jan + 1 month = 28/29 Feb), the same rule PostgreSQL uses.
  static DateTime addMonths(DateTime d, int months) {
    final totalMonths = d.year * 12 + (d.month - 1) + months;
    final year = totalMonths ~/ 12;
    final month = totalMonths % 12 + 1;
    final day = d.day.clamp(1, daysInMonth(year, month));
    return DateTime.utc(year, month, day);
  }

  static DateTime addYears(DateTime d, int years) => addMonths(d, years * 12);

  /// ISO `yyyy-MM-dd` used by PostgreSQL `date` columns.
  static String toSql(DateTime d) {
    final x = dateOnly(d);
    return '${x.year.toString().padLeft(4, '0')}-'
        '${x.month.toString().padLeft(2, '0')}-'
        '${x.day.toString().padLeft(2, '0')}';
  }

  static DateTime fromSql(String s) {
    final p = s.split('-');
    return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2].substring(0, 2)));
  }

  static DateTime? tryFromSql(Object? s) =>
      s is String && s.length >= 10 ? fromSql(s) : null;

  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // Formatting (Turkish) ---------------------------------------------------
  static final _long = DateFormat('d MMMM y', 'tr_TR');
  static final _longWeekday = DateFormat('d MMMM y, EEEE', 'tr_TR');
  static final _short = DateFormat('d MMM y', 'tr_TR');
  static final _monthYear = DateFormat('MMMM y', 'tr_TR');
  static final _dayMonth = DateFormat('d MMMM', 'tr_TR');
  static final _weekday = DateFormat('EEEE', 'tr_TR');

  static String long(DateTime d) => _long.format(d);
  static String longWithWeekday(DateTime d) => _longWeekday.format(d);
  static String short(DateTime d) => _short.format(d);
  static String monthYear(DateTime d) => _monthYear.format(d);
  static String dayMonth(DateTime d) => _dayMonth.format(d);
  static String weekday(DateTime d) => _weekday.format(d);

  /// "14:05" from a PostgreSQL `time` value ("14:05:00").
  static String? timeLabel(String? sqlTime) =>
      sqlTime == null || sqlTime.length < 5 ? null : sqlTime.substring(0, 5);

  static String relativeDays(int days) {
    if (days == 0) return 'bugün';
    if (days == 1) return 'yarın';
    if (days == -1) return 'dün';
    if (days > 0) return '$days gün sonra';
    return '${-days} gün önce';
  }
}
