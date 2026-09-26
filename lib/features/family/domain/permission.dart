/// Mirrors the `public.permissions` catalog. The backend (RLS) is the
/// source of truth; the app only uses these to hide actions the user cannot
/// perform anyway.
enum AppPermission {
  viewMemories('view_memories', 'Anıları görüntüleyebilir'),
  viewAlbum('view_album', 'Albümü görüntüleyebilir'),
  addMemory('add_memory', 'Anı ekleyebilir'),
  editOwnMemory('edit_own_memory', 'Kendi anısını düzenleyebilir'),
  addPhoto('add_photo', 'Fotoğraf ekleyebilir'),
  addVideo('add_video', 'Video ekleyebilir'),
  comment('comment', 'Yorum / aile notu yazabilir'),
  addMilestone('add_milestone', 'Kilometre taşı ekleyebilir'),
  writeLetter('write_letter', 'Bebeğe mektup yazabilir'),
  createBook('create_book', 'Kitap oluşturabilir'),
  inviteMembers('invite_members', 'Aile üyesi davet edebilir'),
  manageMembers('manage_members', 'Aile üyelerini yönetebilir'),
  manageContent('manage_content', 'Tüm içerikleri yönetebilir'),
  manageBaby('manage_baby', 'Bebek profilini düzenleyebilir');

  const AppPermission(this.key, this.label);

  final String key;
  final String label;

  static AppPermission? fromKey(String key) {
    for (final p in values) {
      if (p.key == key) return p;
    }
    return null;
  }

  static Set<AppPermission> parse(Iterable<dynamic>? keys) =>
      {for (final k in keys ?? const []) ?AppPermission.fromKey(k.toString())};

  /// Permissions only an admin may hand out.
  bool get isManagement =>
      this == manageMembers || this == manageContent || this == manageBaby || this == inviteMembers;
}

/// What the current user may do for one baby.
class MemberAccess {
  const MemberAccess({required this.isAdmin, required this.permissions, required this.userId});

  static const none = MemberAccess(isAdmin: false, permissions: {}, userId: '');

  final bool isAdmin;
  final Set<AppPermission> permissions;
  final String userId;

  bool can(AppPermission p) => isAdmin || permissions.contains(p);

  /// Same rule as the RLS UPDATE/DELETE policies on memories/milestones.
  bool canEditContent(String? authorId) =>
      can(AppPermission.manageContent) ||
      (authorId != null && authorId == userId && can(AppPermission.editOwnMemory));

  /// Media: the uploader or content managers.
  bool canEditMedia(String? uploaderId) =>
      can(AppPermission.manageContent) || (uploaderId != null && uploaderId == userId);

  bool canEditLetter(String? authorId) => authorId != null && authorId == userId;

  bool canDeleteLetter(String? authorId) =>
      canEditLetter(authorId) || can(AppPermission.manageContent);

  bool get canCreateAnything =>
      can(AppPermission.addMemory) ||
      can(AppPermission.addPhoto) ||
      can(AppPermission.addVideo) ||
      can(AppPermission.addMilestone) ||
      can(AppPermission.writeLetter);
}
