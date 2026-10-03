import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/connectivity.dart';

/// Thin banner shown while the device is offline; cached data stays visible.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(isOnlineProvider).value ?? true;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      child: online
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              color: scheme.inverseSurface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    Icon(Icons.cloud_off_rounded, size: 16, color: scheme.onInverseSurface),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Çevrimdışısınız — son kaydedilen veriler gösteriliyor.',
                        style: TextStyle(color: scheme.onInverseSurface, fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
