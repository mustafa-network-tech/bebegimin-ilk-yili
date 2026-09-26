import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../domain/time_capsule.dart';

final capsuleRepositoryProvider = Provider<CapsuleRepository>((ref) => CapsuleRepository(ref.watch(supabaseProvider)));

class CapsuleRepository {
  CapsuleRepository(this._client);

  final SupabaseClient _client;

  /// Sealed capsules come back without content: the RLS policy on
  /// `time_capsule_contents` only returns rows whose open date has come.
  Future<List<TimeCapsule>> forBaby(String babyId) async {
    final rows = await _client
        .from('time_capsules')
        .select('*, time_capsule_contents(body)')
        .eq('baby_id', babyId)
        .order('open_on');
    return rows.map(TimeCapsule.fromJson).toList();
  }

  Future<String> create({
    required String babyId,
    required String title,
    required String body,
    required DateTime openOn,
    required CapsuleOccasion occasion,
    File? photoJpeg,
  }) async {
    final id = await _client.rpc(
      'create_time_capsule',
      params: {
        'p_baby_id': babyId,
        'p_title': title.trim(),
        'p_body': body.trim(),
        'p_open_on': Dates.toSql(openOn),
        'p_occasion': occasion.key,
        'p_has_photo': photoJpeg != null,
      },
    ) as String;
    if (photoJpeg != null) {
      await _client.storage
          .from(Buckets.babyMedia)
          .upload(
            '$babyId/capsules/$id/photo.jpg',
            photoJpeg,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
    }
    return id;
  }

  Future<void> delete(TimeCapsule c) async {
    if (c.hasPhoto) {
      try {
        await _client.storage.from(Buckets.babyMedia).remove([c.photoPath]);
      } catch (_) {}
    }
    await _client.from('time_capsules').delete().eq('id', c.id);
  }
}
