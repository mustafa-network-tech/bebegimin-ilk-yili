// Runs with `deno test` or `node --experimental-strip-types --test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  appStoreOneTimePayload,
  appStorePayload,
  googlePlayPayload,
  googlePlayProductPayload,
  googleVoidedPayload,
  isAppleSubscription,
} from "../_shared/store_status.ts";

const now = Date.parse("2026-09-29T12:00:00Z");
const day = 86_400_000;

test("App Store: active renewing subscription bound to the checkout intent", () => {
  const p = appStorePayload(
    {
      originalTransactionId: "1000",
      productId: "bebegimin.small_family.monthly",
      purchaseDate: now - day,
      expiresDate: now + 29 * day,
      appAccountToken: "8d2c1a52-0000-4000-8000-000000000001",
      signedDate: now,
    },
    { autoRenewStatus: 1 },
    now,
  );
  assert.equal(p.status, "active");
  assert.equal(p.provider_subscription_id, "1000");
  assert.equal(p.bound_intent_id, "8d2c1a52-0000-4000-8000-000000000001");
  assert.equal(p.cancel_at_period_end, false);
  assert.equal(p.event_time, new Date(now).toISOString());
});

test("App Store: auto-renew off stays active until the period ends", () => {
  const p = appStorePayload(
    { originalTransactionId: "1", productId: "x", expiresDate: now + day },
    { autoRenewStatus: 0 },
    now,
  );
  assert.equal(p.status, "active");
  assert.equal(p.cancel_at_period_end, true);
});

test("App Store: grace period, billing retry, expiry and refund", () => {
  const tx = { originalTransactionId: "1", productId: "x", expiresDate: now - day };
  assert.equal(appStorePayload(tx, { gracePeriodExpiresDate: now + day }, now).status, "grace");
  assert.equal(appStorePayload(tx, { isInBillingRetryPeriod: true }, now).status, "past_due");
  assert.equal(appStorePayload(tx, {}, now).status, "expired");
  assert.equal(
    appStorePayload({ ...tx, expiresDate: now + day, revocationDate: now }, {}, now).status,
    "expired",
  );
});

test("App Store: free trial offer maps to trialing", () => {
  const p = appStorePayload({ originalTransactionId: "1", productId: "x", expiresDate: now + day, offerType: 1 }, {}, now);
  assert.equal(p.status, "trialing");
});

test("Google Play: active base plan with account binding and linked token", () => {
  const p = googlePlayPayload(
    "token-B",
    {
      subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
      startTime: "2026-09-01T00:00:00Z",
      linkedPurchaseToken: "token-A",
      externalAccountIdentifiers: { obfuscatedExternalAccountId: "intent-1" },
      lineItems: [{
        productId: "normal_family",
        expiryTime: "2026-10-29T00:00:00Z",
        autoRenewingPlan: { autoRenewEnabled: true },
        offerDetails: { basePlanId: "monthly" },
      }],
    },
    now,
  );
  assert.ok(p);
  assert.equal(p.provider_product_id, "normal_family:monthly");
  assert.equal(p.previous_provider_subscription_id, "token-A");
  assert.equal(p.bound_intent_id, "intent-1");
  assert.equal(p.status, "active");
});

test("Google Play: canceled keeps access until expiry, then expires", () => {
  const item = (expiryTime: string) => ({
    subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
    lineItems: [{
      productId: "small_family",
      expiryTime,
      autoRenewingPlan: { autoRenewEnabled: false },
      offerDetails: { basePlanId: "annual" },
    }],
  });
  const future = googlePlayPayload("t", item("2026-10-10T00:00:00Z"), now);
  assert.equal(future?.status, "active");
  assert.equal(future?.cancel_at_period_end, true);
  assert.equal(googlePlayPayload("t", item("2026-09-01T00:00:00Z"), now)?.status, "expired");
});

test("Google Play: grace, on hold, pending", () => {
  const base = { lineItems: [{ productId: "small_family", offerDetails: { basePlanId: "monthly" } }] };
  assert.equal(googlePlayPayload("t", { ...base, subscriptionState: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" }, now)?.status, "grace");
  assert.equal(googlePlayPayload("t", { ...base, subscriptionState: "SUBSCRIPTION_STATE_ON_HOLD" }, now)?.status, "past_due");
  assert.equal(googlePlayPayload("t", { ...base, subscriptionState: "SUBSCRIPTION_STATE_PENDING" }, now), null);
  assert.throws(() => googlePlayPayload("t", { ...base, subscriptionState: "WHATEVER" }, now));
});

test("App Store one-time: paid with price in kuruş, refund revokes", () => {
  const tx = {
    originalTransactionId: "5",
    transactionId: "5",
    productId: "bebegimin.first_year_book",
    type: "Consumable",
    price: 349000,
    currency: "TRY",
    appAccountToken: "order-1",
  };
  const paid = appStoreOneTimePayload(tx);
  assert.equal(paid.status, "paid");
  assert.equal(paid.price_minor, 34900);
  assert.equal(paid.currency, "TRY");
  assert.equal(paid.bound_order_id, "order-1");
  assert.equal(isAppleSubscription(tx), false);
  assert.equal(appStoreOneTimePayload({ ...tx, revocationDate: now }).status, "refunded");
  assert.equal(isAppleSubscription({ type: "Auto-Renewable Subscription" }), true);
});

test("Google one-time: purchased, canceled, pending, voided", () => {
  const p = googlePlayProductPayload("first_year_film", "tok", {
    purchaseState: 0,
    orderId: "GPA.1",
    obfuscatedExternalAccountId: "order-2",
  });
  assert.equal(p?.status, "paid");
  assert.equal(p?.provider_order_ref, "GPA.1");
  assert.equal(p?.bound_order_id, "order-2");
  assert.equal(googlePlayProductPayload("x", "tok", { purchaseState: 1 })?.status, "canceled");
  assert.equal(googlePlayProductPayload("x", "tok", { purchaseState: 2 }), null);
  assert.equal(googleVoidedPayload("GPA.1").status, "refunded");
});
