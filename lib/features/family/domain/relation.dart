import 'permission.dart';

/// Relationship to the baby (relative to *that* baby).
enum Relation {
  anne('anne', 'Anne', 'Annesi'),
  baba('baba', 'Baba', 'Babası'),
  abla('abla', 'Abla', 'Ablası'),
  abi('abi', 'Abi', 'Abisi'),
  teyze('teyze', 'Teyze', 'Teyzesi'),
  hala('hala', 'Hala', 'Halası'),
  dayi('dayi', 'Dayı', 'Dayısı'),
  amca('amca', 'Amca', 'Amcası'),
  anneanne('anneanne', 'Anneanne', 'Anneannesi'),
  babaanne('babaanne', 'Babaanne', 'Babaannesi'),
  dede('dede', 'Dede', 'Dedesi'),
  diger('diger', 'Diğer yakın', 'Bir yakını');

  const Relation(this.key, this.label, this.possessive);

  final String key;
  final String label;

  /// "Teyzesi", used in sentences: "Teyzesi Zeynep yeni bir anı ekledi".
  final String possessive;

  static Relation fromKey(String? key) => values.firstWhere((r) => r.key == key, orElse: () => Relation.diger);

  bool get isParent => this == anne || this == baba;

  /// Suggested defaults when inviting someone with this relation.
  Set<AppPermission> get defaultPermissions => switch (this) {
    anne || baba => AppPermission.values.toSet(),
    abla || abi => {
      AppPermission.viewMemories,
      AppPermission.viewAlbum,
      AppPermission.addMemory,
      AppPermission.editOwnMemory,
      AppPermission.addPhoto,
      AppPermission.comment,
      AppPermission.writeLetter,
    },
    anneanne || babaanne || dede => {
      AppPermission.viewMemories,
      AppPermission.viewAlbum,
      AppPermission.addMemory,
      AppPermission.editOwnMemory,
      AppPermission.addPhoto,
      AppPermission.addVideo,
      AppPermission.comment,
      AppPermission.writeLetter,
    },
    teyze || hala || dayi || amca => {
      AppPermission.viewMemories,
      AppPermission.viewAlbum,
      AppPermission.addMemory,
      AppPermission.editOwnMemory,
      AppPermission.addPhoto,
      AppPermission.addVideo,
      AppPermission.comment,
      AppPermission.writeLetter,
    },
    diger => {AppPermission.viewMemories, AppPermission.viewAlbum, AppPermission.comment},
  };

  bool get defaultAdmin => isParent;
}

/// Display text for a relation with an optional custom label ("Kuzen").
String relationText(Relation r, String? customLabel) =>
    (customLabel != null && customLabel.trim().isNotEmpty) ? customLabel.trim() : r.label;

String relationPossessive(Relation r, String? customLabel) =>
    (customLabel != null && customLabel.trim().isNotEmpty) ? customLabel.trim() : r.possessive;
