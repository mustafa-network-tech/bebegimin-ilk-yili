import '../../../app/env.dart';
import 'permission.dart';
import 'relation.dart';

enum InvitationStatus { pending, accepted, revoked, expired }

class Invitation {
  const Invitation({
    required this.id,
    required this.babyId,
    required this.code,
    required this.relation,
    required this.relationLabel,
    required this.isAdmin,
    required this.permissions,
    required this.invitedEmail,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
  });

  factory Invitation.fromJson(Map<String, dynamic> j) => Invitation(
    id: j['id'] as String,
    babyId: j['baby_id'] as String,
    code: j['code'] as String,
    relation: Relation.fromKey(j['relation'] as String?),
    relationLabel: j['relation_label'] as String?,
    isAdmin: j['is_admin'] as bool? ?? false,
    permissions: AppPermission.parse(j['permissions'] as List?),
    invitedEmail: j['invited_email'] as String?,
    status: InvitationStatus.values.byName(j['status'] as String),
    expiresAt: DateTime.parse(j['expires_at'] as String),
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String babyId;
  final String code;
  final Relation relation;
  final String? relationLabel;
  final bool isAdmin;
  final Set<AppPermission> permissions;
  final String? invitedEmail;
  final InvitationStatus status;
  final DateTime expiresAt;
  final DateTime createdAt;

  /// A pending invitation past its expiry is effectively expired even if
  /// the nightly job has not updated the row yet.
  InvitationStatus effectiveStatus(DateTime now) =>
      status == InvitationStatus.pending && !expiresAt.isAfter(now) ? InvitationStatus.expired : status;

  bool isUsable(DateTime now) => effectiveStatus(now) == InvitationStatus.pending;

  String get link => InviteCode.link(code);
}

/// Invitation code rules (mirrors the SQL CHECK constraint).
abstract final class InviteCode {
  static const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const length = 10;
  static final _valid = RegExp(r'^[A-HJ-NP-Z2-9]{10}$');

  /// Normalises user input: trims, upper-cases, removes spaces/dashes and
  /// maps look-alike characters (O→0 is not in the alphabet, so O stays
  /// invalid rather than silently becoming something else).
  static String normalize(String input) =>
      input.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]'), '');

  static bool isValid(String input) => _valid.hasMatch(normalize(input));

  /// "DEDE2-DAVET" style for display.
  static String pretty(String code) =>
      code.length == length ? '${code.substring(0, 5)}-${code.substring(5)}' : code;

  static String link(String code, {String? base}) {
    final b = (base ?? Env.inviteLinkBase).replaceAll(RegExp(r'/+$'), '');
    return '$b/$code';
  }

  /// Extracts a code from a shared link or raw text:
  ///   bebegimin://invite/ABCDE23456, https://x.app/davet/ABCDE23456,
  ///   ...?code=ABCDE23456, or the bare code.
  static String? parse(String? text) {
    if (text == null) return null;
    final t = text.trim();
    final uri = Uri.tryParse(t);
    if (uri != null && (uri.hasScheme || t.contains('/'))) {
      final q = uri.queryParameters['code'];
      if (q != null && isValid(q)) return normalize(q);
      for (final seg in uri.pathSegments.reversed) {
        if (isValid(seg)) return normalize(seg);
      }
      if (uri.host.isNotEmpty && isValid(uri.host)) return normalize(uri.host);
      return null;
    }
    return isValid(t) ? normalize(t) : null;
  }
}

class InvitationPreview {
  const InvitationPreview({
    required this.babyFirstName,
    required this.relation,
    required this.relationLabel,
    required this.inviterName,
    required this.expiresAt,
    required this.alreadyMember,
  });

  factory InvitationPreview.fromJson(Map<String, dynamic> j) => InvitationPreview(
    babyFirstName: j['baby_first_name'] as String,
    relation: Relation.fromKey(j['relation'] as String?),
    relationLabel: j['relation_label'] as String?,
    inviterName: j['inviter_name'] as String,
    expiresAt: DateTime.parse(j['expires_at'] as String),
    alreadyMember: j['already_member'] as bool? ?? false,
  );

  final String babyFirstName;
  final Relation relation;
  final String? relationLabel;
  final String inviterName;
  final DateTime expiresAt;
  final bool alreadyMember;
}
