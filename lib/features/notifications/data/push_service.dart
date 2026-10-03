import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/env.dart';
import '../../../core/supabase_providers.dart';
import 'notification_repository.dart';

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Optional Firebase Cloud Messaging integration.
///
/// The app never needs Firebase to work: notifications are rows in the
/// `notifications` table (in-app inbox + realtime badge). When FIREBASE_*
/// values are provided at build time, device tokens are registered in
/// `device_tokens` and the `send-push` Edge Function delivers pushes.
class PushService {
  PushService(this._ref);

  final Ref _ref;
  bool _started = false;
  String? _token;
  final _foreground = StreamController<RemoteMessage>.broadcast();

  /// Messages received while the app is open (shown as in-app banners).
  Stream<RemoteMessage> get foregroundMessages => _foreground.stream;

  /// Route to open when the user tapped a push (consumed by the shell).
  final openedRoute = ValueNotifier<String?>(null);

  static FirebaseOptions? get _options {
    if (!Env.isPushConfigured || kIsWeb) return null;
    final appId = Platform.isIOS ? Env.firebaseIosAppId : Env.firebaseAndroidAppId;
    if (appId.isEmpty) return null;
    return FirebaseOptions(
      apiKey: Env.firebaseApiKey,
      appId: appId,
      messagingSenderId: Env.firebaseSenderId,
      projectId: Env.firebaseProjectId,
      iosBundleId: Env.firebaseIosBundleId.isEmpty ? null : Env.firebaseIosBundleId,
    );
  }

  bool get isAvailable => _options != null;

  Future<void> start() async {
    if (_started || !isAvailable) return;
    _started = true;
    try {
      await Firebase.initializeApp(options: _options);
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      await messaging.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);

      FirebaseMessaging.onMessage.listen(_foreground.add);
      FirebaseMessaging.onMessageOpenedApp.listen((m) => openedRoute.value = m.data['route'] as String?);
      final initial = await messaging.getInitialMessage();
      if (initial != null) openedRoute.value = initial.data['route'] as String?;

      messaging.onTokenRefresh.listen(_register);
      _ref.listen(currentUserIdProvider, (prev, next) async {
        if (next != null) {
          final t = _token ?? await messaging.getToken();
          if (t != null) await _register(t);
        }
      }, fireImmediately: true);
    } catch (e) {
      debugPrint('Push disabled: $e');
    }
  }

  void dispose() {
    _foreground.close();
    openedRoute.dispose();
  }

  Future<void> _register(String token) async {
    _token = token;
    if (_ref.read(currentUserIdProvider) == null) return;
    try {
      await _ref.read(notificationRepositoryProvider).registerDeviceToken(token, Platform.isIOS ? 'ios' : 'android');
    } catch (e) {
      debugPrint('Device token registration failed: $e');
    }
  }

  /// Called before sign-out so the device stops receiving the user's pushes.
  Future<void> unregister() async {
    final t = _token;
    if (t == null) return;
    try {
      await _ref.read(notificationRepositoryProvider).removeDeviceToken(t);
    } catch (_) {}
  }
}
