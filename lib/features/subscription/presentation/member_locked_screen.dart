import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../application/subscription_providers.dart';

const memberLockRoute = '/plan-locked';

/// Family members cannot buy a plan; while the family has none they only see why.
/// The router sends them back to the app as soon as the server reports access again.
class MemberLockedScreen extends ConsumerWidget {
  const MemberLockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final gate = ref.watch(activeAccessGateProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan gerekli'),
        actions: [
          IconButton(
            tooltip: 'Ayarlar',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
        children: [
          Icon(Icons.lock_outline_rounded, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 20),
          Text(gate?.title ?? 'Plan gerekli', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            gate?.message ??
                'Ailenizin planı aktif değil. Anne veya Baba planı yenilediğinde uygulamayı yeniden kullanabilirsiniz.',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Center(
            child: TextButton.icon(
              onPressed: () => ref.read(lifecycleRevisionProvider.notifier).bump(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Tekrar kontrol et'),
            ),
          ),
        ],
      ),
    );
  }
}
