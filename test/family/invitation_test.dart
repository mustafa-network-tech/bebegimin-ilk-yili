import 'package:bebegimin_ilk_yili/features/family/domain/invitation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InviteCode', () {
    test('normalises user input', () {
      expect(InviteCode.normalize(' dede2-davet '), 'DEDE2DAVET');
      expect(InviteCode.isValid('dede2 davet'), isTrue);
      expect(InviteCode.isValid('DEMO23DEDE'), isFalse, reason: 'O is not in the alphabet');
      expect(InviteCode.isValid('ABC'), isFalse);
      expect(InviteCode.isValid('ABCDEFGH10'), isFalse, reason: '1 and 0 are excluded');
    });

    test('alphabet has 32 unambiguous characters', () {
      expect(InviteCode.alphabet.length, 32);
      expect(InviteCode.alphabet.contains('O'), isFalse);
      expect(InviteCode.alphabet.contains('I'), isFalse);
      expect(InviteCode.alphabet.contains('0'), isFalse);
      expect(InviteCode.alphabet.contains('1'), isFalse);
    });

    test('parses links and raw codes', () {
      expect(InviteCode.parse('bebegimin://invite/DEDE2DAVET'), 'DEDE2DAVET');
      expect(InviteCode.parse('https://bebegimin.app/davet/dede2davet'), 'DEDE2DAVET');
      expect(InviteCode.parse('https://x.app/join?code=DEDE2DAVET'), 'DEDE2DAVET');
      expect(InviteCode.parse('DEDE2-DAVET'), 'DEDE2DAVET');
      expect(InviteCode.parse('https://evil.example/whatever'), isNull);
      expect(InviteCode.parse(null), isNull);
    });

    test('builds share links', () {
      expect(InviteCode.link('DEDE2DAVET', base: 'bebegimin://invite/'), 'bebegimin://invite/DEDE2DAVET');
      expect(InviteCode.pretty('DEDE2DAVET'), 'DEDE2-DAVET');
    });
  });

  group('Invitation status', () {
    Invitation inv(String status, DateTime expires) => Invitation.fromJson({
      'id': 'i',
      'baby_id': 'b',
      'code': 'DEDE2DAVET',
      'relation': 'dede',
      'relation_label': null,
      'is_admin': false,
      'permissions': ['view_memories', 'view_album'],
      'invited_email': null,
      'status': status,
      'expires_at': expires.toIso8601String(),
      'created_at': '2026-09-01T00:00:00Z',
    });

    final now = DateTime.utc(2026, 9, 26, 12);

    test('pending invitation past expiry is treated as expired', () {
      expect(inv('pending', now.subtract(const Duration(minutes: 1))).effectiveStatus(now), InvitationStatus.expired);
      expect(inv('pending', now.add(const Duration(days: 2))).isUsable(now), isTrue);
    });

    test('revoked / accepted invitations are never usable', () {
      expect(inv('revoked', now.add(const Duration(days: 2))).isUsable(now), isFalse);
      expect(inv('accepted', now.add(const Duration(days: 2))).isUsable(now), isFalse);
    });
  });
}
