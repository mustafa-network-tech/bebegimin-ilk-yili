import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_lifecycle_providers.dart';
import '../../babies/application/baby_providers.dart';
import '../../premium/presentation/premium_store_screen.dart';
import '../../subscription/presentation/family_plan_screen.dart';
import '../application/book_providers.dart';
import '../domain/book_models.dart';

/// Server-backed gate of the book routes (plan 2.9 / Phase 9). The book is
/// usable only for a LOCKED baby with a live family subscription and a
/// purchased book; editing additionally needs a parent. The backend enforces
/// the same rules on every RPC, table and Storage path.
class BookRouteGate extends ConsumerWidget {
  const BookRouteGate({super.key, required this.child, this.requireEdit = false});

  final Widget child;

  /// Editor routes: parents only. Family Members may still open the book
  /// home (official versions) and the viewer.
  final bool requireEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(bookAccessProvider(baby.id));
    final a = access.value;
    if (a == null) {
      return Scaffold(
        appBar: AppBar(),
        body: access.hasError
            ? ErrorView(error: access.error!, onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump())
            : const LoadingView(),
      );
    }
    if (a.canEdit || (!requireEdit && a.isFamilyMemberView)) return child;
    final closeDate = ref.watch(babyLifecycleProvider(baby.id)).value?.effectiveCloseDate;
    return Scaffold(
      appBar: AppBar(title: const Text('İlk Yılım kitabı')),
      body: _BlockedBook(babyId: baby.id, access: a, closeDate: closeDate),
    );
  }
}

class _BlockedBook extends StatelessWidget {
  const _BlockedBook({required this.babyId, required this.access, required this.closeDate});

  final String babyId;
  final BookAccess access;
  final DateTime? closeDate;

  @override
  Widget build(BuildContext context) {
    void back() => context.canPop() ? context.pop() : context.go('/home');
    return switch (access.block) {
      'premium_requires_locked' => EmptyState(
        icon: Icons.hourglass_bottom_rounded,
        title: 'İlk yıl devam ediyor',
        message: closeDate == null
            ? 'Dijital kitap, ilk yıl arşivi tamamlandıktan sonra hazırlanabilir.'
            : 'Dijital kitap, ilk yıl arşivi ${Dates.long(closeDate!)} tarihinde tamamlandıktan sonra hazırlanabilir.',
        action: FilledButton(onPressed: back, child: const Text('Geri dön')),
      ),
      'entitlement_required' => EmptyState(
        icon: Icons.auto_stories_rounded,
        title: 'Dijital İlk Yıl Kitabı',
        message:
            'Arşiv tamamlandı. Kitabı satın aldığınızda bölümleri düzenleyip baskıya hazır PDF oluşturabilirsiniz.',
        action: FilledButton(
          onPressed: () => context.push(premiumStoreRoute(babyId)),
          child: const Text('Dijital ürünleri gör'),
        ),
      ),
      'subscription_required' => EmptyState(
        icon: Icons.family_restroom_rounded,
        title: 'Aile paketi gerekiyor',
        message:
            'Kitabınız korunuyor. Aile paketi aboneliği yeniden etkin olduğunda düzenleyebilir ve indirebilirsiniz.',
        action: FilledButton(onPressed: () => context.push(familyPlanRoute), child: const Text('Aile paketi')),
      ),
      'not_parent' => EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Yalnızca Anne ve Baba',
        message: 'Kitabı yalnızca Anne veya Baba düzenleyebilir.',
        action: FilledButton(onPressed: back, child: const Text('Geri dön')),
      ),
      _ => EmptyState(
        icon: Icons.menu_book_outlined,
        title: 'Kitap bulunamadı',
        action: FilledButton(onPressed: back, child: const Text('Geri dön')),
      ),
    };
  }
}

/// Short reason why an official version cannot be downloaded right now.
String bookDownloadBlockText(String? block) => switch (block) {
  null => '',
  'subscription_required' => 'İndirmek için aile paketinin etkin olması gerekiyor.',
  'entitlement_required' => 'Bu kitabın satın alımı etkin değil.',
  'premium_requires_locked' => 'Arşiv yeniden açıkken kitap indirilemez.',
  'artifact_not_ready' => 'Bu sürüm henüz hazır değil.',
  _ => 'Bu sürüm şu anda indirilemiyor.',
};
