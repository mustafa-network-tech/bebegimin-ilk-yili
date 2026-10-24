import 'package:bebegimin_ilk_yili/app/router.dart';
import 'package:bebegimin_ilk_yili/features/admin/domain/admin_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const adminEnabled = AdminSession(isSuperAdmin: true, consoleEnabled: true);
  const adminDisabled = AdminSession(isSuperAdmin: true, consoleEnabled: false);

  test('admin oturumu normal uygulama rotalarından admin ekranına gider', () {
    expect(platformAdminRedirect('/home', const AsyncData(adminEnabled)), '/admin');
    expect(platformAdminRedirect('/family', const AsyncData(adminEnabled)), '/admin');
    expect(platformAdminRedirect('/admin', const AsyncData(adminEnabled)), isNull);
  });

  test('kill-switch kapalı olsa da admin aile uygulamasına düşmez', () {
    expect(platformAdminRedirect('/splash', const AsyncData(adminDisabled)), '/admin');
  });

  test('normal kullanıcının mevcut rota akışına karışmaz', () {
    expect(platformAdminRedirect('/home', const AsyncData(AdminSession.none)), isNull);
  });

  test('rol kontrolü yüklenirken splash beklenir', () {
    expect(platformAdminRedirect('/home', const AsyncLoading()), '/splash');
    expect(platformAdminRedirect('/splash', const AsyncLoading()), isNull);
  });

  test('rol kontrol hatası normal uygulamaya erişimi kapalı tutar', () {
    final failed = AsyncValue<AdminSession>.error(StateError('network'), StackTrace.empty);
    expect(platformAdminRedirect('/home', failed), '/admin');
    expect(platformAdminRedirect('/admin', failed), isNull);
  });
}
