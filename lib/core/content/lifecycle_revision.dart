import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped whenever the server-side lifecycle may have changed: the app came
/// back to the foreground, or the backend refused a write because an archive
/// is locked. Lifecycle summaries watch it and refetch from the server.
final lifecycleRevisionProvider = NotifierProvider<LifecycleRevision, int>(LifecycleRevision.new);

class LifecycleRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}
