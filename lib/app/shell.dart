import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/content/lifecycle_revision.dart';
import '../core/widgets/offline_banner.dart';
import '../features/family/application/family_providers.dart';
import '../features/family/domain/permission.dart';
import '../features/media/presentation/upload_status_bar.dart';
import '../features/notifications/data/push_service.dart';
import '../features/subscription/presentation/read_only_banner.dart';

/// Bottom navigation: Ana Sayfa · Anılar · (+) · Takvim · Aile
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _pushSub;

  /// The Istanbul day may have changed while the app was in the background:
  /// ask the server again instead of trusting the cached lifecycle.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.read(lifecycleRevisionProvider.notifier).bump();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final push = ref.read(pushServiceProvider);
    _pushSub = push.foregroundMessages.listen((m) {
      if (!mounted) return;
      final title = m.notification?.title;
      if (title == null) return;
      final route = m.data['route'] as String?;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(title),
          action: route == null ? null : SnackBarAction(label: 'Aç', onPressed: () => context.push(route)),
        ),
      );
    });
    push.openedRoute.addListener(_openPushRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPushRoute());
  }

  void _openPushRoute() {
    final push = ref.read(pushServiceProvider);
    final route = push.openedRoute.value;
    if (route != null && mounted) {
      push.openedRoute.value = null;
      context.push(route);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pushSub?.cancel();
    ref.read(pushServiceProvider).openedRoute.removeListener(_openPushRoute);
    super.dispose();
  }

  void _go(int index) => widget.shell.goBranch(index, initialLocation: index == widget.shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(activeAccessProvider);
    final scheme = Theme.of(context).colorScheme;
    final index = widget.shell.currentIndex;

    Widget item(int i, IconData icon, IconData selected, String label) {
      final active = index == i;
      return Expanded(
        child: InkResponse(
          onTap: () => _go(i),
          radius: 36,
          child: Semantics(
            selected: active,
            button: true,
            label: label,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: active ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(active ? selected : icon, color: active ? scheme.primary : scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          const OfflineBanner(),
          const SubscriptionReadOnlyBanner(),
          Expanded(child: widget.shell),
          const UploadStatusBar(),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: access.canCreateAnything
          ? FloatingActionButton(
              heroTag: 'create',
              tooltip: 'Yeni ekle',
              elevation: 2,
              shape: const CircleBorder(),
              onPressed: () => showCreateSheet(context, access),
              child: const Icon(Icons.add_rounded, size: 30),
            )
          : null,
      bottomNavigationBar: BottomAppBar(
        height: 72,
        padding: EdgeInsets.zero,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const CircularNotchedRectangle(),
        notchMargin: 7,
        child: Row(
          children: [
            item(0, Icons.home_outlined, Icons.home_rounded, 'Ana Sayfa'),
            item(1, Icons.auto_stories_outlined, Icons.auto_stories_rounded, 'Anılar'),
            const SizedBox(width: 72),
            item(2, Icons.calendar_month_outlined, Icons.calendar_month_rounded, 'Takvim'),
            item(3, Icons.people_outline_rounded, Icons.people_rounded, 'Aile'),
          ],
        ),
      ),
    );
  }
}

/// The central "+" action: Anı · Fotoğraf · Video · Kilometre taşı · Mektup · Kapsül
Future<void> showCreateSheet(BuildContext context, MemberAccess access) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      Widget tile(IconData icon, Color color, String title, String subtitle, String route, {required bool enabled}) {
        return ListTile(
          enabled: enabled,
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(icon, color: color),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(enabled ? subtitle : 'Bu işlem için yetkiniz yok'),
          onTap: () {
            Navigator.pop(ctx);
            context.push(route);
          },
        );
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Ne eklemek istersiniz?', style: Theme.of(ctx).textTheme.titleLarge),
              ),
              tile(
                Icons.auto_awesome_rounded,
                const Color(0xFFC7785B),
                'Anı',
                'Bugün ya da geçmiş bir tarihe',
                '/memory/new?category=moment',
                enabled: access.can(AppPermission.addMemory),
              ),
              tile(
                Icons.photo_library_rounded,
                const Color(0xFF7FA38E),
                'Fotoğraf',
                'Kamera veya galeriden, tek ya da çoklu',
                '/memory/new?category=photo&pick=photo',
                enabled: access.can(AppPermission.addMemory) && access.can(AppPermission.addPhoto),
              ),
              tile(
                Icons.videocam_rounded,
                const Color(0xFF6E8FB5),
                'Video',
                'Kısa bir an kaydedin',
                '/memory/new?category=video&pick=video',
                enabled: access.can(AppPermission.addMemory) && access.can(AppPermission.addVideo),
              ),
              tile(
                Icons.star_rounded,
                const Color(0xFFE2B866),
                'Kilometre taşı',
                'İlk gülümseme, ilk adım…',
                '/milestones',
                enabled: access.can(AppPermission.addMilestone),
              ),
              tile(
                Icons.mail_rounded,
                const Color(0xFFB7A6C9),
                'Mektup',
                'Bebeğinize bir mektup bırakın',
                '/letter/new',
                enabled: access.can(AppPermission.writeLetter),
              ),
              tile(
                Icons.hourglass_bottom_rounded,
                const Color(0xFF9C8BB0),
                'Zaman kapsülü',
                'Yıllar sonra açılacak bir mesaj',
                '/capsule/new',
                enabled: access.can(AppPermission.writeLetter),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}
