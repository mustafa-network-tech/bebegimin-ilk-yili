import 'package:flutter/foundation.dart';

enum ContentRouteKind { memory, milestone, letter }

String contentRoute(ContentRouteKind kind, String babyId, String contentId, {bool edit = false}) {
  final segment = switch (kind) {
    ContentRouteKind.memory => 'memories',
    ContentRouteKind.milestone => 'milestones',
    ContentRouteKind.letter => 'letters',
  };
  return '/babies/$babyId/$segment/$contentId${edit ? '/edit' : ''}';
}

String mediaViewerRoute(String babyId) => '/babies/$babyId/media';

/// Refuses a model returned for a different route scope and records the
/// mismatch without exposing which baby owns the content.
bool matchesBabyContext({required String routeBabyId, required String modelBabyId, required String contentId}) {
  final matches = routeBabyId == modelBabyId;
  if (!matches) {
    debugPrint('security: baby context mismatch for content=$contentId');
  }
  return matches;
}
