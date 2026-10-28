// Runs with `deno test` or `node --experimental-strip-types --test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ackAction,
  breakerLimitsFromEnv,
  decide,
  DEFAULT_BREAKER,
  evaluateBreaker,
  grantsAccess,
  isReplacement,
  planVoided,
  reconcileEventId,
  type StoredSubscription,
  voidedEventId,
  voidedWindow,
} from "../_shared/reconcile.ts";
import { googlePlayPayload, type GoogleSubscriptionV2 } from "../_shared/store_status.ts";

const NOW = Date.parse("2026-11-01T12:00:00Z");
const DAY = 86_400_000;
const iso = (ms: number) => new Date(ms).toISOString();

const stored = (over: Partial<StoredSubscription> = {}): StoredSubscription => ({
  subscription_id: "11111111-1111-4111-8111-111111111111",
  provider_subscription_id: "tok",
  status: "active",
  current_period_end: iso(NOW + 5 * DAY),
  cancel_at_period_end: false,
  ...over,
});

const google = (state: string, expiryMs: number, extra: Partial<GoogleSubscriptionV2> = {}, autoRenew = true): GoogleSubscriptionV2 => ({
  subscriptionState: state,
  startTime: iso(NOW - 30 * DAY),
  lineItems: [{
    productId: "small_family",
    expiryTime: iso(expiryMs),
    autoRenewingPlan: { autoRenewEnabled: autoRenew },
    offerDetails: { basePlanId: "monthly" },
  }],
  ...extra,
});

const run = (s: StoredSubscription, g: GoogleSubscriptionV2) => decide(s, g, googlePlayPayload("tok", g, NOW, iso(NOW)), NOW);

// Access rule (mirrors public.subscription_grants_access) --------------------------------------
test("two-day slack applies to trialing / active only", () => {
  assert.equal(grantsAccess("active", iso(NOW - 47 * 3_600_000), NOW), true);
  assert.equal(grantsAccess("active", iso(NOW - 49 * 3_600_000), NOW), false);
  assert.equal(grantsAccess("trialing", iso(NOW - DAY), NOW), true);
  assert.equal(grantsAccess("grace", iso(NOW - 30 * DAY), NOW), true);
  for (const s of ["past_due", "expired", "canceled"]) assert.equal(grantsAccess(s, iso(NOW + 30 * DAY), NOW), false, s);
  assert.equal(grantsAccess("active", null, NOW), true);
});

// Scenarios ---------------------------------------------------------------------------------------
test("monthly renewal: a later expiry is applied, not a downgrade", () => {
  const d = run(stored({ current_period_end: iso(NOW - 3_600_000) }), google("SUBSCRIPTION_STATE_ACTIVE", NOW + 30 * DAY));
  assert.equal(d.action, "apply");
  if (d.action === "apply") {
    assert.equal(d.downgrade, false);
    assert.equal(d.payload.status, "active");
    assert.equal(d.payload.current_period_end, iso(NOW + 30 * DAY));
  }
});

test("annual renewal behaves the same", () => {
  const d = run(stored({ current_period_end: iso(NOW - 2 * 3_600_000) }), google("SUBSCRIPTION_STATE_ACTIVE", NOW + 365 * DAY));
  assert.equal(d.action, "apply");
  if (d.action === "apply") assert.equal(d.downgrade, false);
});

test("user cancellation keeps access until the period ends", () => {
  const d = run(stored(), google("SUBSCRIPTION_STATE_CANCELED", NOW + 5 * DAY, {}, false));
  assert.equal(d.action, "apply");
  if (d.action === "apply") {
    assert.equal(d.payload.status, "active");
    assert.equal(d.payload.cancel_at_period_end, true);
    assert.equal(d.downgrade, false);
  }
});

test("grace period keeps access", () => {
  const d = run(stored({ current_period_end: iso(NOW - DAY) }), google("SUBSCRIPTION_STATE_IN_GRACE_PERIOD", NOW + 2 * DAY));
  assert.equal(d.action, "apply");
  if (d.action === "apply") {
    assert.equal(d.payload.status, "grace");
    assert.equal(d.downgrade, false);
  }
});

