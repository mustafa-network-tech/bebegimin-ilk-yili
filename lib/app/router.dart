import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/supabase_providers.dart';
import '../core/content/content_route.dart';
import '../core/content/legacy_content_redirect_screen.dart';
import '../core/utils/dates.dart';
import '../features/admin/presentation/admin_screens.dart';
import '../features/auth/presentation/auth_screens.dart';
import '../features/babies/application/baby_providers.dart';
import '../features/babies/presentation/baby_form_screen.dart';
import '../features/babies/presentation/lifecycle_screen.dart';
import '../features/babies/presentation/lifecycle_widgets.dart';
import '../features/babies/presentation/onboarding_screens.dart';
import '../features/babies/presentation/route_baby.dart';
import '../features/archive/presentation/archive_screen.dart';
import '../features/book/presentation/book_editor_screen.dart';
import '../features/book/presentation/book_gate.dart';
import '../features/book/presentation/book_generation.dart';
import '../features/book/presentation/book_home_screen.dart';
import '../features/book/presentation/book_page_editor_screen.dart';
import '../features/film/presentation/film_screen.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/capsules/presentation/capsule_screens.dart';
import '../features/family/presentation/family_screen.dart';
import '../features/family/presentation/invite_screens.dart';
import '../features/family/presentation/member_screens.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/letters/presentation/letter_screens.dart';
import '../features/media/presentation/album_screen.dart';
import '../features/media/presentation/media_viewer_screen.dart';
import '../features/memories/domain/memory.dart';
import '../features/memories/presentation/memory_detail_screen.dart';
import '../features/memories/presentation/memory_form_screen.dart';
import '../features/memories/presentation/timeline_screen.dart';
import '../features/milestones/presentation/milestone_screens.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/premium/presentation/premium_store_screen.dart';
import '../features/profile/data/profile_repository.dart';
import '../features/search/presentation/search_screen.dart';
import '../features/settings/presentation/settings_screens.dart';
import '../features/subscription/application/subscription_providers.dart';
import '../features/subscription/presentation/family_plan_screen.dart';
import '../features/subscription/presentation/paywall_screen.dart';
import 'env.dart';
import 'session.dart';
import 'shell.dart';

