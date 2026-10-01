import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/content/lifecycle_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_lifecycle_providers.dart';
import '../../babies/application/baby_providers.dart';
import '../../subscription/data/store_billing.dart';
import '../../subscription/domain/subscription_models.dart' show formatMinor;
import '../../subscription/presentation/family_plan_screen.dart';
import '../application/premium_providers.dart';
import '../data/premium_repository.dart';
import '../domain/premium_models.dart';
import 'download_permissions_screen.dart';

String premiumStoreRoute(String babyId) => '/babies/$babyId/premium';

/// Premium storefront of one baby. Closed while the archive is ACTIVE; for a
/// LOCKED archive parents see the products with catalog prices, everyone sees
/// what the family already owns. Owned products show their preparation
/// state until the artifact pipeline delivers the file (phases 8-11).
class PremiumStoreScreen extends ConsumerStatefulWidget {
  const PremiumStoreScreen({super.key, required this.babyId});

  final String babyId;

  @override
  ConsumerState<PremiumStoreScreen> createState() => _PremiumStoreScreenState();
}

class _PremiumStoreScreenState extends ConsumerState<PremiumStoreScreen> {
  StreamSubscription<StorePurchaseEvent>? _events;
  PremiumProduct? _buying;

  @override
  void initState() {
    super.initState();
    _events = ref.read(storeBillingProvider).events.listen((e) {
      if (!mounted) return;
      switch (e.status) {
        case StorePurchaseStatus.verified:
          showSnack(context, 'Satın alma tamamlandı.');
          setState(() => _buying = null);
        case StorePurchaseStatus.pending:
          showSnack(context, 'Ödeme onayı bekleniyor…');
        case StorePurchaseStatus.failed:
          if (e.message != null) showSnack(context, e.message!, error: true);
          setState(() => _buying = null);
        case StorePurchaseStatus.canceled:
          setState(() => _buying = null);
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _buy(PremiumOffer offer) async {
    final store = ref.read(storeBillingProvider);
    final provider = store.provider;
    if (provider == null) {
      showSnack(context, 'Satın alma yalnızca iOS ve Android uygulamasında yapılabilir.', error: true);
      return;
    }
    final baby = ref.read(babyByIdProvider(widget.babyId));
    final ok = await confirm(
      context,
      title: '${offer.product.title} satın alınsın mı?',
      message:
          '${formatMinor(offer.priceMinor)} · tek seferlik. ${offer.product.description}\n\n'
          'Ürün ${baby?.firstName ?? 'bu bebek'} için aile hesabınıza tanımlanır; diğer ebeveyn ikinci kez ödeme yapmaz.',
      confirmLabel: 'Satın al',
    );
    if (!ok || !mounted) return;
    setState(() => _buying = offer.product);
    try {
      final order = await ref
          .read(premiumRepositoryProvider)
          .requestPurchase(babyId: widget.babyId, product: offer.product, provider: provider.key);
      await store.buyPremium(order);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _buying = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = ref.watch(babyLifecycleProvider(widget.babyId)).value;
    return Scaffold(
      appBar: AppBar(title: const Text('İlk Yıl hatıraları')),
      body: lifecycle == null
          ? const LoadingView()
          : lifecycle.isActive
          ? EmptyState(
              icon: Icons.hourglass_bottom_rounded,
              title: 'İlk yıl devam ediyor',
              message:
                  'Dijital kitap, film ve çevrimdışı arşiv, ilk yıl arşivi ${Dates.long(lifecycle.effectiveCloseDate)} '
                  'tarihinde tamamlandıktan sonra sunulur.',
            )
          : AsyncValueView<PremiumStoreView>(
              value: ref.watch(premiumStoreViewProvider(widget.babyId)),
              onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump(),
              data: (view) => RefreshIndicator(
                onRefresh: () async {
                  ref.read(lifecycleRevisionProvider.notifier).bump();
                  await ref.read(premiumStoreViewProvider(widget.babyId).future);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: view.isParent ? _parentView(view) : _memberView(view),
                ),
              ),
            ),
    );
  }

  List<Widget> _parentView(PremiumStoreView view) {
    final storePrices = ref.watch(premiumStorePricesProvider).value ?? const {};
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Text(
          'Her ürün bu bebek için ayrı ve tek seferlik satın alınır. Satın alınan ürün iki ebeveyn için de geçerlidir.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      for (final offer in view.offers)
        _ProductCard(
          product: offer.product,
          priceMinor: offer.priceMinor,
          storePrice: storePrices[offer.product.code],
          owned: offer.owned,
          block: offer.block,
          busy: _buying != null,
          onBuy: offer.canBuy ? () => _buy(offer) : null,
          onOpenPlan: () => context.push(familyPlanRoute),
        ),
      if (view.offers.any((o) => o.owned))
        Card(
          child: ListTile(
            leading: const Icon(Icons.share_rounded),
            title: const Text('Aile üyeleriyle paylaş'),
            subtitle: const Text('Hangi aile üyesinin hangi dosyayı indirebileceğini seçin.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(downloadPermissionsRoute(widget.babyId)),
          ),
        ),
    ];
  }

  List<Widget> _memberView(PremiumStoreView view) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Text('Dijital ürünleri Anne veya Baba satın alabilir.', style: Theme.of(context).textTheme.bodyMedium),
    ),
    for (final product in PremiumProduct.values)
      _ProductCard(product: product, owned: view.owned.contains(product), busy: false),
  ];
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.owned,
    required this.busy,
    this.priceMinor,
    this.storePrice,
    this.block,
    this.onBuy,
    this.onOpenPlan,
  });

  final PremiumProduct product;
  final int? priceMinor;
  final String? storePrice;
  final bool owned;
  final PurchaseBlock? block;
  final bool busy;
  final VoidCallback? onBuy;
  final VoidCallback? onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(product.title, style: theme.textTheme.titleMedium)),
                Chip(label: Text(product.format), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 4),
            Text(product.description, style: theme.textTheme.bodySmall),
            if (priceMinor != null) ...[
              const SizedBox(height: 8),
              Text(formatMinor(priceMinor!), style: theme.textTheme.titleLarge),
              if (storePrice != null) Text('Mağaza fiyatı: $storePrice', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            if (owned)
              Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Satın alındı')),
                  FilledButton.tonal(
                    onPressed: () => context.push(_openRoute(product)),
                    child: Text(switch (product) {
                      PremiumProduct.book => 'Kitabı aç',
                      PremiumProduct.film => 'Filmi aç',
                      PremiumProduct.html => 'Arşivi aç',
                    }),
                  ),
                ],
              )
            else if (block == PurchaseBlock.subscriptionRequired) ...[
              Text('Satın alma için aktif bir aile paketi gerekir.', style: TextStyle(color: theme.colorScheme.error)),
              TextButton(onPressed: onOpenPlan, child: const Text('Aile paketine git')),
            ] else if (block == PurchaseBlock.storefrontClosed)
              Text('Yakında satışta.', style: theme.textTheme.bodyMedium)
            else if (onBuy != null)
              FilledButton(onPressed: busy ? null : onBuy, child: const Text('Satın al')),
          ],
        ),
      ),
    );
  }
}

/// Where an owned product is prepared and downloaded.
String _openRoute(PremiumProduct product) => switch (product) {
  PremiumProduct.book => '/book',
  PremiumProduct.film => '/film',
  PremiumProduct.html => '/archive',
};

/// Home entry for a LOCKED archive: opens the premium storefront.
class PremiumEntryCard extends StatelessWidget {
  const PremiumEntryCard({super.key, required this.babyId});

  final String babyId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        child: InkWell(
          onTap: () => context.push(premiumStoreRoute(babyId)),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.lavender.withValues(alpha: 0.2),
                  child: const Icon(Icons.auto_stories_rounded, color: AppColors.lavender),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('İlk Yıl hatıraları', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Dijital kitap (PDF), İlk Yıl Filmi ve çevrimdışı HTML arşivi.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
