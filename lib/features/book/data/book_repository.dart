import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/artifact_download.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';
import '../domain/book_snapshot.dart';

final bookRepositoryProvider = Provider<BookRepository>((ref) => BookRepository(ref.watch(supabaseProvider)));

class BookRepository {
  BookRepository(this._client);

  final SupabaseClient _client;
  static const _uuid = Uuid();

  static const _projectSelect = '*, book_pages(*, book_items(*))';

  Future<BookProject?> projectFor(String babyId) async {
    final row = await _client
        .from('book_projects')
        .select(_projectSelect)
        .eq('baby_id', babyId)
        .eq('kind', 'first_year')
        .maybeSingle();
    return row == null ? null : BookProject.fromJson(row);
  }

  // Every query and mutation is scoped by baby as well as by id (plan 3.3).
  Future<BookProject> _reload(String babyId, String projectId) async => BookProject.fromJson(
    await _client.from('book_projects').select(_projectSelect).eq('baby_id', babyId).eq('id', projectId).single(),
  );

  /// Creates the project with the default chapters and all planned items.
  Future<BookProject> create({
    required String babyId,
    required String title,
    String? subtitle,
    required BookFormat format,
    required BookPlan plan,
  }) async {
    final project = await _client
        .from('book_projects')
        .insert({
          'baby_id': babyId,
          'title': title,
          'subtitle': subtitle,
          'format': format.key,
          'cover_media_id': plan.coverMediaId,
          'last_synced_at': DateTime.now().toUtc().toIso8601String(),
        })
        .select()
        .single();
    final projectId = project['id'] as String;
    await _insertPlanned(babyId, projectId, plan.pages, startOrder: 0);
    return _reload(babyId, projectId);
  }

  Future<void> _insertPlanned(
    String babyId,
    String projectId,
    List<PlannedPage> pages, {
    required int startOrder,
  }) async {
    final pageRows = <Map<String, dynamic>>[];
    final itemRows = <Map<String, dynamic>>[];
    var order = startOrder;
    for (final p in pages) {
      final pageId = _uuid.v4();
      pageRows.add(
        BookPage(
          id: pageId,
          projectId: projectId,
          type: p.type,
          monthIndex: p.monthIndex,
          title: p.title,
          body: null,
          sortOrder: order++,
          isHidden: false,
          items: const [],
        ).toRow(babyId),
      );
      for (var i = 0; i < p.items.length; i++) {
        itemRows.add(_itemRow(babyId, pageId, p.items[i], i));
      }
    }
    if (pageRows.isNotEmpty) await _client.from('book_pages').insert(pageRows);
    for (var i = 0; i < itemRows.length; i += 500) {
      await _client.from('book_items').insert(itemRows.sublist(i, (i + 500).clamp(0, itemRows.length)));
    }
  }

  Map<String, dynamic> _itemRow(String babyId, String pageId, PlannedItem it, int order) => BookItem(
    id: _uuid.v4(),
    pageId: pageId,
    type: it.type,
    refId: it.refId,
    sortOrder: order,
    isHidden: it.hidden,
  ).toRow(babyId);

  /// Applies a [BookSyncResult]: restores missing chapters and appends new
  /// content at the end of the right chapter.
  Future<BookProject> applySync(BookProject project, BookSyncResult sync) async {
    if (sync.missingPages.isNotEmpty) {
      final maxOrder = project.pages.fold<int>(0, (m, p) => p.sortOrder > m ? p.sortOrder : m);
      await _insertPlanned(project.babyId, project.id, sync.missingPages, startOrder: maxOrder + 1);
    }
    final bySlot = {for (final p in project.pages) p.slot: p};
    final rows = <Map<String, dynamic>>[];
    sync.newItems.forEach((slot, items) {
      final page = bySlot[slot];
      if (page == null) return; // created above together with its items
      var order = page.items.fold<int>(0, (m, i) => i.sortOrder > m ? i.sortOrder : m) + 1;
      for (final it in items) {
        rows.add(_itemRow(project.babyId, page.id, it, order++));
      }
    });
    if (rows.isNotEmpty) await _client.from('book_items').insert(rows);
    await _client
        .from('book_projects')
        .update({'last_synced_at': DateTime.now().toUtc().toIso8601String()})
        .eq('baby_id', project.babyId)
        .eq('id', project.id);
    return _reload(project.babyId, project.id);
  }

  Future<void> updateProject(
    String babyId,
    String id, {
    String? title,
    String? subtitle,
    BookFormat? format,
    String? coverMediaId,
    String? backCoverText,
    bool clearSubtitle = false,
  }) async {
    await _client
        .from('book_projects')
        .update({
          'title': ?title,
          if (subtitle != null || clearSubtitle) 'subtitle': subtitle,
          if (format != null) 'format': format.key,
          'cover_media_id': ?coverMediaId,
          'back_cover_text': ?backCoverText,
        })
        .eq('baby_id', babyId)
        .eq('id', id);
  }

