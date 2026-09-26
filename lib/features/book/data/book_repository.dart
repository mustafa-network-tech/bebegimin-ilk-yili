import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';

final bookRepositoryProvider = Provider<BookRepository>(
  (ref) => BookRepository(ref.watch(supabaseProvider)),
);

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

  Future<BookProject> _reload(String projectId) async =>
      BookProject.fromJson(await _client.from('book_projects').select(_projectSelect).eq('id', projectId).single());

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
    return _reload(projectId);
  }

  Future<void> _insertPlanned(String babyId, String projectId, List<PlannedPage> pages, {required int startOrder}) async {
    final pageRows = <Map<String, dynamic>>[];
    final itemRows = <Map<String, dynamic>>[];
    var order = startOrder;
    for (final p in pages) {
      final pageId = _uuid.v4();
      pageRows.add(BookPage(
        id: pageId,
        projectId: projectId,
        type: p.type,
        monthIndex: p.monthIndex,
        title: p.title,
        body: null,
        sortOrder: order++,
        isHidden: false,
        items: const [],
      ).toRow(babyId));
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
        .eq('id', project.id);
    return _reload(project.id);
  }

  Future<void> updateProject(
    String id, {
    String? title,
    String? subtitle,
    BookFormat? format,
    String? coverMediaId,
    String? backCoverText,
    bool clearSubtitle = false,
  }) async {
    await _client.from('book_projects').update({
      'title': ?title,
      if (subtitle != null || clearSubtitle) 'subtitle': subtitle,
      if (format != null) 'format': format.key,
      'cover_media_id': ?coverMediaId,
      'back_cover_text': ?backCoverText,
    }).eq('id', id);
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

  Future<void> deletePage(String pageId) => _client.from('book_pages').delete().eq('id', pageId);

  Future<void> addItems(String babyId, String pageId, List<PlannedItem> items, int startOrder) async {
    if (items.isEmpty) return;
    await _client.from('book_items').insert([
      for (var i = 0; i < items.length; i++) _itemRow(babyId, pageId, items[i], startOrder + i),
    ]);
  }

  Future<void> deleteItem(String itemId) => _client.from('book_items').delete().eq('id', itemId);

  // Exports -------------------------------------------------------------------------
  Future<List<BookExport>> exports(String projectId) async {
    final rows = await _client
        .from('book_exports')
        .select()
        .eq('project_id', projectId)
        .order('version', ascending: false);
    return rows.map(BookExport.fromJson).toList();
  }

  /// Uploads a generated PDF to the private `books` bucket and registers a
  /// new version (atomic version bump on the server).
  Future<BookExport> publish(BookProject project, File pdf, {required int pageCount, required BookQuality quality}) async {
    final path = '${project.babyId}/${project.id}/ilk-yilim-${DateTime.now().millisecondsSinceEpoch}.pdf';
    await _client.storage.from(Buckets.books).upload(
      path,
      pdf,
      fileOptions: const FileOptions(contentType: 'application/pdf'),
    );
    final row = await _client.rpc('register_book_export', params: {
      'p_project_id': project.id,
      'p_storage_path': path,
      'p_page_count': pageCount,
      'p_size_bytes': await pdf.length(),
      'p_quality': quality.key,
    });
    return BookExport.fromJson((row as Map).cast<String, dynamic>());
  }

  Future<Uint8List> download(BookExport export) => _client.storage.from(Buckets.books).download(export.storagePath);

  Future<void> deleteExport(BookExport export) async {
    try {
      await _client.storage.from(Buckets.books).remove([export.storagePath]);
    } catch (_) {}
    await _client.from('book_exports').delete().eq('id', export.id);
  }
}
