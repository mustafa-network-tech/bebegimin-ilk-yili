import 'package:bebegimin_ilk_yili/core/cache/local_cache.dart';
import 'package:bebegimin_ilk_yili/core/content/content_route.dart';
import 'package:bebegimin_ilk_yili/features/media/domain/media_item.dart';
import 'package:bebegimin_ilk_yili/features/media/domain/pending_upload.dart';
import 'package:bebegimin_ilk_yili/features/notifications/domain/app_notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('baby-scoped content context', () {
    test('canonical detail and edit routes include baby and content ids', () {
      expect(contentRoute(ContentRouteKind.memory, 'defne', 'm1'), '/babies/defne/memories/m1');
      expect(contentRoute(ContentRouteKind.milestone, 'ece', 'ms1', edit: true), '/babies/ece/milestones/ms1/edit');
      expect(contentRoute(ContentRouteKind.letter, 'defne', 'l1'), '/babies/defne/letters/l1');
      expect(mediaViewerRoute('ece'), '/babies/ece/media');
    });

    test('route/model baby mismatch is rejected', () {
      expect(matchesBabyContext(routeBabyId: 'ece', modelBabyId: 'defne', contentId: 'm1'), isFalse);
      expect(matchesBabyContext(routeBabyId: 'defne', modelBabyId: 'defne', contentId: 'm1'), isTrue);
    });

    test('notification does not create an unscoped content route', () {
      final scoped = AppNotification.fromJson({
        'id': 'n1',
        'baby_id': 'defne',
        'type': 'content_added',
        'title': 'Yeni anı',
        'data': {'target_type': 'memories', 'target_id': 'm1'},
        'created_at': '2026-09-27T00:00:00Z',
      });
      final unscoped = AppNotification.fromJson({
        'id': 'n2',
        'baby_id': null,
        'type': 'content_added',
        'title': 'Yeni anı',
        'data': {'target_type': 'memories', 'target_id': 'm1'},
        'created_at': '2026-09-27T00:00:00Z',
      });

      expect(scoped.route, '/babies/defne/memories/m1');
      expect(unscoped.route, isNull);
    });

    test('local and upload namespaces separate users and babies', () {
      expect(
        LocalCache.userBabyKey(userId: 'anne', babyId: 'defne', resource: 'timeline'),
        isNot(LocalCache.userBabyKey(userId: 'anne', babyId: 'ece', resource: 'timeline')),
      );
      expect(
        LocalCache.userBabyKey(userId: 'anne', babyId: 'defne', resource: 'timeline'),
        isNot(LocalCache.userBabyKey(userId: 'baba', babyId: 'defne', resource: 'timeline')),
      );

      final upload = PendingUpload(
        id: 'media-1',
        userId: 'anne',
        babyId: 'defne',
        kind: MediaKind.photo,
        localPath: 'source.jpg',
        mimeType: 'image/jpeg',
        takenOn: DateTime(2026, 9, 27),
      );
      expect(upload.localNamespace, 'anne/defne/media-1');
      expect(PendingUpload.fromJson(upload.toJson()).localNamespace, upload.localNamespace);
    });
  });
}