  Future<void> savePages(String babyId, List<BookPage> pages) async {
    if (pages.isEmpty) return;
    await _client.from('book_pages').upsert(pages.map((p) => p.toRow(babyId)).toList());
  }

  Future<void> saveItems(String babyId, List<BookItem> items) async {
    if (items.isEmpty) return;
    await _client.from('book_items').upsert(items.map((i) => i.toRow(babyId)).toList());
  }

  Future<BookPage> addCustomPage(BookProject project, String title) async {
    final maxOrder = project.pages
        .where((p) => p.type != BookPageType.backCover)
        .fold<int>(0, (m, p) => p.sortOrder > m ? p.sortOrder : m);
    final page = BookPage(
      id: _uuid.v4(),
      projectId: project.id,
      type: BookPageType.custom,
      monthIndex: null,
      title: title,
      body: null,
      sortOrder: maxOrder + 1,
      isHidden: false,
      items: const [],
    );
    await _client.from('book_pages').insert(page.toRow(project.babyId));
    return page;
  }

  Future<void> deletePage(String babyId, String pageId) =>
      _client.from('book_pages').delete().eq('baby_id', babyId).eq('id', pageId);

  Future<void> addItems(String babyId, String pageId, List<PlannedItem> items, int startOrder) async {
    if (items.isEmpty) return;
    await _client.from('book_items').insert([
      for (var i = 0; i < items.length; i++) _itemRow(babyId, pageId, items[i], startOrder + i),
    ]);
  }

  Future<void> deleteItem(String babyId, String itemId) =>
      _client.from('book_items').delete().eq('baby_id', babyId).eq('id', itemId);

  // Official book (Phase 9) ------------------------------------------------------
  /// Server-side gate: lifecycle, family subscription, entitlement and role.
  Future<BookAccess> access(String babyId) async {
    final rows = await _client.rpc('book_access_state', params: {'p_baby_id': babyId}) as List;
    return BookAccess.fromJson((rows.single as Map).cast<String, dynamic>());
  }

  /// Official (server-verified) versions with the caller's download state.
  Future<List<BookVersion>> versions(String babyId) async {
    final rows = await _client.rpc('book_versions', params: {'p_baby_id': babyId}) as List;
    return [for (final r in rows) BookVersion.fromJson((r as Map).cast<String, dynamic>())];
  }

  /// Seals the snapshot, freezes the current configuration and leases the
  /// render job to this device. The same [idempotencyKey] resumes the job.
  Future<BookRenderLease> startRender(String babyId, String idempotencyKey) async {
    final rows = await _client.rpc(
      'book_render_start',
      params: {'p_baby_id': babyId, 'p_idempotency_key': idempotencyKey},
    ) as List;
    return BookRenderLease.fromJson((rows.single as Map).cast<String, dynamic>());
  }

  Future<BookRenderPayload> payload(String jobId) async {
    final rows = await _client.rpc('book_render_payload', params: {'p_job_id': jobId}) as List;
    return BookRenderPayload.fromJson((rows.single as Map).cast<String, dynamic>());
  }

  Future<void> heartbeat(String jobId) => _client.rpc('book_render_heartbeat', params: {'p_job_id': jobId});

  /// Creates the artifact row (declared checksum and size) before the upload.
  Future<BookArtifactSlot> beginArtifact(String jobId, String sha256, int sizeBytes) async {
    final rows = await _client.rpc(
      'book_artifact_begin',
      params: {'p_job_id': jobId, 'p_sha256': sha256, 'p_size_bytes': sizeBytes},
    ) as List;
    return BookArtifactSlot.fromJson((rows.single as Map).cast<String, dynamic>());
  }

  /// The only path this device may write: the staging object of its lease.
  Future<void> uploadStaging(String stagingPath, Uint8List bytes) => _client.storage
      .from(Buckets.outputArtifacts)
      .uploadBinary(stagingPath, bytes, fileOptions: const FileOptions(contentType: 'application/pdf'));

  /// The server re-reads and hashes the upload, then publishes the version.
  Future<int> finalize(String artifactId, int pageCount) async {
    final res = await _client.functions.invoke(
      'book-artifact-finalize',
      body: {'artifact_id': artifactId, 'page_count': pageCount},
    );
    final data = (res.data as Map).cast<String, dynamic>();
    return (data['version'] as num).toInt();
  }

  /// Reports a failed render / upload so the attempt is retried later.
  Future<void> fail(String jobId, String code) =>
      _client.rpc('book_render_fail', params: {'p_job_id': jobId, 'p_error_code': code});

  /// Downloads a version and checks the bytes against the artifact checksum.
  Future<Uint8List> download(BookVersion version) =>
      downloadVerifiedArtifact(_client, version.artifactId, version.sha256);
}