test("account hold and pause remove access (downgrade) only when Google says so", () => {
  for (const state of ["SUBSCRIPTION_STATE_ON_HOLD", "SUBSCRIPTION_STATE_PAUSED"]) {
    const d = run(stored(), google(state, NOW - DAY));
    assert.equal(d.action, "apply", state);
    if (d.action === "apply") {
      assert.equal(d.payload.status, "past_due");
      assert.equal(d.downgrade, true);
    }
  }
});

test("expiry and refund/revocation (EXPIRED) are downgrades of a running subscription", () => {
  const d = run(stored(), google("SUBSCRIPTION_STATE_EXPIRED", NOW - 60_000, { canceledStateContext: { developerInitiatedCancellation: {} } }));
  assert.equal(d.action, "apply");
  if (d.action === "apply") {
    assert.equal(d.payload.status, "expired");
    assert.equal(d.downgrade, true);
  }
});

test("a subscription that already lost access is not counted as a downgrade", () => {
  const d = run(stored({ current_period_end: iso(NOW - 10 * DAY) }), google("SUBSCRIPTION_STATE_EXPIRED", NOW - 10 * DAY));
  assert.equal(d.action, "apply");
  if (d.action === "apply") assert.equal(d.downgrade, false);
});

test("an unchanged state is skipped (no event rows every 15 minutes)", () => {
  const exp = NOW + 5 * DAY;
  const d = run(stored({ current_period_end: iso(exp) }), google("SUBSCRIPTION_STATE_ACTIVE", exp));
  assert.deepEqual(d, { action: "skip", reason: "unchanged" });
});

test("a pending purchase is never applied", () => {
  const g = google("SUBSCRIPTION_STATE_PENDING", NOW + DAY);
  assert.deepEqual(decide(stored(), g, googlePlayPayload("tok", g, NOW), NOW), { action: "skip", reason: "pending" });
});

test("plan change in Play: the replaced token is recognised and not expired", () => {
  const g = google("SUBSCRIPTION_STATE_EXPIRED", NOW - 60_000, { canceledStateContext: { replacementCancellation: {} } });
  assert.equal(isReplacement(g), true);
  assert.deepEqual(run(stored(), g), { action: "replaced" });
  assert.equal(isReplacement(google("SUBSCRIPTION_STATE_EXPIRED", NOW, { canceledStateContext: { userInitiatedCancellation: {} } })), false);
});

test("an unknown Google state throws and so changes nothing", () => {
  assert.throws(() => googlePlayPayload("tok", google("SUBSCRIPTION_STATE_SOMETHING_NEW", NOW), NOW), /unknown subscription state/);
});

// Circuit breaker ------------------------------------------------------------------------------------
test("breaker: few removals pass, a mass removal is blocked", () => {
  assert.deepEqual(evaluateBreaker(0, 40, 0), { blocked: false });
  assert.deepEqual(evaluateBreaker(3, 40, 0), { blocked: false });
  assert.deepEqual(evaluateBreaker(DEFAULT_BREAKER.maxPerRun, 100, 0), { blocked: false });
  assert.deepEqual(evaluateBreaker(DEFAULT_BREAKER.maxPerRun + 1, 100, 0), { blocked: true, reason: "per_run" });
});

test("breaker: ratio is judged only on a meaningful batch", () => {
  assert.deepEqual(evaluateBreaker(2, 4, 0), { blocked: false }); // 50 % of 4: normal on a small base
  assert.deepEqual(evaluateBreaker(9, 30, 0), { blocked: true, reason: "ratio" });
  assert.deepEqual(evaluateBreaker(3, 30, 0), { blocked: false });
});

test("breaker: earlier runs count (rolling hour)", () => {
  assert.deepEqual(evaluateBreaker(5, 100, 16), { blocked: true, reason: "per_hour" });
  assert.deepEqual(evaluateBreaker(5, 100, 15), { blocked: false });
  assert.deepEqual(evaluateBreaker(5, 100, 0), { blocked: false });
});

