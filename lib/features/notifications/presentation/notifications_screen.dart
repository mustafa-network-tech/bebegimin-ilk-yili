import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/notification_providers.dart';
import '../data/notification_repository.dart';
import '../domain/app_notification.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  IconData _icon(String type) => switch (type) {
    'anniversary' => Icons.favorite_rounded,
    'birthday' => Icons.cake_rounded,
    'memories_of_the_day' => Icons.history_rounded,
    'book_ready' || 'book_generated' => Icons.menu_book_rounded,
    'time_capsule_opened' => Icons.drafts_rounded,
    'member_joined' => Icons.person_add_alt_1_rounded,
    _ => Icons.auto_awesome_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(notificationsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bildirimler'),
        actions: [
          TextButton(
            onPressed: () async {
              await runWithProgress(context, () => ref.read(notificationRepositoryProvider).markAllRead());
              ref.invalidate(notificationsProvider);
            },
            child: const Text('Tümünü okundu say'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(notificationsProvider.future),
        child: AsyncValueView<List<AppNotification>>(
          value: list,
          onRetry: () => ref.invalidate(notificationsProvider),
          data: (items) => items.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.notifications_none_rounded,
                      title: 'Henüz bildirim yok',
                      message: 'Ay dönümleri, aileden yeni anılar ve kitap haberleri burada görünür.',
                    ),
                  ],
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                  itemBuilder: (_, i) {
                    final n = items[i];
                    return Dismissible(
                      key: ValueKey(n.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: theme.colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline_rounded),
                      ),
                      onDismissed: (_) => ref.read(notificationRepositoryProvider).delete(n.id).ignore(),
                      child: ListTile(
                        tileColor: n.isRead ? null : theme.colorScheme.primary.withValues(alpha: 0.06),
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14),
                          child: Icon(_icon(n.type), color: theme.colorScheme.primary),
                        ),
                        title: Text(
                          n.title,
                          style: TextStyle(fontWeight: n.isRead ? FontWeight.w600 : FontWeight.w800),
                        ),
                        subtitle: Text(
                          [if (n.body?.isNotEmpty ?? false) n.body!, Dates.short(n.createdAt.toLocal())].join(' · '),
                        ),
                        onTap: () async {
                          if (!n.isRead) {
                            ref.read(notificationRepositoryProvider).markRead(n.id).ignore();
                          }
                          if (n.babyId != null) await ref.read(activeBabyIdProvider.notifier).select(n.babyId);
                          final route = n.route;
                          if (route != null && context.mounted) {
                            route.startsWith('/timeline') ||
                                    route.startsWith('/calendar') ||
                                    route.startsWith('/family')
                                ? context.go(route)
                                : context.push(route);
                          }
                          ref.invalidate(notificationsProvider);
                        },
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
