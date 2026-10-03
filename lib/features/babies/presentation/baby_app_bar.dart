import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/signed_urls.dart';
import '../../../core/widgets/avatar.dart';
import '../../notifications/application/notification_providers.dart';
import '../application/baby_providers.dart';

/// App bar of the main tabs: active child switcher + search / notifications / settings.
class BabyAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const BabyAppBar({super.key, this.title, this.actions = const []});

  final String? title;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 4);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    final unread = ref.watch(unreadCountProvider).value ?? 0;
    return AppBar(
      toolbarHeight: kToolbarHeight + 4,
      titleSpacing: 12,
      title: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => showBabySwitcher(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppAvatar(name: baby?.firstName ?? '?', bucket: Buckets.babyMedia, path: baby?.avatarPath, radius: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title ?? baby?.firstName ?? '', overflow: TextOverflow.ellipsis),
                    if (title != null && baby != null)
                      Text(baby.firstName, style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              ),
              const Icon(Icons.expand_more_rounded, size: 20),
            ],
          ),
        ),
      ),
      actions: [
        ...actions,
        IconButton(tooltip: 'Ara', icon: const Icon(Icons.search_rounded), onPressed: () => context.push('/search')),
        IconButton(
          tooltip: 'Bildirimler',
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text(unread > 99 ? '99+' : '$unread'),
            child: const Icon(Icons.notifications_none_rounded),
          ),
          onPressed: () => context.push('/notifications'),
        ),
        IconButton(
          tooltip: 'Ayarlar',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push('/settings'),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

Future<void> showBabySwitcher(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final babies = ref.watch(babiesProvider).value ?? const [];
        final active = ref.watch(activeBabyProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Çocuklarım', style: Theme.of(ctx).textTheme.titleLarge),
                ),
              ),
              for (final b in babies)
                ListTile(
                  leading: AppAvatar(name: b.firstName, bucket: Buckets.babyMedia, path: b.avatarPath),
                  title: Text(b.fullName, style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(b.ageToday().label),
                  trailing: b.id == active?.id
                      ? Icon(Icons.check_circle_rounded, color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  onTap: () {
                    ref.read(activeBabyIdProvider.notifier).select(b.id);
                    Navigator.pop(ctx);
                  },
                ),
              const Divider(),
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
                title: const Text('Yeni çocuk ekle'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/baby/new');
                },
              ),
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.vpn_key_outlined)),
                title: const Text('Davet koduyla bir aileye katıl'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/join');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}
