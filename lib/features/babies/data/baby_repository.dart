import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../family/domain/relation.dart';
import '../domain/baby.dart';

final babyRepositoryProvider = Provider<BabyRepository>(
  (ref) => BabyRepository(ref.watch(supabaseProvider), ref.watch(localCacheProvider)),
);

class BabyInput {
  const BabyInput({
    required this.firstName,
    required this.birthDate,
    this.lastName,
    this.birthTime,
    this.birthPlace,
    this.birthWeightGrams,
    this.birthLengthCm,
    this.story,
  });

  final String firstName;
  final String? lastName;
  final DateTime birthDate;

  /// "HH:mm"
  final String? birthTime;
  final String? birthPlace;
  final int? birthWeightGrams;
  final double? birthLengthCm;
  final String? story;

  String? get _sqlTime => birthTime == null ? null : '$birthTime:00';

  Map<String, dynamic> toRow() => {
    'first_name': firstName.trim(),
    'last_name': (lastName?.trim().isEmpty ?? true) ? null : lastName!.trim(),
    'birth_date': Dates.toSql(birthDate),
    'birth_time': _sqlTime,
    'birth_place': (birthPlace?.trim().isEmpty ?? true) ? null : birthPlace!.trim(),
    'birth_weight_grams': birthWeightGrams,
    'birth_length_cm': birthLengthCm,
    'story': (story?.trim().isEmpty ?? true) ? null : story!.trim(),
  };
}

class BabyStats {
  const BabyStats({this.memories = 0, this.milestones = 0, this.letters = 0, this.photos = 0, this.videos = 0, this.capsules = 0});

  factory BabyStats.fromJson(Map<String, dynamic> j) => BabyStats(
    memories: (j['memories'] as num?)?.toInt() ?? 0,
    milestones: (j['milestones'] as num?)?.toInt() ?? 0,
    letters: (j['letters'] as num?)?.toInt() ?? 0,
    photos: (j['photos'] as num?)?.toInt() ?? 0,
    videos: (j['videos'] as num?)?.toInt() ?? 0,
    capsules: (j['capsules'] as num?)?.toInt() ?? 0,
  );

  final int memories;
  final int milestones;
  final int letters;
  final int photos;
  final int videos;
  final int capsules;

  Map<String, dynamic> toJson() => {
    'memories': memories,
    'milestones': milestones,
    'letters': letters,
    'photos': photos,
    'videos': videos,
    'capsules': capsules,
  };
}

class BabyRepository {
  BabyRepository(this._client, this._cache);

  final SupabaseClient _client;
  final LocalCache _cache;

  /// Babies the user is a member of (RLS limits the rows).
  Future<List<Baby>> myBabies(String uid) => _cache.networkFirst<List<Baby>>(
    key: 'babies.$uid',
    fetch: () async {
      final rows = await _client.from('babies').select().order('birth_date');
      return rows.map(Baby.fromJson).toList();
    },
    encode: (list) => list.map((b) => b.toJson()).toList(),
    decode: (j) => (j as List).map((e) => Baby.fromJson((e as Map).cast<String, dynamic>())).toList(),
  );

  Future<Baby> create(BabyInput input, {required Relation relation, String? relationLabel}) async {
    final row = await _client.rpc('create_baby', params: {
      'p_first_name': input.firstName.trim(),
      'p_birth_date': Dates.toSql(input.birthDate),
      'p_relation': relation.key,
      'p_relation_label': relationLabel,
      'p_last_name': input.toRow()['last_name'],
      'p_birth_time': input.toRow()['birth_time'],
      'p_birth_place': input.toRow()['birth_place'],
      'p_birth_weight_grams': input.birthWeightGrams,
      'p_birth_length_cm': input.birthLengthCm,
      'p_story': input.toRow()['story'],
    });
    return Baby.fromJson((row as Map).cast<String, dynamic>());
  }

  Future<Baby> update(String babyId, BabyInput input) async {
    final row = await _client.from('babies').update(input.toRow()).eq('id', babyId).select().single();
    return Baby.fromJson(row);
  }

  /// Uploads a profile or cover image into `<baby>/profile/` (manage_baby).
  Future<void> uploadImage(Baby baby, File jpeg, {required bool cover}) async {
    final path = '${baby.id}/profile/${cover ? 'cover' : 'avatar'}-${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _client.storage.from(Buckets.babyMedia).upload(
      path,
      jpeg,
      fileOptions: const FileOptions(contentType: 'image/jpeg', cacheControl: '3600'),
    );
    await _client.from('babies').update({cover ? 'cover_path' : 'avatar_path': path}).eq('id', baby.id);
    final old = cover ? baby.coverPath : baby.avatarPath;
    if (old != null) {
      try {
        await _client.storage.from(Buckets.babyMedia).remove([old]);
      } catch (_) {}
    }
  }

  Future<BabyStats> stats(String babyId) => _cache.networkFirst<BabyStats>(
    key: 'stats.$babyId',
    fetch: () async {
      final res = await _client.rpc('baby_stats', params: {'p_baby_id': babyId});
      return BabyStats.fromJson((res as Map).cast<String, dynamic>());
    },
    encode: (s) => s.toJson(),
    decode: (j) => BabyStats.fromJson((j as Map).cast<String, dynamic>()),
  );

  /// Permanently deletes the baby, all content and files (admins only),
  /// through the `privacy-actions` Edge Function.
  Future<void> delete(String babyId) async {
    await _client.functions.invoke('privacy-actions', body: {'action': 'delete_baby', 'baby_id': babyId});
  }
}
