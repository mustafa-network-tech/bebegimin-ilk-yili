import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../media/domain/media_item.dart';
import '../../memories/data/memory_repository.dart';
import '../domain/milestone.dart';

final milestoneRepositoryProvider = Provider<MilestoneRepository>(
  (ref) => MilestoneRepository(ref.watch(supabaseProvider), ref.watch(localCacheProvider)),
);

class MilestoneDraft {
  const MilestoneDraft({
    required this.babyId,
    required this.typeId,
    required this.achievedOn,
    this.time,
    this.description,
    this.includeInBook = true,
  });

  final String babyId;
  final String typeId;
  final DateTime achievedOn;
  final TimeOfDay? time;
  final String? description;
  final bool includeInBook;

  Map<String, dynamic> toJson() => {
    'baby_id': babyId,
    'milestone_type_id': typeId,
    'achieved_on': Dates.toSql(achievedOn),
    'achieved_time': time == null
        ? null
        : '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}:00',
    'description': (description?.trim().isEmpty ?? true) ? null : description!.trim(),
    'include_in_book': includeInBook,
  };
}

class MilestoneRepository {
  MilestoneRepository(this._client, this._cache);

  final SupabaseClient _client;
  final LocalCache _cache;

  Future<List<MilestoneType>> types(String babyId) => _cache.networkFirst<List<MilestoneType>>(
    key: 'milestone_types.$babyId',
    fetch: () async {
      final rows = await _client
          .from('milestone_types')
          .select()
          .or('baby_id.is.null,baby_id.eq.$babyId')
          .order('sort_order')
          .order('created_at');
      return rows.map(MilestoneType.fromJson).toList();
    },
    encode: (l) => l.map((t) => t.toJson()).toList(),
    decode: (j) => (j as List).map((e) => MilestoneType.fromJson((e as Map).cast<String, dynamic>())).toList(),
  );

  Future<List<Milestone>> forBaby(String babyId) => _cache.networkFirst<List<Milestone>>(
    key: 'milestones.$babyId',
    fetch: () async {
      final rows = await _client.from('milestones').select().eq('baby_id', babyId).order('achieved_on');
      return rows.map(Milestone.fromJson).toList();
    },
    encode: (l) => l.map((m) => m.toJson()).toList(),
    decode: (j) => (j as List).map((e) => Milestone.fromJson((e as Map).cast<String, dynamic>())).toList(),
  );

  Future<Milestone?> get(String id) async {
    final row = await _client.from('milestones').select().eq('id', id).maybeSingle();
    return row == null ? null : Milestone.fromJson(row);
  }

  Future<Milestone> create(MilestoneDraft d) async {
    final row = await _client.from('milestones').insert(d.toJson()).select().single();
    return Milestone.fromJson(row);
  }

  Future<Milestone> update(String id, MilestoneDraft d) async {
    final json = d.toJson()
      ..remove('baby_id')
      ..remove('milestone_type_id');
    final row = await _client.from('milestones').update(json).eq('id', id).select().single();
    return Milestone.fromJson(row);
  }

  Future<void> delete(String id, List<MediaItem> media) async {
    await removeFiles(_client, media);
    await _client.from('milestones').delete().eq('id', id);
  }

  Future<MilestoneType> createCustomType(String babyId, String title, String? emoji) async {
    final row = await _client
        .from('milestone_types')
        .insert({'baby_id': babyId, 'title': title.trim(), 'emoji': (emoji?.trim().isEmpty ?? true) ? '⭐' : emoji!.trim()})
        .select()
        .single();
    return MilestoneType.fromJson(row);
  }

  Future<void> deleteCustomType(String id) => _client.from('milestone_types').delete().eq('id', id);
}
