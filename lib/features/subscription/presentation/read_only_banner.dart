import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/subscription_providers.dart';
import 'paywall_screen.dart';

/// Shown in the app shell while the family subscription is inactive: the
/// archive stays readable but nothing can be added or changed (decision P-2).
class SubscriptionReadOnlyBanner extends ConsumerWidget {
  const SubscriptionReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(activeAccessGateProvider);
    if (gate == null || gate.allowed) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: [
              Icon(Icons.visibility_rounded, size: 18, color: scheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  gate.isParent
                      ? 'Aile paketi aktif değil: arşiv salt okunur.'
                      : 'Aile paketi aktif değil: arşiv salt okunur. Anne veya Baba yenileyebilir.',
                  style: TextStyle(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(onPressed: () => context.push(paywallRoute), child: const Text('Aile paketi')),
            ],
          ),
        ),
      ),
    );
  }
}
