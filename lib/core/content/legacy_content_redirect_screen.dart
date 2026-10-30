import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/letters/data/letter_repository.dart';
import '../../features/memories/data/memory_repository.dart';
import '../../features/milestones/data/milestone_repository.dart';
import '../widgets/states.dart';
import 'content_route.dart';

class LegacyContentRedirectScreen extends ConsumerStatefulWidget {
  const LegacyContentRedirectScreen({super.key, required this.kind, required this.contentId, this.edit = false});

  final ContentRouteKind kind;
  final String contentId;
  final bool edit;

  @override
  ConsumerState<LegacyContentRedirectScreen> createState() => _LegacyContentRedirectScreenState();
}

class _LegacyContentRedirectScreenState extends ConsumerState<LegacyContentRedirectScreen> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_resolve);
  }

  Future<void> _resolve() async {
    try {
      final babyId = switch (widget.kind) {
        ContentRouteKind.memory => await ref.read(memoryRepositoryProvider).resolveLegacyBabyId(widget.contentId),
        ContentRouteKind.milestone => await ref.read(milestoneRepositoryProvider).resolveLegacyBabyId(widget.contentId),
        ContentRouteKind.letter => await ref.read(letterRepositoryProvider).resolveLegacyBabyId(widget.contentId),
      };
      if (!mounted) return;
      if (babyId == null) {
        setState(() => _failed = true);
        return;
      }
      context.go(contentRoute(widget.kind, babyId, widget.contentId, edit: widget.edit));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: _failed
        ? const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'İçerik bulunamadı',
            message: 'Silinmiş olabilir ya da erişim yetkiniz yok.',
          )
        : const LoadingView(),
  );
}
