import 'package:bebegimin_ilk_yili/features/babies/domain/baby.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  test('next month-iversaries and first-year completion', () {
    final list = upcomingDays(defne, d(2026, 3, 1), limit: 3);
    expect(list.first.date, d(2026, 3, 12));
    expect(list.first.title, '6. ay dönümü');
    expect(list.map((e) => e.kind), contains(UpcomingKind.monthiversary));
  });

  test('after the first year: first-year reminder disappears, birthdays remain', () {
    final list = upcomingDays(defne, d(2027, 10, 1), limit: 2);
    expect(list.any((e) => e.kind == UpcomingKind.firstYearComplete), isFalse);
    expect(list.first.title, '3. yaş günü 🎂');
    expect(list.first.date, d(2028, 9, 12));
  });

  test('baby helpers', () {
    expect(defne.fullName, 'Defne Yılmaz');
    expect(defne.birthWeightLabel, '3,25 kg');
    expect(defne.birthLengthLabel, '50,5 cm');
    expect(defne.ageOn(d(2025, 9, 30))!.label, '18 günlük');
  });
}
