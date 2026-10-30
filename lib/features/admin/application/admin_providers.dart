import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import '../data/admin_repository.dart';
import '../domain/admin_models.dart';

/// Platform role of the signed-in user, asked from the database. Used only
/// to show or hide the console entry; every console RPC re-checks the role.
final adminSessionProvider = FutureProvider<AdminSession>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return AdminSession.none;
  return ref.watch(adminRepositoryProvider).session();
});
