import 'package:bebegimin_ilk_yili/core/utils/baby_age.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  String label(DateTime birth, DateTime on) => BabyAge.at(birth, on)!.label;

  group('BabyAge.label', () {
    test('birth day and first days', () {
      expect(label(d(2025, 9, 12), d(2025, 9, 12)), 'Bugün doğdu');
      expect(label(d(2025, 9, 12), d(2025, 9, 30)), '18 günlük');
    });

    test('months and days', () {
      expect(label(d(2025, 9, 12), d(2025, 12, 24)), '3 aylık 12 günlük');
      expect(label(d(2025, 9, 12), d(2026, 8, 12)), '11 aylık');
    });

    test('years', () {
      expect(label(d(2025, 9, 12), d(2026, 9, 12)), '1 yaşında');
      expect(label(d(2025, 9, 12), d(2027, 1, 20)), '1 yaş 4 aylık');
      expect(label(d(2025, 9, 12), d(2027, 9, 12)), '2 yaşında');
    });

    test('184 günlük example from the spec', () {
      final age = BabyAge.at(d(2025, 9, 12), d(2026, 3, 15))!;
      expect(age.totalDays, 184);
    });

    test('end of month births clamp like PostgreSQL', () {
      // born 31 Jan: 1 month old on 28 Feb (non-leap year)
      expect(BabyAge.at(d(2025, 1, 31), d(2025, 2, 28))!.totalMonths, 1);
      expect(BabyAge.at(d(2025, 1, 31), d(2025, 2, 27))!.totalMonths, 0);
      expect(label(d(2025, 1, 31), d(2025, 3, 31)), '2 aylık');
    });

    test('leap day birth', () {
      expect(label(d(2024, 2, 29), d(2025, 2, 28)), '1 yaşında');
      expect(BabyAge.at(d(2024, 2, 29), d(2025, 2, 27))!.years, 0);
    });

    test('before birth returns null (pregnancy)', () {
      expect(BabyAge.at(d(2025, 9, 12), d(2025, 9, 1)), isNull);
    });

    test('whileLabel for sentences', () {
      expect(BabyAge.at(d(2025, 9, 12), d(2025, 12, 24))!.whileLabel, '3 aylık 12 günlükken');
      expect(BabyAge.at(d(2025, 9, 12), d(2026, 9, 12))!.whileLabel, '1 yaşındayken');
      expect(BabyAge.at(d(2025, 9, 12), d(2025, 9, 12))!.whileLabel, 'doğduğu gün');
    });

    test('DST transitions do not shift days', () {
      // local DateTimes around the end of March (EU DST) are normalised
      final age = BabyAge.at(DateTime(2026, 3, 28, 23), DateTime(2026, 3, 30, 1))!;
      expect(age.totalDays, 2);
    });
  });

  group('AgePeriod', () {
    test('first year and later periods', () {
      final birth = d(2025, 9, 12);
      expect(AgePeriod.forDate(birth, d(2026, 9, 11))!.label, 'İlk Yılım');
      expect(AgePeriod.forDate(birth, d(2026, 9, 12))!.label, '1–2 yaş');
      expect(AgePeriod.forDate(birth, d(2028, 1, 1))!.label, '2–3 yaş');
      expect(AgePeriod.forDate(birth, d(2025, 1, 1)), isNull);
    });
  });
}
