import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped after every mutation (new memory, finished upload, edit …).
/// Content providers watch it, so every visible list refreshes itself.
final contentRevisionProvider = NotifierProvider<ContentRevision, int>(ContentRevision.new);

class ContentRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}