test("breaker limits can be tuned from the environment; bad values fall back", () => {
  const env: Record<string, string> = { RECONCILE_MAX_DOWNGRADES_PER_RUN: "3", RECONCILE_MAX_DOWNGRADE_RATIO: "abc", RECONCILE_MAX_DOWNGRADES_PER_HOUR: "" };
  const l = breakerLimitsFromEnv((n) => env[n]);
  assert.equal(l.maxPerRun, 3);
  assert.equal(l.maxRatio, DEFAULT_BREAKER.maxRatio);
  assert.equal(l.maxPerHour, DEFAULT_BREAKER.maxPerHour);
});

// Event ids -----------------------------------------------------------------------------------------------
test("event ids: stable inside an hour, new in the next, never the purchase token", () => {
  const p = googlePlayPayload("secret-token-value", google("SUBSCRIPTION_STATE_ACTIVE", NOW + DAY), NOW)!;
  const a = reconcileEventId("sub-1", p, NOW);
  assert.equal(a, reconcileEventId("sub-1", p, NOW + 60_000));
  assert.notEqual(a, reconcileEventId("sub-1", p, NOW + 2 * 3_600_000));
  assert.notEqual(a, reconcileEventId("sub-2", p, NOW));
  assert.ok(!a.includes("secret-token-value"));
  assert.equal(voidedEventId("order", "GPA.1", { status: "refunded" }), "reconcile-voided:GPA.1");
  assert.ok(voidedEventId("sub", "sub-1", { status: "expired", current_period_end: "x" }).startsWith("reconcile-voided:sub-1:expired"));
});

// Voided purchases -------------------------------------------------------------------------------------------
test("voided window: first run, overlap, retention gap", () => {
  const first = voidedWindow(null, NOW);
  assert.equal(first.startMs, NOW - 29 * DAY);
  assert.equal(first.gap, false);
  const normal = voidedWindow(NOW - 3_600_000, NOW);
  assert.equal(normal.startMs, NOW - 2 * 3_600_000);
  assert.equal(normal.gap, false);
  const stale = voidedWindow(NOW - 40 * DAY, NOW);
  assert.equal(stale.startMs, NOW - 29 * DAY);
  assert.equal(stale.gap, true);
});

test("voided plan: unknown purchases never reach the apply RPCs, duplicates collapse", () => {
  const plan = planVoided(
    [
      { purchaseToken: "tok-known", orderId: "GPA.sub.1" },
      { purchaseToken: "tok-known", orderId: "GPA.sub.2" },
      { purchaseToken: "tok-ghost", orderId: "GPA.ghost" },
      { purchaseToken: "tok-premium", orderId: "GPA.premium" },
      {},
    ],
    { tokens: ["tok-known"], orders: ["GPA.premium"] },
  );
  assert.deepEqual(plan.tokens, ["tok-known"]);
  assert.deepEqual(plan.orders, ["GPA.premium"]);
  assert.equal(plan.unknown, 2);
});

// Acknowledgement ------------------------------------------------------------------------------------------------
test("acknowledgement: only a running, stored entitlement, and not before the app had its chance", () => {
  const P = "ACKNOWLEDGEMENT_STATE_PENDING";
  const A = "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED";
  assert.equal(ackAction(A, "active", null, NOW), "note_acknowledged");
  assert.equal(ackAction(undefined, "active", null, NOW), "none");
  assert.equal(ackAction(P, "active", null, NOW), "note_pending");
  assert.equal(ackAction(P, "active", iso(NOW - 5 * 60_000), NOW), "note_pending");
  assert.equal(ackAction(P, "active", iso(NOW - 20 * 60_000), NOW), "acknowledge");
  assert.equal(ackAction(P, "grace", iso(NOW - 20 * 60_000), NOW), "acknowledge");
  // expired / on hold / refunded purchases are never acknowledged
  for (const s of ["expired", "past_due", "canceled"]) assert.equal(ackAction(P, s, iso(NOW - DAY), NOW), "none", s);
});
