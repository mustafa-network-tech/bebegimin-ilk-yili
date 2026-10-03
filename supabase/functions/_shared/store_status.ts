// Pure mapping from verified store data to the normalised payload accepted
// by public.billing_apply_event(). No I/O and no Deno APIs, so it can be
// unit-tested anywhere (see ../tests/store_status.test.ts).

export type NormalizedPayload = {
  provider_subscription_id: string;
  previous_provider_subscription_id?: string;
  provider_product_id: string;
  status: "trialing" | "active" | "grace" | "past_due" | "canceled" | "expired";
  bound_intent_id?: string;
  checkout_intent_id?: string;
  current_period_start?: string;
  current_period_end?: string;
  cancel_at_period_end?: boolean;
  event_time?: string;
};

// App Store ----------------------------------------------------------------------------
// Fields of JWSTransactionDecodedPayload / JWSRenewalInfoDecodedPayload we use
// (dates are epoch milliseconds, as Apple sends them).
export type AppleTransaction = {
  originalTransactionId: string;
  transactionId?: string;
  productId: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
  appAccountToken?: string;
  offerType?: number;
  signedDate?: number;
};

export type AppleRenewalInfo = {
  autoRenewStatus?: number; // 1 = on, 0 = off
  gracePeriodExpiresDate?: number;
  isInBillingRetryPeriod?: boolean;
  signedDate?: number;
};

const iso = (ms?: number) => (ms == null ? undefined : new Date(ms).toISOString());

export function appStorePayload(
  tx: AppleTransaction,
  renewal: AppleRenewalInfo | undefined,
  nowMs: number,
  eventTimeMs?: number,
): NormalizedPayload {
  let status: NormalizedPayload["status"];
  if (tx.revocationDate != null) {
    status = "expired"; // refunded / revoked
  } else if (tx.expiresDate != null && tx.expiresDate > nowMs) {
    status = tx.offerType === 1 ? "trialing" : "active";
  } else if (renewal?.gracePeriodExpiresDate != null && renewal.gracePeriodExpiresDate > nowMs) {
    status = "grace";
  } else if (renewal?.isInBillingRetryPeriod) {
    status = "past_due";
  } else {
    status = "expired";
  }
  return {
    provider_subscription_id: tx.originalTransactionId,
    provider_product_id: tx.productId,
    status,
    bound_intent_id: tx.appAccountToken || undefined,
    current_period_start: iso(tx.purchaseDate),
    current_period_end: iso(tx.expiresDate),
    cancel_at_period_end: renewal?.autoRenewStatus === 0,
    event_time: iso(eventTimeMs ?? tx.signedDate),
  };
}

// Google Play ------------------------------------------------------------------------------
// Subset of purchases.subscriptionsv2 (SubscriptionPurchaseV2).
export type GoogleSubscriptionV2 = {
  subscriptionState?: string;
  startTime?: string;
  linkedPurchaseToken?: string;
  externalAccountIdentifiers?: { obfuscatedExternalAccountId?: string };
  lineItems?: Array<{
    productId: string;
    expiryTime?: string;
    autoRenewingPlan?: { autoRenewEnabled?: boolean };
    offerDetails?: { basePlanId?: string };
  }>;
};

