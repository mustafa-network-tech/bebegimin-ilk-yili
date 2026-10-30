import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/artifact_download.dart';
import '../../../core/supabase_providers.dart';
import '../domain/archive_models.dart';

final archiveRepositoryProvider = Provider<ArchiveRepository>((ref) => ArchiveRepository(ref.watch(supabaseProvider)));

/// Offline HTML archive (Phase 11). Built on the server from the sealed
/// snapshot; the app requests it, follows progress and downloads the ZIP.
class ArchiveRepository {
  ArchiveRepository(this._client);

  final SupabaseClient _client;

  Future<ArchiveAccess> access(String babyId) async {
    final rows = await _client.rpc('html_access_state', params: {'p_baby_id': babyId}) as List;
    return ArchiveAccess.fromJson((rows.single as Map).cast<String, dynamic>());
  }

  Future<String> request(String babyId, String idempotencyKey) async {
    final rows = await _client.rpc(
      'html_request_render',
      params: {'p_baby_id': babyId, 'p_idempotency_key': idempotencyKey},
    ) as List;
    return (rows.single as Map)['job_id'] as String;
  }

  Future<ArchiveState> state(String babyId) async {
    final rows = await _client.rpc('html_state', params: {'p_baby_id': babyId}) as List;
    return rows.isEmpty ? ArchiveState.empty : ArchiveState.fromJson((rows.first as Map).cast<String, dynamic>());
  }

  Future<Uint8List> download(ArchiveState state) =>
      downloadVerifiedArtifact(_client, state.artifactId!, state.artifactSha256!);
}
