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
}
