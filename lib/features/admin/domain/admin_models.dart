import '../../../core/utils/dates.dart';

/// The caller's platform role as reported by the database. Never derived
/// from client-side claims.
class AdminSession {
  const AdminSession({required this.isSuperAdmin, required this.consoleEnabled});

  static const none = AdminSession(isSuperAdmin: false, consoleEnabled: false);

  factory AdminSession.fromJson(Map<String, dynamic> j) => AdminSession(
    isSuperAdmin: j['is_super_admin'] as bool? ?? false,
    consoleEnabled: j['console_enabled'] as bool? ?? false,
  );

  final bool isSuperAdmin;
  final bool consoleEnabled;

  bool get canUseConsole => isSuperAdmin && consoleEnabled;
}

/// One page of an admin list plus the total for "load more".
class AdminPage<T> {
  const AdminPage(this.items, this.total);

  final List<T> items;
  final int total;
}

enum ExtensionQueueFilter {
  pending('pending', 'Bekleyen'),
  decided('decided', 'Karara bağlanan'),
  expired('expired', 'Süresi dolan'),
  all('all', 'Tümü');

  const ExtensionQueueFilter(this.key, this.label);

  final String key;
  final String label;
}

enum ExtensionSla { urgent, soon, normal }

class AdminExtensionRequest {
  const AdminExtensionRequest({
    required this.requestId,
    required this.babyId,
    required this.babyFirstName,
    required this.requestedDays,
    required this.status,
    required this.requestedByName,
    required this.requestedAt,
    required this.baseCloseDate,
    required this.daysUntilBaseClose,
    required this.sla,
    required this.decidedByName,
    required this.decidedAt,
    required this.decisionNote,
  });

  factory AdminExtensionRequest.fromJson(Map<String, dynamic> j) => AdminExtensionRequest(
    requestId: j['request_id'] as String,
    babyId: j['baby_id'] as String,
    babyFirstName: j['baby_first_name'] as String,
    requestedDays: (j['requested_days'] as num).toInt(),
    status: j['status'] as String,
    requestedByName: j['requested_by_name'] as String? ?? 'Aile üyesi',
    requestedAt: DateTime.parse(j['requested_at'] as String),
    baseCloseDate: Dates.fromSql(j['base_close_date'] as String),
    daysUntilBaseClose: (j['days_until_base_close'] as num).toInt(),
    sla: switch (j['sla'] as String?) {
      'urgent' => ExtensionSla.urgent,
      'soon' => ExtensionSla.soon,
      'normal' => ExtensionSla.normal,
      _ => null,
    },
    decidedByName: j['decided_by_name'] as String?,
    decidedAt: j['decided_at'] == null ? null : DateTime.parse(j['decided_at'] as String),
    decisionNote: j['decision_note'] as String?,
  );

  final String requestId;
  final String babyId;
  final String babyFirstName;
  final int requestedDays;

  /// pending | approved | rejected | expired (a pending request past its base
  /// close is reported as expired).
  final String status;
  final String requestedByName;
  final DateTime requestedAt;
  final DateTime baseCloseDate;
  final int daysUntilBaseClose;
  final ExtensionSla? sla;
  final String? decidedByName;
  final DateTime? decidedAt;
  final String? decisionNote;

  bool get isPending => status == 'pending';

  String get statusLabel => switch (status) {
    'pending' => 'Bekliyor',
    'approved' => 'Onaylandı',
    'rejected' => 'Reddedildi',
    'expired' => 'Süresi doldu',
    _ => status,
  };
}

class AdminBabyResult {
  const AdminBabyResult({
    required this.babyId,
    required this.firstName,
    required this.birthDate,
    required this.isLocked,
    required this.baseCloseDate,
    required this.effectiveCloseDate,
    required this.approvedExtensionDays,
    required this.extensionStatus,
    required this.contentCount,
  });

  factory AdminBabyResult.fromJson(Map<String, dynamic> j) => AdminBabyResult(
    babyId: j['baby_id'] as String,
    firstName: j['first_name'] as String,
    birthDate: Dates.fromSql(j['birth_date'] as String),
    isLocked: j['status'] == 'LOCKED',
    baseCloseDate: Dates.fromSql(j['base_close_date'] as String),
    effectiveCloseDate: Dates.fromSql(j['effective_close_date'] as String),
    approvedExtensionDays: (j['approved_extension_days'] as num).toInt(),
    extensionStatus: j['extension_status'] as String?,
    contentCount: (j['content_count'] as num).toInt(),
  );

  final String babyId;
  final String firstName;
  final DateTime birthDate;
  final bool isLocked;
  final DateTime baseCloseDate;
  final DateTime effectiveCloseDate;
  final int approvedExtensionDays;
  final String? extensionStatus;
  final int contentCount;
}

