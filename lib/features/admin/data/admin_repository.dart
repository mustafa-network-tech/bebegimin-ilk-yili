import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../domain/admin_models.dart';

final adminRepositoryProvider = Provider<AdminRepository>((ref) => AdminRepository(ref.watch(supabaseProvider)));

/// Super Admin console. Every call is re-authorised by the database
/// (platform role, console flag, rate limit); nothing here is trusted.
class AdminRepository {
  AdminRepository(this._client);

  final SupabaseClient _client;
  static const pageSize = 30;

  List<Map<String, dynamic>> _rows(Object? response) => [
    for (final row in (response as List? ?? const [])) (row as Map).cast<String, dynamic>(),
  ];

  AdminPage<T> _page<T>(List<Map<String, dynamic>> rows, T Function(Map<String, dynamic>) parse) =>
      AdminPage([for (final r in rows) parse(r)], rows.isEmpty ? 0 : (rows.first['total_count'] as num).toInt());

  Future<AdminSession> session() async {
    final rows = _rows(await _client.rpc('admin_session'));
    return rows.isEmpty ? AdminSession.none : AdminSession.fromJson(rows.first);
  }

  Future<AdminPage<AdminExtensionRequest>> extensionQueue({
    required ExtensionQueueFilter filter,
    String? search,
    int offset = 0,
  }) async {
    final rows = _rows(
      await _client.rpc(
        'admin_extension_queue',
        params: {
          'p_status': filter.key,
          'p_search': (search?.trim().isEmpty ?? true) ? null : search!.trim(),
          'p_limit': pageSize,
          'p_offset': offset,
        },
      ),
    );
    return _page(rows, AdminExtensionRequest.fromJson);
  }

  /// Returns the resulting status: approved | rejected | expired.
  Future<String> decide({required String requestId, required bool approve, String? note}) async {
    final response = await _client.rpc(
      'admin_decide_extension',
      params: {
        'p_request_id': requestId,
        'p_decision': approve ? 'approved' : 'rejected',
        'p_note': (note?.trim().isEmpty ?? true) ? null : note!.trim(),
      },
    );
    return response as String;
  }

  Future<List<AdminBabyResult>> lookupBabies(String query) async {
    final rows = _rows(await _client.rpc('admin_baby_lookup', params: {'p_query': query.trim()}));
    return [for (final r in rows) AdminBabyResult.fromJson(r)];
  }

  Future<BirthDatePreview> previewBirthDate({required String babyId, required DateTime birthDate}) async {
    final rows = _rows(
      await _client.rpc(
        'admin_preview_birth_date_correction',
        params: {'p_baby_id': babyId, 'p_birth_date': Dates.toSql(birthDate)},
      ),
    );
    return BirthDatePreview.fromJson(rows.single);
  }

  Future<void> correctBirthDate({
    required String babyId,
    required DateTime birthDate,
    required String reason,
    required bool confirmReopen,
  }) => _client.rpc(
    'admin_correct_birth_date',
    params: {
      'p_baby_id': babyId,
      'p_birth_date': Dates.toSql(birthDate),
      'p_reason': reason.trim(),
      'p_confirm_reopen': confirmReopen,
    },
  );

  Future<AdminPage<AdminAuditEntry>> auditLog({AdminAuditAction? action, int offset = 0}) async {
    final rows = _rows(
      await _client.rpc(
        'admin_audit_log',
        params: {'p_action': action?.key, 'p_baby_id': null, 'p_limit': pageSize, 'p_offset': offset},
      ),
    );
    return _page(rows, AdminAuditEntry.fromJson);
  }
}
