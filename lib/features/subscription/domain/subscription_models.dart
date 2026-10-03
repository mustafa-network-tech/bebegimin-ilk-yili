import 'package:intl/intl.dart';

enum BillingPeriod {
  monthly('monthly', 'Aylık'),
  annual('annual', 'Yıllık');

  const BillingPeriod(this.key, this.label);

  final String key;
  final String label;

  static BillingPeriod fromKey(String? key) => key == 'annual' ? annual : monthly;
}

/// Display name of a plan code. Prices and capacities always come from the
/// server catalog, never from here.
String planName(String code) => switch (code) {
  'small_family' => 'Small Family',
  'normal_family' => 'Normal Family',
  'large_family' => 'Large Family',
  _ => code,
};

final _money = NumberFormat.currency(locale: 'tr_TR', symbol: '₺', decimalDigits: 2);

String formatMinor(int minor) => _money.format(minor / 100);

class PlanCatalogItem {
  const PlanCatalogItem({
    required this.planCode,
    required this.period,
    required this.maxParentSeats,
    required this.maxFamilyMembers,
    required this.priceMinor,
    required this.currency,
  });

  factory PlanCatalogItem.fromJson(Map<String, dynamic> j) => PlanCatalogItem(
    planCode: j['plan_code'] as String,
    period: BillingPeriod.fromKey(j['billing_period'] as String?),
    maxParentSeats: (j['max_parent_seats'] as num).toInt(),
    maxFamilyMembers: (j['max_family_members'] as num).toInt(),
    priceMinor: (j['price_minor'] as num).toInt(),
    currency: j['currency'] as String,
  );

  final String planCode;
  final BillingPeriod period;
  final int maxParentSeats;
  final int maxFamilyMembers;
  final int priceMinor;
  final String currency;
}

/// Catalog helpers (all numbers derived from catalog rows).
class PlanCatalog {
  const PlanCatalog(this.items);

  final List<PlanCatalogItem> items;

  List<PlanCatalogItem> forPeriod(BillingPeriod p) =>
      items.where((i) => i.period == p).toList()..sort((a, b) => a.maxFamilyMembers.compareTo(b.maxFamilyMembers));

  PlanCatalogItem? find(String code, BillingPeriod p) {
    for (final i in items) {
      if (i.planCode == code && i.period == p) return i;
    }
    return null;
  }

  /// Yearly saving of the annual price against 12 monthly payments.
  int? annualSavingMinor(String code) {
    final m = find(code, BillingPeriod.monthly);
    final a = find(code, BillingPeriod.annual);
    if (m == null || a == null) return null;
    return m.priceMinor * 12 - a.priceMinor;
  }
}

class FamilySubscription {
  const FamilySubscription({
    required this.planCode,
    required this.period,
    required this.status,
    required this.currentPeriodEnd,
    required this.cancelAtPeriodEnd,
    required this.overCapacity,
    required this.maxFamilyMembers,
    required this.priceMinor,
  });

  factory FamilySubscription.fromJson(Map<String, dynamic> j) => FamilySubscription(
    planCode: j['plan_code'] as String,
    period: BillingPeriod.fromKey(j['billing_period'] as String?),
    status: j['status'] as String,
    currentPeriodEnd: j['current_period_end'] == null ? null : DateTime.parse(j['current_period_end'] as String),
    cancelAtPeriodEnd: j['cancel_at_period_end'] as bool? ?? false,
    overCapacity: j['over_capacity'] as bool? ?? false,
    maxFamilyMembers: (j['max_family_members'] as num).toInt(),
    priceMinor: (j['price_minor'] as num).toInt(),
  );

  final String planCode;
  final BillingPeriod period;
  final String status;
  final DateTime? currentPeriodEnd;
  final bool cancelAtPeriodEnd;
  final bool overCapacity;
  final int maxFamilyMembers;
  final int priceMinor;

  bool get isLive => const {'trialing', 'active', 'grace', 'past_due'}.contains(status);

  String get statusLabel => switch (status) {
    'trialing' => 'Deneme süresinde',
    'active' => 'Aktif',
    'grace' => 'Ödeme bekleniyor (ek süre)',
    'past_due' => 'Ödeme gecikti',
    'canceled' => 'İptal edildi',
    'expired' => 'Süresi doldu',
    _ => status,
  };
}

class AccountMember {
  const AccountMember({
    required this.userId,
    required this.displayName,
    required this.isParent,
    required this.status,
    required this.relationshipLabel,
  });

  factory AccountMember.fromJson(Map<String, dynamic> j) => AccountMember(
    userId: j['user_id'] as String,
    displayName: j['display_name'] as String,
    isParent: j['role'] == 'parent',
    status: j['status'] as String,
    relationshipLabel: j['relationship_label'] as String?,
  );

  final String userId;
  final String displayName;
  final bool isParent;
  final String status;
  final String? relationshipLabel;

  String get statusLabel => switch (status) {
    'active' => 'Aktif',
    'invited' => 'Davet edildi',
    'suspended' => 'Askıda',
    _ => status,
  };
}

class FamilyAccountOverview {
  const FamilyAccountOverview({
    required this.id,
    required this.displayName,
    required this.isParent,
    required this.subscription,
    required this.subscriptionLive,
    required this.enforcement,
    required this.activeParents,
    required this.activeFamilyMembers,
    required this.babies,
    required this.members,
  });

