import 'package:bebegimin_ilk_yili/features/family/domain/family_member.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/permission.dart';
import 'package:bebegimin_ilk_yili/features/family/domain/relation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const teyze = MemberAccess(
    isAdmin: false,
    userId: 'teyze',
    permissions: {
      AppPermission.viewMemories,
      AppPermission.viewAlbum,
      AppPermission.addMemory,
      AppPermission.editOwnMemory,
      AppPermission.addPhoto,
    },
  );
  const anne = MemberAccess(isAdmin: true, userId: 'anne', permissions: {});

  test('admins implicitly hold every permission (same as has_baby_permission)', () {
    for (final p in AppPermission.values) {
      expect(anne.can(p), isTrue, reason: p.key);
    }
  });

  test('granular permissions are not derived from the relation name', () {
    expect(teyze.can(AppPermission.addMemory), isTrue);
    expect(teyze.can(AppPermission.addVideo), isFalse);
    expect(teyze.can(AppPermission.addMilestone), isFalse);
    expect(teyze.can(AppPermission.createBook), isFalse);
    expect(teyze.can(AppPermission.inviteMembers), isFalse);
    expect(teyze.can(AppPermission.manageMembers), isFalse);
  });

  test('content editing mirrors the RLS policies', () {
    expect(teyze.canEditContent('teyze'), isTrue);
    expect(teyze.canEditContent('anne'), isFalse);
    expect(teyze.canEditContent(null), isFalse);
    expect(anne.canEditContent('teyze'), isTrue);
    const noEdit = MemberAccess(isAdmin: false, userId: 'x', permissions: {AppPermission.addMemory});
    expect(noEdit.canEditContent('x'), isFalse);
    expect(teyze.canEditMedia('teyze'), isTrue);
    expect(teyze.canEditMedia('anne'), isFalse);
    expect(teyze.canDeleteLetter('anne'), isFalse);
    expect(anne.canDeleteLetter('teyze'), isTrue);
    expect(anne.canEditLetter('teyze'), isFalse, reason: 'letters are personal: only the author edits');
  });

  test('permission keys match the database catalog', () {
    expect(AppPermission.values.map((p) => p.key).toSet(), {
      'view_memories', 'view_album', 'add_memory', 'edit_own_memory', 'add_photo', 'add_video',
      'comment', 'add_milestone', 'write_letter', 'create_book', 'invite_members',
      'manage_members', 'manage_content', 'manage_baby',
    });
    expect(AppPermission.parse(['add_memory', 'unknown', 'view_album']),
        {AppPermission.addMemory, AppPermission.viewAlbum});
  });

  test('relation presets', () {
    expect(Relation.anne.defaultAdmin, isTrue);
    expect(Relation.teyze.defaultAdmin, isFalse);
    expect(Relation.teyze.defaultPermissions.contains(AppPermission.manageMembers), isFalse);
    expect(Relation.diger.defaultPermissions, {AppPermission.viewMemories, AppPermission.viewAlbum, AppPermission.comment});
    expect(Relation.fromKey('dayi').label, 'Dayı');
    expect(Relation.fromKey('???'), Relation.diger);
  });

  test('member introduction texts', () {
    final m = FamilyMember.fromJson({
      'id': '1',
      'baby_id': 'b',
      'user_id': 'u',
      'relation': 'teyze',
      'relation_label': null,
      'is_admin': false,
      'permissions': ['view_memories'],
      'joined_at': '2026-01-01T10:00:00Z',
      'profiles': {'display_name': 'Zeynep', 'avatar_path': null},
    });
    expect(m.introduction, 'Teyzesi Zeynep');
    expect(m.relationName, 'Teyze');
    final custom = FamilyMember.fromJson({...m.toJson(), 'relation': 'diger', 'relation_label': 'Kuzeni'});
    expect(custom.introduction, 'Kuzeni Zeynep');
    expect(custom.access.can(AppPermission.viewMemories), isTrue);
  });
}
