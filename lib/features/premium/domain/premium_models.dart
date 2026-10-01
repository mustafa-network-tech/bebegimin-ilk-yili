/// Premium one-time products of a LOCKED first-year archive. Prices always
/// come from the server catalog; only names and descriptions live here.
enum PremiumProduct {
  book(
    'first_year_book',
    'Dijital İlk Yıl Kitabı',
    'PDF',
    'Baskıya hazır dijital PDF kitap. Fiziksel / basılı kitap bu ürüne dahil değildir.',
  ),
  html(
    'first_year_html',
    'Offline HTML Hatırası',
    'ZIP (HTML)',
    'İlk yıl arşivinin internetsiz açılabilen, değiştirilemez etkileşimli kopyası.',
  ),
  film(
    'first_year_film',
    'İlk Yıl Filmi',
    'MP4',
    'Fotoğraf, video ve anılardan hazırlanan, içeriğe göre en fazla 10 dakikalık film.',
  );

  const PremiumProduct(this.code, this.title, this.format, this.description);

  final String code;
  final String title;
  final String format;
  final String description;

  static PremiumProduct? fromCode(String? code) {
    for (final p in values) {
      if (p.code == code) return p;
    }
    return null;
  }
}

/// Why a parent cannot buy right now (server hint).
enum PurchaseBlock {
  alreadyOwned,
  subscriptionRequired,
  storefrontClosed,
  requiresLocked,
  notParent,
  other;

  static PurchaseBlock? fromHint(String? hint) => switch (hint) {
    null => null,
    'already_owned' => alreadyOwned,
    'subscription_required' => subscriptionRequired,
    'storefront_closed' => storefrontClosed,
    'premium_requires_locked' => requiresLocked,
    'not_parent' => notParent,
    _ => other,
  };
}

class PremiumOffer {
  const PremiumOffer({
    required this.product,
    required this.priceMinor,
    required this.currency,
    required this.owned,
    required this.block,
  });

  factory PremiumOffer.fromJson(Map<String, dynamic> j) => PremiumOffer(
    product: PremiumProduct.fromCode(j['product_code'] as String)!,
    priceMinor: (j['price_minor'] as num).toInt(),
    currency: j['currency'] as String,
    owned: j['owned'] as bool? ?? false,
    block: PurchaseBlock.fromHint(j['purchase_block'] as String?),
  );

  final PremiumProduct product;
  final int priceMinor;
  final String currency;
  final bool owned;
  final PurchaseBlock? block;

  bool get canBuy => !owned && block == null;
}

/// What the premium screen shows: parents get the storefront, everybody the
/// products this baby already owns.
class PremiumStoreView {
  const PremiumStoreView({required this.isParent, required this.offers, required this.owned});

  final bool isParent;
  final List<PremiumOffer> offers;
  final Set<PremiumProduct> owned;
}

class PremiumOrder {
  const PremiumOrder({
    required this.orderId,
    required this.provider,
    required this.providerProductId,
    required this.product,
    required this.priceMinor,
  });

  factory PremiumOrder.fromJson(Map<String, dynamic> j) => PremiumOrder(
    orderId: j['order_id'] as String,
    provider: j['provider'] as String,
    providerProductId: j['provider_product_id'] as String,
    product: PremiumProduct.fromCode(j['product_code'] as String)!,
    priceMinor: (j['price_minor'] as num).toInt(),
  );

  final String orderId;
  final String provider;
  final String providerProductId;
  final PremiumProduct product;
  final int priceMinor;
}

/// One Family Member × product row of the parent's download sharing screen
/// (`artifact_download_permission_list`).
class DownloadPermission {
  const DownloadPermission({
    required this.memberUserId,
    required this.displayName,
    required this.relation,
    required this.relationLabel,
    required this.product,
    required this.granted,
    required this.productOwned,
  });

  factory DownloadPermission.fromJson(Map<String, dynamic> j) => DownloadPermission(
    memberUserId: j['member_user_id'] as String,
    displayName: (j['display_name'] as String?) ?? '',
    relation: j['relation'] as String?,
    relationLabel: j['relation_label'] as String?,
    product: PremiumProduct.fromCode(j['product_code'] as String)!,
    granted: j['granted'] as bool? ?? false,
    productOwned: j['product_owned'] as bool? ?? false,
  );

  final String memberUserId;
  final String displayName;
  final String? relation;
  final String? relationLabel;
  final PremiumProduct product;
  final bool granted;
  final bool productOwned;
}
