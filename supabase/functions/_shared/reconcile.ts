// Pure decision logic of the scheduled Google Play reconciliation. No I/O and no
// Deno APIs (unit-tested in ../tests/reconcile.test.ts).
//
// Principles:
//  * Only an explicit state read from Google may change a subscription. An API
//    error, an unknown state or a missing field never removes access.
//  * A removal of access (a "downgrade") needs the circuit breaker's consent.
//  * Everything is applied through billing_apply_event / premium_apply_event.
import type { GoogleSubscriptionV2, NormalizedPayload } from "./store_status.ts";
import type { GoogleVoidedPurchase } from "./google_play.ts";

/** Mirrors public.subscription_grants_access(): two days of slack for trialing / active. */
export const ACCESS_SLACK_MS = 2 * 24 * 60 * 60 * 1000;

export type StoredSubscription = {
  subscription_id: string;
  provider_subscription_id: string;
  status: string;
  current_period_end: string | null;
  cancel_at_period_end: boolean | null;
};

export function grantsAccess(status: string, periodEndIso: string | null | undefined, nowMs: number): boolean {
  if (status === "grace") return true;
  if (status !== "trialing" && status !== "active") return false;
  if (!periodEndIso) return true;
  return Date.parse(periodEndIso) > nowMs - ACCESS_SLACK_MS;
}

export type Decision =
  | { action: "skip"; reason: "pending" | "unchanged" }
  // Play moved the user to a new purchase token (plan change): only the app can link it.
  | { action: "replaced" }
  | { action: "apply"; downgrade: boolean; payload: NormalizedPayload };

/** True when Google says this token ended because another purchase replaced it. */
export function isReplacement(sub: GoogleSubscriptionV2): boolean {
  return sub.subscriptionState === "SUBSCRIPTION_STATE_EXPIRED" &&
    sub.canceledStateContext?.replacementCancellation != null;
}

const sameInstant = (a: string | null | undefined, b: string | null | undefined) => {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return Date.parse(a) === Date.parse(b);
};

export function decide(
  stored: StoredSubscription,
  sub: GoogleSubscriptionV2,
  payload: NormalizedPayload | null,
  nowMs: number,
): Decision {
  if (payload === null) return { action: "skip", reason: "pending" };
  if (isReplacement(sub)) return { action: "replaced" };
  if (
    stored.status === payload.status &&
    sameInstant(stored.current_period_end, payload.current_period_end) &&
    (stored.cancel_at_period_end ?? false) === (payload.cancel_at_period_end ?? false)
  ) {
    return { action: "skip", reason: "unchanged" };
  }
  const before = grantsAccess(stored.status, stored.current_period_end, nowMs);
  const after = grantsAccess(payload.status, payload.current_period_end, nowMs);
  return { action: "apply", downgrade: before && !after, payload };
}

export type BreakerLimits = {
  maxPerRun: number; // removals of access in one run
  maxRatio: number; // share of the checked subscriptions (only judged from minChecked on)
  minChecked: number;
  maxPerHour: number; // including the removals applied in the last hour
};

export const DEFAULT_BREAKER: BreakerLimits = { maxPerRun: 10, maxRatio: 0.2, minChecked: 20, maxPerHour: 20 };

export type BreakerVerdict = { blocked: boolean; reason?: "per_run" | "ratio" | "per_hour" };

/**
 * Decides whether this run may remove access. When it may not, none of the removals is
 * applied (renewals and other updates still are) and the run is reported as blocked.
 */
export function evaluateBreaker(
  downgrades: number,
  checked: number,
  recentDowngrades: number,
  limits: BreakerLimits = DEFAULT_BREAKER,
): BreakerVerdict {
  if (downgrades <= 0) return { blocked: false };
  if (downgrades > limits.maxPerRun) return { blocked: true, reason: "per_run" };
  if (checked >= limits.minChecked && downgrades / checked > limits.maxRatio) return { blocked: true, reason: "ratio" };
  if (recentDowngrades + downgrades > limits.maxPerHour) return { blocked: true, reason: "per_hour" };
  return { blocked: false };
}