/** `null` when the purchase is not paid yet (pending) and must not be applied. */
export function googlePlayPayload(
  purchaseToken: string,
  sub: GoogleSubscriptionV2,
  nowMs: number,
  eventTimeIso?: string,
): NormalizedPayload | null {
  const item = sub.lineItems?.[0];
  if (!item || !item.offerDetails?.basePlanId) throw new Error("subscription has no line item");
  const expiry = item.expiryTime ? Date.parse(item.expiryTime) : undefined;
  let status: NormalizedPayload["status"];
  switch (sub.subscriptionState) {
    case "SUBSCRIPTION_STATE_ACTIVE":
      status = "active";
      break;
    case "SUBSCRIPTION_STATE_IN_GRACE_PERIOD":
      status = "grace";
      break;
    case "SUBSCRIPTION_STATE_ON_HOLD":
    case "SUBSCRIPTION_STATE_PAUSED":
      status = "past_due";
      break;
    case "SUBSCRIPTION_STATE_CANCELED":
      // Auto-renew is off; access continues until the paid period ends.
      status = expiry != null && expiry > nowMs ? "active" : "expired";
      break;
    case "SUBSCRIPTION_STATE_EXPIRED":
    case "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED":
      status = "expired";
      break;
    case "SUBSCRIPTION_STATE_PENDING":
      return null;
    default:
      throw new Error(`unknown subscription state ${sub.subscriptionState}`);
  }
  return {
    provider_subscription_id: purchaseToken,
    previous_provider_subscription_id: sub.linkedPurchaseToken || undefined,
    provider_product_id: `${item.productId}:${item.offerDetails.basePlanId}`,
    status,
    bound_intent_id: sub.externalAccountIdentifiers?.obfuscatedExternalAccountId || undefined,
    current_period_start: sub.startTime,
    current_period_end: item.expiryTime,
    cancel_at_period_end: item.autoRenewingPlan?.autoRenewEnabled === false,
    event_time: eventTimeIso,
  };
}

// Premium one-time products ---------------------------------------------------------------
export type PremiumPayload = {
  provider_order_ref: string;
  provider_product_id?: string;
  status: "paid" | "canceled" | "refunded" | "revoked";
  bound_order_id?: string;
  order_id?: string;
  price_minor?: number;
  currency?: string;
  event_time?: string;
};

/** Apple transaction fields for one-time (consumable) purchases. */
export type AppleOneTimeTransaction = AppleTransaction & {
  type?: string;
  price?: number; // milliunits of the currency
  currency?: string;
};

export const isAppleSubscription = (tx: { type?: string }) => tx.type === "Auto-Renewable Subscription";

export function appStoreOneTimePayload(tx: AppleOneTimeTransaction, eventTimeMs?: number): PremiumPayload {
  return {
    provider_order_ref: tx.transactionId ?? tx.originalTransactionId,
    provider_product_id: tx.productId,
    status: tx.revocationDate != null ? "refunded" : "paid",
    bound_order_id: tx.appAccountToken || undefined,
    // Apple reports prices in milliunits; the catalog stores minor units (kuruş).
    price_minor: tx.price != null ? Math.round(tx.price / 10) : undefined,
    currency: tx.currency || undefined,
    event_time: iso(eventTimeMs ?? tx.signedDate),
  };
}

/** Subset of purchases.products (ProductPurchase). */
export type GoogleProductPurchase = {
  purchaseState?: number; // 0 purchased, 1 canceled, 2 pending
  orderId?: string;
  obfuscatedExternalAccountId?: string;
  regionCode?: string;
};

/** `null` while the payment is pending. */
export function googlePlayProductPayload(
  productId: string,
  purchaseToken: string,
  p: GoogleProductPurchase,
  eventTimeIso?: string,
): PremiumPayload | null {
  let status: PremiumPayload["status"];
  switch (p.purchaseState) {
    case 0:
      status = "paid";
      break;
    case 1:
      status = "canceled";
      break;
    case 2:
      return null;
    default:
      throw new Error(`unknown purchase state ${p.purchaseState}`);
  }
  return {
    provider_order_ref: p.orderId || purchaseToken,
    provider_product_id: productId,
    status,
    bound_order_id: p.obfuscatedExternalAccountId || undefined,
    event_time: eventTimeIso,
  };
}

/** Google voided purchase (refund / chargeback) of a one-time product. */
export function googleVoidedPayload(orderId: string, eventTimeIso?: string): PremiumPayload {
  return { provider_order_ref: orderId, status: "refunded", event_time: eventTimeIso };
}
