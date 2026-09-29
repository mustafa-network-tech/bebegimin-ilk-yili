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
import '../features/book/presentation/book_editor_screen.dart';
import '../features/book/presentation/book_generation.dart';
import '../features/book/presentation/book_home_screen.dart';
import '../features/book/presentation/book_page_editor_screen.dart';
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

      GoRoute(
        path: '/memory/new',
        builder: (_, s) => LifecycleWriteGuard(
          child: MemoryFormScreen(
            initialCategory: MemoryCategory.fromKey(s.uri.queryParameters['category']),
            initialDate: Dates.tryFromSql(s.uri.queryParameters['date']),
            autoPick: s.uri.queryParameters['pick'],
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
        builder: (_, s) => MediaViewerScreen(babyId: s.pathParameters['babyId']!, args: s.extra! as MediaViewerArgs),
      ),
      GoRoute(path: '/milestones', builder: (_, _) => const MilestonesScreen()),
      GoRoute(
        path: '/milestone/new',
        builder: (_, s) => LifecycleWriteGuard(child: MilestoneFormScreen(typeId: s.uri.queryParameters['typeId'])),
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
        builder: (_, _) => const LifecycleWriteGuard(child: LetterFormScreen()),
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
        builder: (_, _) => const LifecycleWriteGuard(child: CapsuleFormScreen()),
      ),
      GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
      // Premium area: closed for ACTIVE profiles, placeholder for LOCKED ones
      // until entitlements exist (plan 2.2 / phase 9).
      GoRoute(
        path: '/book',
        builder: (_, _) => const PremiumRouteGate(child: BookHomeScreen()),
      ),
      GoRoute(
        path: '/book/editor',
        builder: (_, _) => const PremiumRouteGate(child: BookEditorScreen()),
      ),
      GoRoute(
        path: '/book/view',
        builder: (_, s) => PremiumRouteGate(child: BookPdfViewScreen(file: s.extra! as File)),
      ),
      GoRoute(
        path: '/book/page/:pageId',
        builder: (_, s) => PremiumRouteGate(child: BookPageEditorScreen(pageId: s.pathParameters['pageId']!)),
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
        path: '/family/member/:id',
        builder: (_, s) => MemberEditScreen(memberId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/family/activity', builder: (_, _) => const ActivityLogScreen()),
      GoRoute(path: '/family/add-from-sibling', builder: (_, _) => const AddFromSiblingScreen()),
    ],
  );
});

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

  // Inactive family subscription: the whole family goes to the payment page
  // (the server enforces the same rule on every read and write).
  final gate = ref.read(activeAccessGateProvider);
  final blocked = gate != null && !gate.allowed;
  if (blocked && !allowedWithoutSubscription(loc)) return paywallRoute;
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