export function breakerLimitsFromEnv(get: (name: string) => string | undefined): BreakerLimits {
  const num = (name: string, fallback: number) => {
    const n = Number(get(name));
    return Number.isFinite(n) && n >= 0 && get(name) !== undefined && get(name) !== "" ? n : fallback;
  };
  return {
    maxPerRun: num("RECONCILE_MAX_DOWNGRADES_PER_RUN", DEFAULT_BREAKER.maxPerRun),
    maxRatio: num("RECONCILE_MAX_DOWNGRADE_RATIO", DEFAULT_BREAKER.maxRatio),
    minChecked: num("RECONCILE_RATIO_MIN_CHECKED", DEFAULT_BREAKER.minChecked),
    maxPerHour: num("RECONCILE_MAX_DOWNGRADES_PER_HOUR", DEFAULT_BREAKER.maxPerHour),
  };
}

/**
 * Event id for billing_apply_event. Built from the subscription row id (never the purchase
 * token), the new state and an hourly bucket: the same read inside one hour is a duplicate,
 * a state that flips back later is applied again.
 */
export function reconcileEventId(subscriptionId: string, payload: NormalizedPayload, nowMs: number): string {
  const end = payload.current_period_end ? Date.parse(payload.current_period_end) : 0;
  const bucket = Math.floor(nowMs / 3_600_000);
  return `reconcile:${subscriptionId}:${payload.status}:${end}:${payload.cancel_at_period_end ? 1 : 0}:${bucket}`;
}

export function voidedEventId(kind: "sub" | "order", ref: string, payload: { status: string; current_period_end?: string }): string {
  return kind === "sub"
    ? `reconcile-voided:${ref}:${payload.status}:${payload.current_period_end ?? ""}`
    : `reconcile-voided:${ref}`;
}

// Voided purchases ---------------------------------------------------------------------

/** Google keeps voided purchases for about 30 days. */
export const VOIDED_RETENTION_MS = 29 * 24 * 60 * 60 * 1000;
export const VOIDED_OVERLAP_MS = 60 * 60 * 1000;

export type VoidedWindow = { startMs: number; endMs: number; gap: boolean };

/**
 * The window to read. The overlap re-reads the last hour (every apply is idempotent); a
 * cursor older than the retention means records may have been lost: `gap` is reported.
 */
export function voidedWindow(cursorMs: number | null, nowMs: number): VoidedWindow {
  const floor = nowMs - VOIDED_RETENTION_MS;
  if (cursorMs === null) return { startMs: floor, endMs: nowMs, gap: false };
  const start = cursorMs - VOIDED_OVERLAP_MS;
  return { startMs: Math.max(start, floor), endMs: nowMs, gap: start < floor };
}

export type VoidedPlan = {
  tokens: string[];
  orders: string[];
  unknown: number;
};

/** Splits the voided items by what we know. Unknown ones never reach the apply RPCs. */
export function planVoided(
  items: GoogleVoidedPurchase[],
  known: { tokens: string[]; orders: string[] },
): VoidedPlan {
  const knownTokens = new Set(known.tokens);
  const knownOrders = new Set(known.orders);
  const tokens = new Set<string>();
  const orders = new Set<string>();
  let unknown = 0;
  for (const item of items) {
    if (item.purchaseToken && knownTokens.has(item.purchaseToken)) tokens.add(item.purchaseToken);
    else if (item.orderId && knownOrders.has(item.orderId)) orders.add(item.orderId);
    else unknown++;
  }
  return { tokens: [...tokens], orders: [...orders], unknown };
}

// Acknowledgement ----------------------------------------------------------------------

/** Wait before the server acknowledges, so the app normally acknowledges first. */
export const ACK_APP_HEAD_START_MS = 15 * 60 * 1000;

export type AckAction = "none" | "note_pending" | "acknowledge" | "note_acknowledged";

/**
 * What to do with the acknowledgement of a subscription whose entitlement is stored.
 * `payloadStatus` is the verified state. Only a paid, running subscription is acknowledged.
 */
export function ackAction(
  googleAckState: string | undefined,
  payloadStatus: string,
  ackFirstSeenIso: string | null,
  nowMs: number,
): AckAction {
  if (googleAckState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED") return "note_acknowledged";
  if (googleAckState !== "ACKNOWLEDGEMENT_STATE_PENDING") return "none";
  if (payloadStatus !== "active" && payloadStatus !== "trialing" && payloadStatus !== "grace") return "none";
  if (!ackFirstSeenIso) return "note_pending";
  return nowMs - Date.parse(ackFirstSeenIso) >= ACK_APP_HEAD_START_MS ? "acknowledge" : "note_pending";
}
