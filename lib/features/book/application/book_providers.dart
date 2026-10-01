import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../../../core/content/lifecycle_revision.dart';
import '../../babies/application/baby_providers.dart';
import '../data/book_generator.dart';
import '../data/book_repository.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';

final bookProjectProvider = FutureProvider.autoDispose.family<BookProject?, String>((ref, babyId) {
  ref.watch(contentRevisionProvider);
  return ref.watch(bookRepositoryProvider).projectFor(babyId);
});

/// Server-side book gate; refetched with the lifecycle (resume, midnight,
/// refusals) so a reopened or expired archive closes the book immediately.
final bookAccessProvider = FutureProvider.autoDispose.family<BookAccess, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(bookRepositoryProvider).access(babyId);
});

/// Official, server-verified versions of the baby's book.
final bookVersionsProvider = FutureProvider.autoDispose.family<List<BookVersion>, String>((ref, babyId) {
  ref.watch(lifecycleRevisionProvider);
  return ref.watch(bookRepositoryProvider).versions(babyId);
});

/// All content of the baby (for the editor pickers and sync).
final bookSourceProvider = FutureProvider.autoDispose.family<BookSource, String>((ref, babyId) async {
  ref.watch(contentRevisionProvider);
  final baby = (await ref.watch(babiesProvider.future)).firstWhere((b) => b.id == babyId);
  return ref.watch(bookGeneratorProvider).loadSource(baby);
});

/// What would be added by "Taslağı güncelle" right now.
final bookSyncPreviewProvider = FutureProvider.autoDispose.family<BookSyncResult?, String>((ref, babyId) async {
  final project = await ref.watch(bookProjectProvider(babyId).future);
  if (project == null) return null;
  final source = await ref.watch(bookSourceProvider(babyId).future);
  const composer = BookComposer();
  return composer.sync(project, composer.plan(source));
});
