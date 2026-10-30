import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/artifact_download.dart';
import '../../../core/supabase_providers.dart';
import '../domain/film_models.dart';

final filmRepositoryProvider = Provider<FilmRepository>((ref) => FilmRepository(ref.watch(supabaseProvider)));

/// First-year film (Phase 10). The app never renders: it edits the project
/// settings, reads the server's duration estimate, requests a server render
/// and downloads the verified MP4.
class FilmRepository {
  FilmRepository(this._client);

  final SupabaseClient _client;

  Map<String, dynamic> _single(Object? rows) => ((rows as List).single as Map).cast<String, dynamic>();

  Future<FilmAccess> access(String babyId) async =>
      FilmAccess.fromJson(_single(await _client.rpc('film_access_state', params: {'p_baby_id': babyId})));

  Future<FilmSettings> settings(String babyId) async {
    final data = await _client.rpc('film_settings', params: {'p_baby_id': babyId});
    return FilmSettings.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<FilmSettings> updateSettings(String babyId, FilmSettings settings) async {
    final data = await _client.rpc(
      'film_update_settings',
      params: {'p_baby_id': babyId, 'p_settings': settings.toJson()},
    );
    return FilmSettings.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<FilmPlan> plan(String babyId) async =>
      FilmPlan.fromJson(_single(await _client.rpc('film_plan', params: {'p_baby_id': babyId})));

  /// A selection that fits ten minutes (not saved until applied).
  Future<FilmSettings> suggest(String babyId) async {
    final data = await _client.rpc('film_suggest_settings', params: {'p_baby_id': babyId});
    return FilmSettings.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<String> requestRender(String babyId, String idempotencyKey) async {
    final row = _single(
      await _client.rpc('film_request_render', params: {'p_baby_id': babyId, 'p_idempotency_key': idempotencyKey}),
    );
    return row['job_id'] as String;
  }

  Future<FilmState> state(String babyId) async {
    final rows = await _client.rpc('film_state', params: {'p_baby_id': babyId}) as List;
    return rows.isEmpty ? FilmState.empty : FilmState.fromJson((rows.first as Map).cast<String, dynamic>());
  }

  Future<Uint8List> download(FilmState state) =>
      downloadVerifiedArtifact(_client, state.artifactId!, state.artifactSha256!);
}
