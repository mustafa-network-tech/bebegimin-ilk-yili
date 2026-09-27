import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/baby_lifecycle_repository.dart';
import '../domain/baby_lifecycle.dart';

final babyLifecycleProvider = FutureProvider.autoDispose.family<BabyLifecycle, String>(
  (ref, babyId) => ref.watch(babyLifecycleRepositoryProvider).summary(babyId),
);
