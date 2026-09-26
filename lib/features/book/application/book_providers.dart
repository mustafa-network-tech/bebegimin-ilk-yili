import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/book_repository.dart';
import '../domain/book_models.dart';

final bookProjectProvider = FutureProvider.autoDispose.family<BookProject?, String>(
  (ref, babyId) => ref.watch(bookRepositoryProvider).projectFor(babyId),
);

final bookExportsProvider = FutureProvider.autoDispose.family<List<BookExport>, String>(
  (ref, projectId) => ref.watch(bookRepositoryProvider).exports(projectId),
);