  factory FamilyAccountOverview.fromJson(Map<String, dynamic> j) => FamilyAccountOverview(
    id: j['id'] as String,
    displayName: j['display_name'] as String,
    isParent: j['my_role'] == 'parent',
    subscription: j['subscription'] == null
        ? null
        : FamilySubscription.fromJson((j['subscription'] as Map).cast<String, dynamic>()),
    subscriptionLive: j['subscription_live'] as bool? ?? false,
    enforcement: j['enforcement'] as bool? ?? false,
    activeParents: (j['active_parents'] as num).toInt(),
    activeFamilyMembers: (j['active_family_members'] as num).toInt(),
    babies: [for (final b in (j['babies'] as List? ?? const [])) ((b as Map)['first_name'] as String)],
    members: [
      for (final m in (j['members'] as List? ?? const [])) AccountMember.fromJson((m as Map).cast<String, dynamic>()),
    ],
  );

  final String id;
  final String displayName;
  final bool isParent;
  final FamilySubscription? subscription;
  final bool subscriptionLive;
  final bool enforcement;
  final int activeParents;
  final int activeFamilyMembers;
  final List<String> babies;
  final List<AccountMember> members;

  /// Capacity of the live plan; `null` without a live subscription.
  int? get capacity => subscriptionLive ? subscription?.maxFamilyMembers : null;

  bool get isFull => capacity != null && activeFamilyMembers >= capacity!;

  bool get overCapacity => subscriptionLive && (subscription?.overCapacity ?? false);
}

class CheckoutIntent {
  const CheckoutIntent({
    required this.intentId,
    required this.provider,
    required this.providerProductId,
    required this.planCode,
    required this.period,
    required this.priceMinor,
    required this.wouldExceedCapacity,
  });

  factory CheckoutIntent.fromJson(Map<String, dynamic> j) => CheckoutIntent(
    intentId: j['intent_id'] as String,
    provider: j['provider'] as String,
    providerProductId: j['provider_product_id'] as String,
    planCode: j['plan_code'] as String,
    period: BillingPeriod.fromKey(j['billing_period'] as String?),
    priceMinor: (j['price_minor'] as num).toInt(),
    wouldExceedCapacity: j['would_exceed_capacity'] as bool? ?? false,
  );

  final String intentId;
  final String provider;

  /// Store product id (App Store product / Google `productId:basePlanId`).
  final String providerProductId;
  final String planCode;
  final BillingPeriod period;
  final int priceMinor;
  final bool wouldExceedCapacity;
}

/// Why the app is open or sends the family to the payment page.
enum AccessReason {
  ok,
  enforcementOff,
  noSubscription,
  subscriptionEnded,
  paymentIssue,
  accountUnmapped;

  static AccessReason fromKey(String? key) => switch (key) {
    'ok' => ok,
    'enforcement_off' => enforcementOff,
    'no_subscription' => noSubscription,
    'payment_issue' => paymentIssue,
    'account_unmapped' => accountUnmapped,
    _ => subscriptionEnded,
  };
}

/// Server decision for one baby: may the family use the archive?
class BabyAccessState {
  const BabyAccessState({
    required this.babyId,
    required this.allowed,
    required this.reason,
    required this.isParent,
    required this.familyAccountId,
  });

  factory BabyAccessState.fromJson(String babyId, Map<String, dynamic> j) => BabyAccessState(
    babyId: babyId,
    allowed: j['allowed'] as bool? ?? false,
    reason: AccessReason.fromKey(j['reason'] as String?),
    isParent: j['is_parent'] as bool? ?? false,
    familyAccountId: j['family_account_id'] as String?,
  );

  final String babyId;
  final bool allowed;
  final AccessReason reason;
  final bool isParent;
  final String? familyAccountId;

  String get title => switch (reason) {
    AccessReason.noSubscription => 'Aile paketi gerekli',
    AccessReason.paymentIssue => 'Ödeme alınamadı',
    AccessReason.accountUnmapped => 'Aile hesabı eşleştiriliyor',
    _ => 'Aile paketinizin süresi doldu',
  };

  String get message => switch (reason) {
    AccessReason.accountUnmapped =>
      'Bu bebeğin aile hesabı henüz eşleştirilmedi. Destek ekibimiz eşleştirmeyi tamamladığında devam edebilirsiniz.',
    AccessReason.paymentIssue when isParent =>
      'Mağaza ödemeyi alamadı. Ödeme yönteminizi güncelleyin ya da yeni bir paket seçin. Anılarınız güvende.',
    _ when isParent =>
      'Arşiviniz salt okunur: anıları, albümü ve takvimi görüntülemeye devam edebilirsiniz. Yeni içerik eklemek ve '
          'düzenlemek için aile paketini seçin veya yenileyin; hiçbir şey silinmedi.',
    _ =>
      'Ailenizin paketi aktif değil; arşiv salt okunur. Görüntülemeye devam edebilirsiniz. Anne veya Baba paketi '
          'yenilediğinde yeniden içerik ekleyebilirsiniz; hiçbir şey silinmedi.',
  };
}
