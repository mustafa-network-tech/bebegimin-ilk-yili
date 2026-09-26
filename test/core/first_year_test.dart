import 'package:bebegimin_ilk_yili/core/utils/dates.dart';
import 'package:bebegimin_ilk_yili/core/utils/first_year.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  final fy = FirstYearPeriod(d(2025, 9, 12));

  test('covers exactly 365 days starting with the birth date', () {
    expect(fy.start, d(2025, 9, 12));
    expect(fy.end, d(2026, 9, 11));
    expect(fy.dayNumber(fy.start), 1);
    expect(fy.dayNumber(fy.end), 365);
    expect(fy.contains(d(2026, 9, 11)), isTrue);
    expect(fy.contains(d(2026, 9, 12)), isFalse);
    expect(fy.contains(d(2025, 9, 11)), isFalse);
    expect(fy.firstBirthday, d(2026, 9, 12));
  });

  test('leap year: 365 days end one day before the first birthday', () {
    final leap = FirstYearPeriod(d(2027, 3, 1)); // spans 29 Feb 2028
    expect(leap.end, d(2028, 2, 28));
    expect(leap.firstBirthday, d(2028, 3, 1));
    expect(leap.dayNumber(leap.end), 365);
    expect(leap.contains(d(2028, 2, 29)), isFalse);
    expect(leap.isBookCandidate(d(2028, 2, 29)), isTrue); // not lost: "Bir Yaşındayım" chapter
    expect(leap.isBookCandidate(d(2028, 3, 1)), isTrue);
  });

  test('past-dated memory added later still belongs to the first year', () {
    // today the child is 2 years old, memory is dated when she was 11 months
    final memoryDate = Dates.addMonths(fy.start, 11);
    expect(fy.isComplete(d(2027, 10, 1)), isTrue);
    expect(fy.contains(memoryDate), isTrue);
    expect(fy.monthIndex(memoryDate), 12);
  });

  test('month chapters', () {
    expect(fy.monthIndex(d(2025, 9, 12)), 1);
    expect(fy.monthIndex(d(2025, 10, 11)), 1);
    expect(fy.monthIndex(d(2025, 10, 12)), 2);
    expect(fy.monthIndex(d(2026, 8, 12)), 12);
    expect(fy.monthIndex(d(2026, 9, 11)), 12);
    expect(fy.monthIndex(d(2026, 9, 12)), isNull);
    final (from, to) = fy.monthRange(3);
    expect(from, d(2025, 11, 12));
    expect(to, d(2025, 12, 11));
    expect(fy.monthRange(12).$2, fy.end);
  });

  test('every first-year day maps to exactly one month', () {
    for (var i = 0; i < 365; i++) {
      final day = Dates.addDays(fy.start, i);
      final m = fy.monthIndex(day)!;
      final (from, to) = fy.monthRange(m);
      expect(!day.isBefore(from) && !day.isAfter(to), isTrue, reason: '$day in month $m');
    }
  });

  test('pregnancy and birthday are book candidates, later dates are not', () {
    expect(fy.isPregnancy(d(2025, 8, 1)), isTrue);
    expect(fy.isBookCandidate(d(2025, 8, 1)), isTrue);
    expect(fy.isBookCandidate(d(2024, 8, 1)), isFalse);
    expect(fy.isBookCandidate(d(2026, 9, 12)), isTrue); // first birthday
    expect(fy.isBookCandidate(d(2026, 9, 13)), isFalse);
  });

  test('progress and remaining days', () {
    expect(fy.progress(d(2025, 9, 12)), closeTo(1 / 365, 1e-9));
    expect(fy.progress(d(2030, 1, 1)), 1.0);
    expect(fy.daysRemaining(d(2026, 9, 1)), 10);
    expect(fy.isComplete(d(2026, 9, 11)), isFalse);
    expect(fy.isComplete(d(2026, 9, 12)), isTrue);
  });
}
