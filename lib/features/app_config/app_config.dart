import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/env.dart';
import '../../core/supabase_providers.dart';

/// Server-side client requirements (`app_config`, readable before sign-in).
class ClientRequirements {
  const ClientRequirements({required this.minSupportedBuild, required this.latestBuild});

  final int minSupportedBuild;
  final int latestBuild;

  bool mustUpgrade(int build) => build < minSupportedBuild;
}

final appBuildProvider = Provider<int>((ref) => Env.appBuild);

/// Never blocks on failure: offline or misconfigured clients keep working;
/// the server enforces every rule regardless of the client version.
final clientRequirementsProvider = FutureProvider<ClientRequirements?>((ref) async {
  if (!Env.isSupabaseConfigured) return null;
  try {
    final client = ref.watch(supabaseProvider);
    final rows = await client.rpc('app_config') as List;
    final row = (rows.first as Map).cast<String, dynamic>();
    return ClientRequirements(
      minSupportedBuild: (row['min_supported_build'] as num).toInt(),
      latestBuild: (row['latest_build'] as num).toInt(),
    );
  } on PostgrestException {
    return null;
  } catch (_) {
    return null;
  }
});

/// Shows a blocking, safe upgrade screen when this build is no longer
/// supported (for example after a breaking backend policy change).
class UpgradeGate extends ConsumerWidget {
  const UpgradeGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = ref.watch(clientRequirementsProvider).value;
    if (req == null || !req.mustUpgrade(ref.watch(appBuildProvider))) return child;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.system_update_rounded, size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 20),
                Text('Güncelleme gerekiyor', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  'Bu sürüm artık desteklenmiyor. Anılarınız güvende; devam etmek için uygulamayı App Store veya '
                  'Google Play\'den güncelleyin.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
