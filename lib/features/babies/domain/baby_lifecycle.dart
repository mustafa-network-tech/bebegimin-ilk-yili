import '../../../core/utils/dates.dart';

enum BabyLifecycleStatus { active, locked }

enum BabyExtensionStatus { pending, approved, rejected, expired }

class BabyLifecycle {
  const BabyLifecycle({
    required this.babyId,
    required this.status,
    required this.businessDate,
    required this.baseCloseDate,
    required this.effectiveCloseDate,
    required this.remainingDays,
    required this.extensionStatus,
    required this.approvedExtensionDays,
    required this.canRequestExtension,
  });

  factory BabyLifecycle.fromJson(Map<String, dynamic> json) => BabyLifecycle(
    babyId: json['baby_id'] as String,
    status: switch (json['status'] as String) {
      'ACTIVE' => BabyLifecycleStatus.active,
      'LOCKED' => BabyLifecycleStatus.locked,
      final value => throw FormatException('Unknown lifecycle status: $value'),
    },
    businessDate: Dates.fromSql(json['business_date'] as String),
    baseCloseDate: Dates.fromSql(json['base_close_date'] as String),
    effectiveCloseDate: Dates.fromSql(json['effective_close_date'] as String),
    remainingDays: (json['remaining_days'] as num).toInt(),
    extensionStatus: switch (json['extension_status'] as String?) {
      null => null,
      'pending' => BabyExtensionStatus.pending,
      'approved' => BabyExtensionStatus.approved,
      'rejected' => BabyExtensionStatus.rejected,
      'expired' => BabyExtensionStatus.expired,
      final value => throw FormatException('Unknown extension status: $value'),
    },
    approvedExtensionDays: (json['approved_extension_days'] as num).toInt(),
    canRequestExtension: json['can_request_extension'] as bool,
  );

  final String babyId;
  final BabyLifecycleStatus status;
  final DateTime businessDate;
  final DateTime baseCloseDate;
  final DateTime effectiveCloseDate;
  final int remainingDays;
  final BabyExtensionStatus? extensionStatus;
  final int approvedExtensionDays;
  final bool canRequestExtension;

  bool get isActive => status == BabyLifecycleStatus.active;
  bool get isLocked => status == BabyLifecycleStatus.locked;

  /// Days of the extension that are already part of [effectiveCloseDate].
  bool get hasApprovedExtension => approvedExtensionDays > 0;

  Map<String, dynamic> toJson() => {
    'baby_id': babyId,
    'status': isActive ? 'ACTIVE' : 'LOCKED',
    'business_date': Dates.toSql(businessDate),
    'base_close_date': Dates.toSql(baseCloseDate),
    'effective_close_date': Dates.toSql(effectiveCloseDate),
    'remaining_days': remainingDays,
    'extension_status': extensionStatus?.name,
    'approved_extension_days': approvedExtensionDays,
    'can_request_extension': canRequestExtension,
  };

  /// Product business time zone is Europe/Istanbul (permanently UTC+3).
  static const istanbulOffset = Duration(hours: 3);

  /// Istanbul calendar date for an instant.
  static DateTime istanbulDate(DateTime instant) => Dates.dateOnly(instant.toUtc().add(istanbulOffset));

  /// Time until the next Istanbul midnight, when the lifecycle may flip.
  static Duration untilNextBusinessDay(DateTime instant) {
    final local = instant.toUtc().add(istanbulOffset);
    final nextMidnight = DateTime.utc(local.year, local.month, local.day + 1);
    return nextMidnight.difference(local);
  }

  /// The server is the only source that can make a profile ACTIVE. A cached
  /// or long-lived summary may only be *tightened*: once the device clock has
  /// passed the close date the profile is treated as LOCKED until the server
  /// is asked again. The device clock can never unlock a profile.
  BabyLifecycle tightenedFor(DateTime instant) {
    final today = istanbulDate(instant);
    if (isLocked || today.isBefore(effectiveCloseDate)) {
      final remaining = effectiveCloseDate.difference(today).inDays;
      if (isLocked || remaining >= remainingDays) return this;
      return _copy(remainingDays: remaining, canRequestExtension: canRequestExtension && today.isBefore(baseCloseDate));
    }
    return _copy(status: BabyLifecycleStatus.locked, remainingDays: 0, canRequestExtension: false);
  }

  BabyLifecycle _copy({BabyLifecycleStatus? status, int? remainingDays, bool? canRequestExtension}) => BabyLifecycle(
    babyId: babyId,
    status: status ?? this.status,
    businessDate: businessDate,
    baseCloseDate: baseCloseDate,
    effectiveCloseDate: effectiveCloseDate,
    remainingDays: remainingDays ?? this.remainingDays,
    extensionStatus: extensionStatus,
    approvedExtensionDays: approvedExtensionDays,
    canRequestExtension: canRequestExtension ?? this.canRequestExtension,
  );
}
