import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/supabase_providers.dart';
import '../domain/activity_entry.dart';
import '../domain/family_member.dart';
import '../domain/invitation.dart';
import '../domain/permission.dart';
import '../domain/relation.dart';

final familyRepositoryProvider = Provider<FamilyRepository>(
  (ref) => FamilyRepository(ref.watch(supabaseProvider), ref.watch(localCacheProvider)),
);

class FamilyRepository {
  FamilyRepository(this._client, this._cache);

  final SupabaseClient _client;
  final LocalCache _cache;

  static const _memberSelect = '*, profiles(display_name, avatar_path)';

  Future<List<FamilyMember>> members(String babyId) => _cache.networkFirst<List<FamilyMember>>(
    key: 'members.$babyId',
    fetch: () async {
      final rows = await _client.from('family_members').select(_memberSelect).eq('baby_id', babyId).order('joined_at');
      return rows.map(FamilyMember.fromJson).toList();
    },
    encode: (l) => l.map((m) => m.toJson()).toList(),
    decode: (j) => (j as List).map((e) => FamilyMember.fromJson((e as Map).cast<String, dynamic>())).toList(),
  );

  Future<void> updateMember(
    String memberId, {
    required Relation relation,
    String? relationLabel,
    required bool isAdmin,
    required Set<AppPermission> permissions,
  }) async {
    await _client.from('family_members').update({
      'relation': relation.key,
      'relation_label': (relationLabel?.trim().isEmpty ?? true) ? null : relationLabel!.trim(),
      'is_admin': isAdmin,
      'permissions': permissions.map((p) => p.key).toList(),
    }).eq('id', memberId);
  }

  Future<void> removeMember(String memberId) => _client.from('family_members').delete().eq('id', memberId);

  Future<void> leave(String babyId, String uid) =>
      _client.from('family_members').delete().eq('baby_id', babyId).eq('user_id', uid);

  Future<List<Invitation>> invitations(String babyId) async {
    final rows = await _client
        .from('family_invitations')
        .select()
        .eq('baby_id', babyId)
        .order('created_at', ascending: false)
        .limit(50);
    return rows.map(Invitation.fromJson).toList();
  }

  Future<Invitation> createInvitation({
    required String babyId,
    required Relation relation,
    String? relationLabel,
    required bool isAdmin,
    required Set<AppPermission> permissions,
    String? email,
    Duration validFor = const Duration(days: 7),
  }) async {
    final row = await _client
        .from('family_invitations')
        .insert({
          'baby_id': babyId,
          'relation': relation.key,
          'relation_label': (relationLabel?.trim().isEmpty ?? true) ? null : relationLabel!.trim(),
          'is_admin': isAdmin,
          'permissions': permissions.map((p) => p.key).toList(),
          'invited_email': (email?.trim().isEmpty ?? true) ? null : email!.trim(),
          'expires_at': DateTime.now().toUtc().add(validFor).toIso8601String(),
        })
        .select()
        .single();
    return Invitation.fromJson(row);
  }

  Future<void> revokeInvitation(String id) => _client.rpc('revoke_invitation', params: {'p_invitation_id': id});

  Future<InvitationPreview?> preview(String code) async {
    final rows = await _client.rpc('preview_invitation', params: {'p_code': code}) as List;
    if (rows.isEmpty) return null;
    return InvitationPreview.fromJson((rows.first as Map).cast<String, dynamic>());
  }

  /// Returns the id of the baby the user just joined.
  Future<String> accept(String code) async =>
      (await _client.rpc('accept_invitation', params: {'p_code': code})) as String;

  Future<void> addFromSibling({
    required String babyId,
    required String userId,
    required Relation relation,
    String? relationLabel,
    required Set<AppPermission> permissions,
    bool isAdmin = false,
  }) => _client.rpc('add_member_from_sibling', params: {
    'p_target_baby_id': babyId,
    'p_user_id': userId,
    'p_relation': relation.key,
    'p_relation_label': relationLabel,
    'p_permissions': permissions.map((p) => p.key).toList(),
    'p_is_admin': isAdmin,
  });

  Future<List<ActivityEntry>> activity(String babyId) async {
    final rows = await _client
        .from('activity_logs')
        .select()
        .eq('baby_id', babyId)
        .order('created_at', ascending: false)
        .limit(100);
    return rows.map(ActivityEntry.fromJson).toList();
  }
}
