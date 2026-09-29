import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/subscription_providers.dart';
import '../data/store_billing.dart';
import '../domain/subscription_models.dart';
import 'family_plan_screen.dart';

const paywallRoute = '/paywall';

/// Routes that stay reachable while the family subscription is inactive:
/// the payment page itself, plans, account settings (incl. deletion and
/// sign-out), joining another family and creating a baby.
bool allowedWithoutSubscription(String location) =>
    location == paywallRoute ||
    location == familyPlanRoute ||
    location.startsWith('/settings') ||
    location == '/join' ||
    location == '/baby/new' ||
    location == '/admin';

/// Shown instead of the app when the family subscription is not active.
/// Parents can buy or restore; Family Members are told who can renew.
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  StreamSubscription<StorePurchaseEvent>? _events;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _events = ref.read(storeBillingProvider).events.listen((e) {
      if (!mounted) return;
      if (e.status == StorePurchaseStatus.verified) showSnack(context, 'Aile paketiniz etkinleşti.');
      if (e.status == StorePurchaseStatus.failed && e.message != null) showSnack(context, e.message!, error: true);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() => _restoring = true);
    try {
      await ref.read(storeBillingProvider).restore();
      if (mounted) showSnack(context, 'Satın alımlar kontrol ediliyor…');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baby = ref.watch(activeBabyProvider);
    final babies = ref.watch(babiesProvider).value ?? const [];
    if (baby == null) return const Scaffold(body: LoadingView());
    final state = ref.watch(babyAccessStateProvider(baby.id));
    final store = ref.watch(storeBillingProvider);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Aile paketi'),
        actions: [
          IconButton(
            tooltip: 'Ayarlar',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: AsyncValueView<BabyAccessState>(
        value: state,
        onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump(),
        data: (s) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Center(
              child: AppAvatar(name: baby.firstName, bucket: Buckets.babyMedia, path: baby.avatarPath, radius: 40),
            ),
            const SizedBox(height: 16),
            Text(s.title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(s.message, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            if (s.isParent && s.reason != AccessReason.accountUnmapped) ...[
              FilledButton.icon(
                onPressed: () => context.push(familyPlanRoute),
                icon: const Icon(Icons.workspace_premium_rounded),
                label: Text(s.reason == AccessReason.paymentIssue ? 'Paketi yönet' : 'Aile paketini seç'),
              ),
              const SizedBox(height: 8),
              if (store.isSupported)
                OutlinedButton.icon(
                  onPressed: _restoring ? null : _restore,
                  icon: const Icon(Icons.restore_rounded),
                  label: const Text('Satın alımları geri yükle'),
                ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => ref.read(lifecycleRevisionProvider.notifier).bump(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Tekrar kontrol et'),
            ),
            if (babies.length > 1) ...[
              const Divider(height: 40),
              Text('Başka bir çocuğa geç', style: theme.textTheme.titleSmall),
              for (final b in babies.where((b) => b.id != baby.id))
                ListTile(
                  leading: AppAvatar(name: b.firstName, bucket: Buckets.babyMedia, path: b.avatarPath),
                  title: Text(b.fullName),
                  onTap: () => ref.read(activeBabyIdProvider.notifier).select(b.id),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
