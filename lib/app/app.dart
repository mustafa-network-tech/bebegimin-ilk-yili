import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/family/domain/invitation.dart';
import '../features/notifications/data/push_service.dart';
import '../features/settings/application/theme_mode.dart';
import 'env.dart';
import 'router.dart';
import 'session.dart';
import 'theme.dart';

class BebegiminApp extends ConsumerStatefulWidget {
  const BebegiminApp({super.key});

  @override
  ConsumerState<BebegiminApp> createState() => _BebegiminAppState();
}

class _BebegiminAppState extends ConsumerState<BebegiminApp> {
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    if (!Env.isSupabaseConfigured) return;
    _listenForInviteLinks();
    // Push is optional; initialises only when Firebase is configured.
    Future.microtask(() => ref.read(pushServiceProvider).start());
  }

  void _listenForInviteLinks() {
    final appLinks = AppLinks();
    void handle(Uri uri) {
      // Auth callbacks (bebegimin://login-callback) are handled by supabase_flutter.
      final isInvite =
          uri.host == 'invite' || uri.pathSegments.contains('davet') || uri.pathSegments.contains('invite');
      if (!isInvite) return;
      final code = InviteCode.parse(uri.toString());
      if (code == null) return;
      ref.read(pendingInviteCodeProvider.notifier).set(code);
      ref.read(routerProvider).go('/join?code=$code');
    }

    _links = appLinks.uriLinkStream.listen(handle, onError: (_) {});
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Env.isSupabaseConfigured) ref.watch(passwordRecoveryProvider); // keep the listener alive
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Bebeğimin İlk Yılı',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: router,
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