class BirthDatePreview {
  const BirthDatePreview({
    required this.birthDateBefore,
    required this.birthDateAfter,
    required this.lockedBefore,
    required this.lockedAfter,
    required this.baseCloseBefore,
    required this.baseCloseAfter,
    required this.effectiveCloseBefore,
    required this.effectiveCloseAfter,
    required this.approvedExtensionDays,
    required this.wouldReopen,
    required this.wouldLock,
  });

  factory BirthDatePreview.fromJson(Map<String, dynamic> j) => BirthDatePreview(
    birthDateBefore: Dates.fromSql(j['birth_date_before'] as String),
    birthDateAfter: Dates.fromSql(j['birth_date_after'] as String),
    lockedBefore: j['status_before'] == 'LOCKED',
    lockedAfter: j['status_after'] == 'LOCKED',
    baseCloseBefore: Dates.fromSql(j['base_close_before'] as String),
    baseCloseAfter: Dates.fromSql(j['base_close_after'] as String),
    effectiveCloseBefore: Dates.fromSql(j['effective_close_before'] as String),
    effectiveCloseAfter: Dates.fromSql(j['effective_close_after'] as String),
    approvedExtensionDays: (j['approved_extension_days'] as num).toInt(),
    wouldReopen: j['would_reopen'] as bool,
    wouldLock: j['would_lock'] as bool,
  );

  final DateTime birthDateBefore;
  final DateTime birthDateAfter;
  final bool lockedBefore;
  final bool lockedAfter;
  final DateTime baseCloseBefore;
  final DateTime baseCloseAfter;
  final DateTime effectiveCloseBefore;
  final DateTime effectiveCloseAfter;
  final int approvedExtensionDays;
  final bool wouldReopen;
  final bool wouldLock;
}

enum AdminAuditAction {
  extensionRequested('extension_requested', 'Uzatma talebi'),
  extensionApproved('extension_approved', 'Uzatma onayı'),
  extensionRejected('extension_rejected', 'Uzatma reddi'),
  extensionExpired('extension_expired', 'Uzatma süresi doldu'),
  birthDateCorrected('birth_date_corrected', 'Doğum tarihi düzeltmesi'),
  lifecycleReopened('lifecycle_reopened', 'Profil yeniden açıldı'),
  profileLocked('profile_locked', 'Profil kilitlendi'),
  uploadQuarantined('upload_quarantined', 'Yükleme karantinaya alındı');

  const AdminAuditAction(this.key, this.label);

  final String key;
  final String label;

  static AdminAuditAction? fromKey(String key) {
    for (final a in values) {
      if (a.key == key) return a;
    }
    return null;
  }
}

class AdminAuditEntry {
  const AdminAuditEntry({
    required this.id,
    required this.createdAt,
    required this.action,
    required this.actionKey,
    required this.babyId,
    required this.babyFirstName,
    required this.actorName,
    required this.details,
  });

  factory AdminAuditEntry.fromJson(Map<String, dynamic> j) => AdminAuditEntry(
    id: (j['id'] as num).toInt(),
    createdAt: DateTime.parse(j['created_at'] as String),
    action: AdminAuditAction.fromKey(j['action'] as String),
    actionKey: j['action'] as String,
    babyId: j['baby_id'] as String,
    babyFirstName: j['baby_first_name'] as String,
    actorName: j['actor_name'] as String,
    details: ((j['details'] as Map?) ?? const {}).cast<String, dynamic>(),
  );

  final int id;
  final DateTime createdAt;
  final AdminAuditAction? action;
  final String actionKey;
  final String babyId;
  final String babyFirstName;
  final String actorName;
  final Map<String, dynamic> details;

  String get label => action?.label ?? actionKey;

  /// Short, allow-listed summary of the details.
  String get summary {
    final parts = <String>[
      if (details['requested_days'] != null) '${details['requested_days']} gün',
      if (details['birth_date_before'] != null && details['birth_date_after'] != null)
        '${Dates.short(Dates.fromSql(details['birth_date_before'] as String))} → '
            '${Dates.short(Dates.fromSql(details['birth_date_after'] as String))}',
      if (details['effective_close_date'] != null)
        'kapanış ${Dates.short(Dates.fromSql(details['effective_close_date'] as String))}',
      if ((details['reason'] as String?)?.isNotEmpty ?? false) 'Gerekçe: ${details['reason']}',
      if ((details['note'] as String?)?.isNotEmpty ?? false) 'Not: ${details['note']}',
    ];
    return parts.join(' · ');
  }
}
