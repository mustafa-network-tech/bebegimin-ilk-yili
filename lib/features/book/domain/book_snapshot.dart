import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../babies/domain/baby.dart';
import '../../family/domain/family_member.dart';
import '../../family/domain/permission.dart';
import '../../family/domain/relation.dart';
import '../../letters/domain/letter.dart';
import '../../media/domain/media_item.dart';
import '../../memories/domain/memory.dart';
import '../../milestones/domain/milestone.dart';
import 'book_composer.dart';
import 'book_models.dart';

/// The sealed archive snapshot or the frozen manifest did not match the
/// checksum the server sealed it with.
class BookIntegrityException implements Exception {
  const BookIntegrityException(this.part);

  final String part;

  @override
  String toString() => 'BookIntegrityException($part)';
}

/// Snapshot + manifest texts of a leased render job, exactly as sealed.
class BookRenderPayload {
  const BookRenderPayload({
    required this.snapshotContent,
    required this.snapshotChecksum,
    required this.manifestContent,
    required this.manifestChecksum,
  });

  factory BookRenderPayload.fromJson(Map<String, dynamic> j) => BookRenderPayload(
    snapshotContent: j['snapshot_content'] as String,
    snapshotChecksum: j['snapshot_checksum'] as String,
    manifestContent: j['manifest_content'] as String,
    manifestChecksum: j['manifest_checksum'] as String,
  );

  final String snapshotContent;
  final String snapshotChecksum;
  final String manifestContent;
  final String manifestChecksum;
}

/// Everything the existing book engine needs, decoded from a sealed
/// snapshot (content) and a frozen manifest (configuration).
class BookRenderInputs {
  const BookRenderInputs({required this.project, required this.source, required this.members});

  /// Verifies both checksums before anything is decoded.
  factory BookRenderInputs.fromPayload(BookRenderPayload payload) {
    if (sha256Hex(payload.snapshotContent) != payload.snapshotChecksum) {
      throw const BookIntegrityException('snapshot');
    }
    if (sha256Hex(payload.manifestContent) != payload.manifestChecksum) {
      throw const BookIntegrityException('manifest');
    }
    final snapshot = jsonDecode(payload.snapshotContent) as Map<String, dynamic>;
    final manifest = jsonDecode(payload.manifestContent) as Map<String, dynamic>;
    final project = BookProject.fromJson(manifest);
    final decoded = BookSnapshotDecoder.decode(snapshot);
    if (decoded.source.baby.id != project.babyId) throw const BookIntegrityException('baby');
    return BookRenderInputs(project: project, source: decoded.source, members: decoded.members);
  }

  final BookProject project;
  final BookSource source;
  final List<FamilyMember> members;
}

String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// Maps the canonical snapshot JSON (schema version 1) onto the app's domain
/// models. Author names and relations come from the snapshot, never from the
/// live profiles. Per-user favourites are not part of a snapshot.
abstract final class BookSnapshotDecoder {
  /// Snapshot rows carry no creation timestamps; the engine does not use them.
  static final _epoch = DateTime.utc(1970).toIso8601String();

  static ({BookSource source, List<FamilyMember> members}) decode(Map<String, dynamic> content) {
    final version = (content['schema_version'] as num?)?.toInt();
    if (version != 1) throw const BookIntegrityException('schema_version');
    final baby = Baby.fromJson((content['baby'] as Map).cast<String, dynamic>());
    final babyId = baby.id;

    final people = <String, FamilyMember>{};
    void person(Object? raw, {bool member = false}) {
      if (raw is! Map) return;
      final userId = raw['user_id'] as String?;
      if (userId == null || (!member && people.containsKey(userId))) return;
      people[userId] = FamilyMember(
        id: 'snapshot:$userId',
        babyId: babyId,
        userId: userId,
        relation: Relation.fromKey(raw['relation'] as String?),
        relationLabel: raw['relation_label'] as String?,
        isAdmin: false,
        permissions: const <AppPermission>{},
        joinedAt: DateTime.utc(1970),
        displayName: (raw['name'] as String?) ?? '',
        avatarPath: null,
      );
    }

    List<Map<String, dynamic>> rows(String key) =>
        ((content[key] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

    for (final m in rows('members')) {
      person(m, member: true);
    }

    final memories = [
      for (final m in rows('memories'))
        Memory.fromJson({
          ...m,
          'baby_id': babyId,
          'author_id': (m['author'] as Map?)?['user_id'],
          'created_at': _epoch,
        }),
    ];
    for (final m in rows('memories')) {
      person(m['author']);
    }

    final types = <String, MilestoneType>{};
    final milestones = <Milestone>[];
    for (final m in rows('milestones')) {
      // Snapshot milestones embed their type; each gets a private type id.
      final typeId = 'snapshot-type:${m['id']}';
      types[typeId] = MilestoneType(
        id: typeId,
        key: m['type_key'] as String?,
        babyId: null,
        title: (m['title'] as String?) ?? 'İlk',
        emoji: m['emoji'] as String?,
        sortOrder: 0,
        createdBy: null,
      );
      milestones.add(
        Milestone.fromJson({
          ...m,
          'baby_id': babyId,
          'milestone_type_id': typeId,
          'created_by': (m['author'] as Map?)?['user_id'],
          'created_at': _epoch,
        }),
      );
    }

    final letters = [
      for (final l in rows('letters'))
        Letter.fromJson({
          ...l,
          'baby_id': babyId,
          'author_id': (l['author'] as Map?)?['user_id'],
          'author_name': (l['author'] as Map?)?['name'] ?? '',
          'author_relation': (l['author'] as Map?)?['relation'],
          'author_relation_label': (l['author'] as Map?)?['relation_label'],
          'created_at': _epoch,
        }),
    ];

    final media = [
      for (final m in rows('media'))
        MediaItem.fromJson({
          ...m,
          'baby_id': babyId,
          'uploader_id': (m['uploader'] as Map?)?['user_id'],
          'status': 'ready',
          'created_at': _epoch,
        }),
    ];

    return (
      source: BookSource(
        baby: baby,
        memories: memories,
        media: media,
        milestones: milestones,
        milestoneTypes: types,
        letters: letters,
      ),
      members: people.values.toList(),
    );
  }
}
