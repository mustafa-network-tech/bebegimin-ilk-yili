import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../media/domain/media_item.dart';
import '../../memories/data/memory_repository.dart';
import '../domain/letter.dart';

final letterRepositoryProvider = Provider<LetterRepository>(
  (ref) => LetterRepository(ref.watch(supabaseProvider)),
);

class LetterRepository {
  LetterRepository(this._client);

  final SupabaseClient _client;

  Future<List<Letter>> forBaby(String babyId) async {
    final rows = await _client.from('letters').select().eq('baby_id', babyId).order('written_on', ascending: false);
    return rows.map(Letter.fromJson).toList();
  }

  Future<Letter?> get(String id) async {
    final row = await _client.from('letters').select().eq('id', id).maybeSingle();
    return row == null ? null : Letter.fromJson(row);
  }

  Future<Letter> create({required String babyId, String? title, required String body, required DateTime writtenOn, bool includeInBook = true}) async {
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

  Future<Letter> update(String id, {String? title, required String body, required DateTime writtenOn, required bool includeInBook}) async {
    final row = await _client
        .from('letters')
        .update({
          'title': (title?.trim().isEmpty ?? true) ? null : title!.trim(),
          'body': body.trim(),
          'written_on': Dates.toSql(writtenOn),
          'include_in_book': includeInBook,
        })
        .eq('id', id)
        .select()
        .single();
    return Letter.fromJson(row);
  }

  Future<void> setIncludeInBook(String id, bool v) => _client.from('letters').update({'include_in_book': v}).eq('id', id);

  Future<void> delete(String id, List<MediaItem> media) async {
    await removeFiles(_client, media);
    await _client.from('letters').delete().eq('id', id);
  }
}
