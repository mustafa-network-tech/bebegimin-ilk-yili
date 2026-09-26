import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/app_notification.dart';

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(ref.watch(supabaseProvider)),
);

class NotificationRepository {
  NotificationRepository(this._client);

  final SupabaseClient _client;

  Future<List<AppNotification>> list() async {
    final rows = await _client.from('notifications').select().order('created_at', ascending: false).limit(100);
    return rows.map(AppNotification.fromJson).toList();
  }

  /// Live unread count (Supabase Realtime); falls back to polling-free
  /// initial value if realtime is not enabled.
  Stream<int> unreadCount(String uid) => _client
      .from('notifications')
      .stream(primaryKey: ['id'])
      .eq('user_id', uid)
      .map((rows) => rows.where((r) => r['read_at'] == null).length);

  Future<void> markRead(String id) =>
      _client.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);

  Future<void> markAllRead() => _client
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .isFilter('read_at', null);

  Future<void> delete(String id) => _client.from('notifications').delete().eq('id', id);

  Future<void> registerDeviceToken(String token, String platform) => _client.from('device_tokens').upsert({
    'token': token,
    'platform': platform,
    'user_id': _client.auth.currentUser!.id,
  }, onConflict: 'token');

  Future<void> removeDeviceToken(String token) => _client.from('device_tokens').delete().eq('token', token);
}
