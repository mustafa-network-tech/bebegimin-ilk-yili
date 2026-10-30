import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/states.dart';
import '../application/baby_providers.dart';

/// Shown by baby-scoped routes (`/babies/:babyId/...`) while the route baby
/// is not one of the user's babies: loading first, then a neutral "not
/// found" that does not reveal whether such a baby exists (plan 2.4).
class RouteBabyMissing extends ConsumerWidget {
  const RouteBabyMissing({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = ref.watch(babiesProvider).hasValue;
    return Scaffold(
      appBar: AppBar(),
      body: loaded
          ? EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Sayfa bulunamadı',
              message: 'Bu sayfa erişebildiğiniz bir bebeğe ait değil.',
              action: FilledButton(onPressed: () => context.go('/home'), child: const Text('Ana sayfa')),
            )
          : const LoadingView(),
    );
  }
}

/// Pins the active baby at the moment a create route opens. The form and its
/// lifecycle guard then work on that baby only, even if the selection
/// changes while the form is open (plan 2.4: the active baby is a UI
/// convenience, never the implicit target of a write).
class PinnedActiveBaby extends ConsumerStatefulWidget {
  const PinnedActiveBaby({super.key, required this.builder});

  final Widget Function(String babyId) builder;

  @override
  ConsumerState<PinnedActiveBaby> createState() => _PinnedActiveBabyState();
}

class _PinnedActiveBabyState extends ConsumerState<PinnedActiveBaby> {
  String? _babyId;

  @override
  Widget build(BuildContext context) {
    // Watched until the babies are loaded; pinned from then on.
    _babyId ??= ref.watch(activeBabyProvider)?.id;
    final id = _babyId;
    if (id == null) return const Scaffold(body: LoadingView());
    return widget.builder(id);
  }
}
