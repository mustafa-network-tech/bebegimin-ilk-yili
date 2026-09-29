import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../domain/letter.dart';

final letterRepositoryProvider = Provider<LetterRepository>((ref) => LetterRepository(ref.watch(supabaseProvider)));

class LetterRepository {
  LetterRepository(this._client);

  final SupabaseClient _client;

  Future<List<Letter>> forBaby(String babyId) async {
    final rows = await _client.from('letters').select().eq('baby_id', babyId).order('written_on', ascending: false);
    return rows.map(Letter.fromJson).toList();
  }

  Future<Letter?> get(String babyId, String id) async {
    final row = await _client.from('letters').select().eq('baby_id', babyId).eq('id', id).maybeSingle();
    return row == null ? null : Letter.fromJson(row);
  }

  Future<Letter> create({
    required String babyId,
    String? title,
    required String body,
    required DateTime writtenOn,
    bool includeInBook = true,
  }) async {
    final row = await _client
        .from('letters')
        .insert({
          'baby_id': babyId,
          'title': (title?.trim().isEmpty ?? true) ? null : title!.trim(),
          'body': body.trim(),
          'written_on': Dates.toSql(writtenOn),
          'include_in_book': includeInBook,
        })
        .select()
        .single();
    return Letter.fromJson(row);
  }

  Future<Letter> update(
    String babyId,
    String id, {
    String? title,
    required String body,
    required DateTime writtenOn,
    required bool includeInBook,
  }) async {
    final row = await _client
        .from('letters')
        .update({
          'title': (title?.trim().isEmpty ?? true) ? null : title!.trim(),
          'body': body.trim(),
          'written_on': Dates.toSql(writtenOn),
          'include_in_book': includeInBook,
        })
        .eq('baby_id', babyId)
        .eq('id', id)
        .select()
        .single();
    return Letter.fromJson(row);
  }

  Future<void> setIncludeInBook(String babyId, String id, bool v) =>
      _client.from('letters').update({'include_in_book': v}).eq('baby_id', babyId).eq('id', id);

  /// Row first; attached media files are queued server-side for cleanup.
  Future<void> delete(String babyId, String id) => _client.from('letters').delete().eq('baby_id', babyId).eq('id', id);

  Future<String?> resolveLegacyBabyId(String id) async {
    final row = await _client.from('letters').select('baby_id').eq('id', id).maybeSingle();
    return row?['baby_id'] as String?;
  }
}