final _rootKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) => _redirect(ref, state),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/config-error', builder: (_, _) => const ConfigErrorScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(path: '/forgot-password', builder: (_, _) => const ForgotPasswordScreen()),
      GoRoute(
        path: '/verify-email',
        builder: (_, s) => VerifyEmailScreen(email: s.uri.queryParameters['email'] ?? ''),
      ),
      GoRoute(path: '/reset-password', builder: (_, _) => const ResetPasswordScreen()),
      GoRoute(path: '/onboarding/profile', builder: (_, _) => const ProfileSetupScreen()),
      GoRoute(path: '/onboarding/start', builder: (_, _) => const StartChoiceScreen()),
      GoRoute(
        path: '/join',
        builder: (_, s) => JoinFamilyScreen(initialCode: s.uri.queryParameters['code']),
      ),
      GoRoute(path: '/baby/new', builder: (_, _) => const BabyFormScreen()),
      GoRoute(
        path: '/baby/:id/edit',
        builder: (_, s) => BabyFormScreen(babyId: s.pathParameters['id']),
      ),

      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/timeline', builder: (_, _) => const TimelineScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/calendar',
                builder: (_, s) => CalendarScreen(initialDate: Dates.tryFromSql(s.uri.queryParameters['date'])),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/family', builder: (_, _) => const FamilyScreen())],
          ),
        ],
      ),

      // Create routes pin the baby selected when they open (plan 2.4).
      GoRoute(
        path: '/memory/new',
        builder: (_, s) => PinnedActiveBaby(
          builder: (babyId) => LifecycleWriteGuard(
            babyId: babyId,
            child: MemoryFormScreen(
              babyId: babyId,
              initialCategory: MemoryCategory.fromKey(s.uri.queryParameters['category']),
              initialDate: Dates.tryFromSql(s.uri.queryParameters['date']),
              autoPick: s.uri.queryParameters['pick'],
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/memory/:id',
        builder: (_, s) =>
            LegacyContentRedirectScreen(kind: ContentRouteKind.memory, contentId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/memory/:id/edit',
        builder: (_, s) =>
            LegacyContentRedirectScreen(kind: ContentRouteKind.memory, contentId: s.pathParameters['id']!, edit: true),
      ),
      GoRoute(
        path: '/babies/:babyId/memories/:id',
        builder: (_, s) => MemoryDetailScreen(babyId: s.pathParameters['babyId']!, memoryId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/babies/:babyId/memories/:id/edit',
        builder: (_, s) => LifecycleWriteGuard(
          babyId: s.pathParameters['babyId'],
          child: MemoryFormScreen(babyId: s.pathParameters['babyId'], memoryId: s.pathParameters['id']),
        ),
      ),
      GoRoute(path: '/album', builder: (_, _) => const AlbumScreen()),
      GoRoute(
        path: '/babies/:babyId/media',
        // Opened from a list with its items; a restored / external link has none.
        redirect: (_, s) => s.extra is MediaViewerArgs ? null : '/album',
        builder: (_, s) => MediaViewerScreen(babyId: s.pathParameters['babyId']!, args: s.extra! as MediaViewerArgs),
      ),
      GoRoute(path: '/milestones', builder: (_, _) => const MilestonesScreen()),
      GoRoute(
        path: '/milestone/new',
        builder: (_, s) => PinnedActiveBaby(
          builder: (babyId) => LifecycleWriteGuard(
            babyId: babyId,
            child: MilestoneFormScreen(babyId: babyId, typeId: s.uri.queryParameters['typeId']),
          ),
        ),
      ),
      GoRoute(
        path: '/milestone/:id',
        builder: (_, s) =>
            LegacyContentRedirectScreen(kind: ContentRouteKind.milestone, contentId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/milestone/:id/edit',
        builder: (_, s) => LegacyContentRedirectScreen(
          kind: ContentRouteKind.milestone,
          contentId: s.pathParameters['id']!,
          edit: true,
        ),
      ),
      GoRoute(
        path: '/babies/:babyId/milestones/:id',
        builder: (_, s) =>
            MilestoneDetailScreen(babyId: s.pathParameters['babyId']!, milestoneId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/babies/:babyId/milestones/:id/edit',
        builder: (_, s) => LifecycleWriteGuard(
          babyId: s.pathParameters['babyId'],
          child: MilestoneFormScreen(babyId: s.pathParameters['babyId'], milestoneId: s.pathParameters['id']),
        ),
      ),
      GoRoute(path: '/letters', builder: (_, _) => const LettersScreen()),
      GoRoute(
        path: '/letter/new',
        builder: (_, _) => PinnedActiveBaby(
          builder: (babyId) => LifecycleWriteGuard(
            babyId: babyId,
            child: LetterFormScreen(babyId: babyId),
          ),
        ),
      ),
      GoRoute(
        path: '/letter/:id',
        builder: (_, s) =>
            LegacyContentRedirectScreen(kind: ContentRouteKind.letter, contentId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/letter/:id/edit',
        builder: (_, s) =>
            LegacyContentRedirectScreen(kind: ContentRouteKind.letter, contentId: s.pathParameters['id']!, edit: true),
      ),
      GoRoute(
        path: '/babies/:babyId/letters/:id',
        builder: (_, s) => LetterDetailScreen(babyId: s.pathParameters['babyId']!, letterId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/babies/:babyId/letters/:id/edit',
        builder: (_, s) => LifecycleWriteGuard(
          babyId: s.pathParameters['babyId'],
          child: LetterFormScreen(babyId: s.pathParameters['babyId'], letterId: s.pathParameters['id']),
        ),
      ),
      GoRoute(path: '/capsules', builder: (_, _) => const CapsulesScreen()),
      GoRoute(
        path: '/capsule/new',
        builder: (_, _) => PinnedActiveBaby(
          builder: (babyId) => LifecycleWriteGuard(
            babyId: babyId,
            child: CapsuleFormScreen(babyId: babyId),
          ),
        ),
      ),
      GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
      // Book: LOCKED + family subscription + purchased book (plan 2.9 /
      // phase 9); editor routes are for parents only. Every premium route
      // carries its baby (plan 2.4 / 3.3).
      GoRoute(
        path: '/babies/:babyId/book',
        builder: (_, s) => BookRouteGate(
          babyId: s.pathParameters['babyId']!,
          child: BookHomeScreen(babyId: s.pathParameters['babyId']!),
        ),
      ),
      GoRoute(
        path: '/babies/:babyId/book/editor',
        builder: (_, s) => BookRouteGate(
          babyId: s.pathParameters['babyId']!,
          requireEdit: true,
          child: BookEditorScreen(babyId: s.pathParameters['babyId']!),
        ),
      ),
      GoRoute(
        path: '/babies/:babyId/book/view',
        redirect: (_, s) => s.extra is File ? null : bookRoute(s.pathParameters['babyId']!),
        builder: (_, s) => BookRouteGate(
          babyId: s.pathParameters['babyId']!,
          child: BookPdfViewScreen(file: s.extra! as File),
        ),
      ),
      GoRoute(
        path: '/babies/:babyId/book/pages/:pageId',
        builder: (_, s) => BookRouteGate(
          babyId: s.pathParameters['babyId']!,
          requireEdit: true,
          child: BookPageEditorScreen(babyId: s.pathParameters['babyId']!, pageId: s.pathParameters['pageId']!),
        ),
      ),
      // Offline HTML archive: same premium gate; built on the server (phase 11).
      GoRoute(
        path: '/babies/:babyId/archive',
        builder: (_, s) => ArchiveRouteGate(
          babyId: s.pathParameters['babyId']!,
          child: ArchiveScreen(babyId: s.pathParameters['babyId']!),
        ),
      ),
      // Film: same premium gate; produced on the server (phase 10).
      GoRoute(
        path: '/babies/:babyId/film',
        builder: (_, s) => FilmRouteGate(
          babyId: s.pathParameters['babyId']!,
          child: FilmScreen(babyId: s.pathParameters['babyId']!),
        ),
      ),
      GoRoute(
        path: '/babies/:babyId/film/view',
        redirect: (_, s) => s.extra is File ? null : filmRoute(s.pathParameters['babyId']!),
        builder: (_, s) => FilmRouteGate(
          babyId: s.pathParameters['babyId']!,
          child: FilmPlayerScreen(file: s.extra! as File),
        ),
      ),
      // Old links (stored notifications, earlier app versions) open the
      // selected baby's canonical route.
      GoRoute(path: '/book', redirect: (_, _) => _forActiveBaby(ref, bookRoute)),
      GoRoute(path: '/film', redirect: (_, _) => _forActiveBaby(ref, filmRoute)),
      GoRoute(path: '/archive', redirect: (_, _) => _forActiveBaby(ref, archiveRoute)),
      // Decision P-12: downloads are not shared with Family Members any more;
      // old links land on the baby's store page.
      GoRoute(
        path: '/babies/:babyId/download-permissions',
        redirect: (_, s) => premiumStoreRoute(s.pathParameters['babyId']!),
      ),
      GoRoute(
        path: '/babies/:babyId/premium',
        builder: (_, s) => PremiumStoreScreen(babyId: s.pathParameters['babyId']!),
      ),
      GoRoute(
        path: '/babies/:babyId/lifecycle',
        builder: (_, s) => BabyLifecycleScreen(babyId: s.pathParameters['babyId']!),
      ),
      // Platform Super Admin console: separate from the family shell; the
      // database re-checks the role on every call.
      GoRoute(
        path: '/admin',
        builder: (_, _) => const AdminGate(child: AdminConsoleScreen()),
      ),
      GoRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(path: '/settings/profile', builder: (_, _) => const EditProfileScreen()),
      GoRoute(path: '/settings/password', builder: (_, _) => const ChangePasswordScreen()),
      GoRoute(path: '/settings/notifications', builder: (_, _) => const NotificationSettingsScreen()),
      GoRoute(path: '/settings/delete-account', builder: (_, _) => const DeleteAccountScreen()),
      GoRoute(path: '/settings/privacy', builder: (_, _) => const PrivacyScreen()),
      GoRoute(path: '/family/invite', builder: (_, _) => const InviteScreen()),
      GoRoute(path: familyPlanRoute, builder: (_, _) => const FamilyPlanScreen()),
      GoRoute(path: paywallRoute, builder: (_, _) => const PaywallScreen()),
      GoRoute(
        path: '/babies/:babyId/members/:memberId',
        builder: (_, s) =>
            MemberEditScreen(babyId: s.pathParameters['babyId']!, memberId: s.pathParameters['memberId']!),
      ),
      GoRoute(
        path: '/family/member/:id',
        redirect: (_, s) => _forActiveBaby(ref, (babyId) => memberRoute(babyId, s.pathParameters['id']!)),
      ),
      GoRoute(path: '/family/activity', builder: (_, _) => const ActivityLogScreen()),
      GoRoute(path: '/family/add-from-sibling', builder: (_, _) => const AddFromSiblingScreen()),
    ],
  );
});

/// Canonical baby-scoped route for the selected baby (legacy links only).
String _forActiveBaby(Ref ref, String Function(String babyId) route) {
  final baby = ref.read(activeBabyProvider);
  return baby == null ? '/home' : route(baby.id);
}

const _publicRoutes = {'/login', '/register', '/forgot-password', '/verify-email', '/config-error'};
const _onboardingRoutes = {
  '/onboarding/profile',
  '/onboarding/start',
  '/baby/new',
  '/join',
  '/settings',
  '/settings/profile',
  '/settings/delete-account',
  '/settings/privacy',
  '/admin',
};

String? _redirect(Ref ref, GoRouterState state) {
  final loc = state.matchedLocation;
  if (!Env.isSupabaseConfigured) return loc == '/config-error' ? null : '/config-error';

  // Invitation links opened while signed out are remembered.
  if (loc == '/join') {
    final code = state.uri.queryParameters['code'];
    if (code != null) Future.microtask(() => ref.read(pendingInviteCodeProvider.notifier).set(code));
  }

  final user = ref.read(currentUserProvider);
  if (user == null) {
    return _publicRoutes.contains(loc) ? null : '/login';
  }
  if (ref.read(passwordRecoveryProvider)) {
    return loc == '/reset-password' ? null : '/reset-password';
  }

  final profile = ref.read(myProfileProvider);
  final babies = ref.read(babiesProvider);
  if ((profile.isLoading && !profile.hasValue) || (babies.isLoading && !babies.hasValue)) {
    return loc == '/splash' ? null : (loc == '/join' ? null : '/splash');
  }
  final p = profile.value;
  if (p != null && !p.hasName) {
    return loc == '/onboarding/profile' ? null : '/onboarding/profile';
  }

  final pending = ref.read(pendingInviteCodeProvider);
  final hasBabies = (babies.value ?? const []).isNotEmpty;
  if (!hasBabies) {
    if (pending != null && loc != '/join') return '/join?code=$pending';
    if (_onboardingRoutes.contains(loc)) return null;
    return '/onboarding/start';
  }
  if (_publicRoutes.contains(loc) ||
      loc == '/splash' ||
      loc == '/onboarding/start' ||
      loc == '/onboarding/profile' ||
      loc == '/reset-password') {
    if (pending != null) return '/join?code=$pending';
    return '/home';
  }

  // Inactive family subscription: the archive stays readable (decision P-2);
  // the shell shows a read-only banner and write routes are guarded. The
  // payment page is only left automatically once access is back.
  final gate = ref.read(activeAccessGateProvider);
  final blocked = gate != null && !gate.allowed;
  if (!blocked && loc == paywallRoute && gate != null) return '/home';
  return null;
}

/// Re-runs the redirect whenever session-relevant state changes.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    if (!Env.isSupabaseConfigured) return;
    ref.listen(currentUserIdProvider, (_, _) => notifyListeners());
    ref.listen(passwordRecoveryProvider, (_, _) => notifyListeners());
    ref.listen(myProfileProvider, (_, _) => notifyListeners());
    ref.listen(babiesProvider, (_, _) => notifyListeners());
    ref.listen(pendingInviteCodeProvider, (_, _) => notifyListeners());
    ref.listen(activeAccessGateProvider, (_, _) => notifyListeners());
  }
}
