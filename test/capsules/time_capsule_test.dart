import 'package:bebegimin_ilk_yili/features/capsules/domain/time_capsule.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  TimeCapsule capsule(DateTime openOn, {String? body}) => TimeCapsule.fromJson({
    'id': 'c1',
    'baby_id': 'b1',
    'author_id': 'u',
    'author_name': 'Elif',
    'author_relation': 'anne',
    'title': '18. yaş gününde aç',
    'occasion': 'age_18',
    'open_on': '${openOn.year}-${openOn.month.toString().padLeft(2, '0')}-${openOn.day.toString().padLeft(2, '0')}',
    'has_photo': true,
    'created_at': '2025-09-20T10:00:00Z',
    'time_capsule_contents': body == null ? null : {'body': body},
  });

  test('occasion open dates follow the birth date', () {
    expect(CapsuleOccasion.age18.openDateFor(d(2025, 9, 12)), d(2043, 9, 12));
    expect(CapsuleOccasion.age5.openDateFor(d(2024, 2, 29)), d(2029, 2, 28));
    expect(CapsuleOccasion.custom.openDateFor(d(2025, 9, 12)), isNull);
  });

  test('sealed capsule has no body (backend does not return it)', () {
    final c = capsule(d(2043, 9, 12));
    expect(c.isOpen(d(2026, 9, 26)), isFalse);
    expect(c.body, isNull);
    expect(c.remainingLabel(d(2026, 9, 26)), '16 yıl 11 ay sonra açılacak');
    expect(c.photoPath, 'b1/capsules/c1/photo.jpg');
    expect(c.signature, 'Annesi Elif');
  });

  test('opened capsule', () {
    final c = capsule(d(2026, 9, 12), body: 'Merhaba');
    expect(c.isOpen(d(2026, 9, 12)), isTrue);
    expect(c.body, 'Merhaba');
    expect(c.remainingLabel(d(2026, 9, 26)), 'Açıldı');
    expect(capsule(d(2026, 10, 5)).remainingLabel(d(2026, 9, 26)), '9 gün sonra açılacak');
  });
}
