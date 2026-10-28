// Scheduled Google Play reconciliation (pg_cron + pg_net, every 15 minutes), the
// replacement for RTDN while RTDN is not set up:
//   1. renewals / cancellations / grace / hold / expiry / refunds of the subscriptions
//      that are due (purchases.subscriptionsv2.get),
//   2. server-side acknowledgement of verified purchases the app has not acknowledged,
//   3. refunds and revocations (purchases.voidedpurchases.list, hourly).
// State changes go through the same RPCs as the store notifications:
// public.billing_apply_event / public.premium_apply_event.
//
// Called with the header `x-reconcile-secret` (secret BILLING_RECONCILE_SECRET), never with a
// user JWT (verify_jwt = false). Off by default: the platform flag `billing_reconcile`
// must be enabled, and `billing_reconcile_dry_run` (default on) makes it read-only.
//
// Only counters and safe codes are logged / returned: no purchase tokens, keys or user data.
import { createClient } from "npm:@supabase/supabase-js@2";
import { json, safeEqual } from "../_shared/cors.ts";
import {
  googleAcknowledgeSubscription,
  googleSubscription,
  googleVoidedPurchases,
} from "../_shared/google_play.ts";
import { googlePlayPayload, googleVoidedPayload, type NormalizedPayload } from "../_shared/store_status.ts";
import { toBillingError } from "../_shared/billing_errors.ts";
import {
  ackAction,
  breakerLimitsFromEnv,
  decide,
  evaluateBreaker,
  planVoided,
  reconcileEventId,
  type StoredSubscription,
  voidedEventId,
  voidedWindow,
} from "../_shared/reconcile.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CHUNK = 10; // subscriptions claimed at a time
const CONCURRENCY = 5;
const DEFAULT_MAX_CHECKS = 40; // Google calls per run (quota)
const TIME_BUDGET_MS = 100_000;
const VOIDED_EVERY_MS = 55 * 60 * 1000;
const VOIDED_MAX_PAGES = 10;
const MAX_TEMPORARY_ERRORS = 3; // stop the run when Google keeps failing / throttling

type Claimed = StoredSubscription & { failure_count: number; ack_state: string; ack_first_seen_at: string | null };

type Counters = {
  checked: number;
  changed: number;
  downgrades: number;
  failed: number;
  acked: number;
  voided_seen: number;
  voided_applied: number;
  blocked: boolean;
  codes: Record<string, number>;
};

const bump = (c: Counters, code: string) => {
  c.codes[code] = (c.codes[code] ?? 0) + 1;
};

function envNumber(name: string, fallback: number): number {
  const n = Number(Deno.env.get(name));
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i]);
      }
    }),
  );
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const expected = Deno.env.get("BILLING_RECONCILE_SECRET");
  if (!expected) {
    console.error(JSON.stringify({ fn: "billing-reconcile", code: "not_configured" }));
    return json({ error: "not_configured" }, 503);
  }
  if (!safeEqual(req.headers.get("x-reconcile-secret") ?? "", expected)) return json({ error: "unauthorized" }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const startedAt = new Date();
  const { data: cfg, error: cfgError } = await admin.rpc("billing_reconcile_config");
  if (cfgError) {
    console.error(JSON.stringify({ fn: "billing-reconcile", code: "temporary_error", stage: "config" }));
    return json({ error: "temporary_error" }, 503);
  }
  if (!cfg?.enabled) return json({ result: "disabled" });

  // A caller can only make a run safer, never more live.
  let forceDry = false;
  try {
    forceDry = (await req.json())?.dry_run === true;
  } catch (_) { /* empty body */ }
  const dryRun = forceDry || cfg.dry_run !== false;

  const limits = breakerLimitsFromEnv((n) => Deno.env.get(n));
  const maxChecks = envNumber("RECONCILE_MAX_CHECKS", DEFAULT_MAX_CHECKS);
  const c: Counters = { checked: 0, changed: 0, downgrades: 0, failed: 0, acked: 0, voided_seen: 0, voided_applied: 0, blocked: false, codes: {} };

  const { data: recentRaw } = await admin.rpc("billing_reconcile_recent_downgrades", { p_minutes: 60 });
  const recentDowngrades = Number(recentRaw ?? 0);

  // Removing access needs the breaker's consent; once it trips, the whole run is read-only for removals.
  const mayDowngrade = (extra: number, checked: number): boolean => {
    if (c.blocked) return false;
    const verdict = evaluateBreaker(c.downgrades + extra, checked, recentDowngrades, limits);
    if (verdict.blocked) {
      c.blocked = true;
      bump(c, `circuit_${verdict.reason}`);
      console.error(JSON.stringify({ fn: "billing-reconcile", code: "circuit_open", reason: verdict.reason }));
      return false;
    }
    return true;
  };

  const applySubscription = async (row: Claimed, payload: NormalizedPayload, nowMs: number, eventId?: string) => {
    const p = { ...payload };
    delete p.bound_intent_id; // the subscription already exists; the intent is irrelevant here
    const { data, error } = await admin.rpc("billing_apply_event", {
      p_provider: "google_play",
      p_provider_event_id: eventId ?? reconcileEventId(row.subscription_id, p, nowMs),
      p_event_type: "reconcile",
      p_payload: p,
    });
    if (error) throw new Error("rpc");
    return String(data);
  };

  type Read = {
    row: Claimed;
    nowMs: number;
    googleAck?: string;
    payload?: NormalizedPayload | null;
    decision?: ReturnType<typeof decide>;
    code?: string;
  };

  const read = async (row: Claimed): Promise<Read> => {
    const nowMs = Date.now();
    try {
      const sub = await googleSubscription(row.provider_subscription_id);
      const payload = googlePlayPayload(row.provider_subscription_id, sub, nowMs, new Date(nowMs).toISOString());
      return { row, nowMs, googleAck: sub.acknowledgementState, payload, decision: decide(row, sub, payload, nowMs) };
    } catch (e) {
      return { row, nowMs, code: toBillingError(e).code };
    }
  };

  const noteAck = async (row: Claimed, ack: "pending" | "acknowledged" | "failed", code?: string) => {
    if (dryRun) return;
    await admin.rpc("billing_reconcile_note_ack", { p_provider_subscription_id: row.provider_subscription_id, p_ack: ack, p_error_code: code ?? null });
  };

  const finish = async (row: Claimed, outcome: "ok" | "error" | "replaced" | "skipped", code?: string) => {
    await admin.rpc("billing_reconcile_finish", { p_subscription_id: row.subscription_id, p_outcome: outcome, p_error_code: code ?? null });
  };

  // 1. Due subscriptions, in small chunks ------------------------------------------------------
  let temporaryErrors = 0;
  while (c.checked < maxChecks && Date.now() - startedAt.getTime() < TIME_BUDGET_MS && temporaryErrors < MAX_TEMPORARY_ERRORS) {
    const { data: claimed, error } = await admin.rpc("billing_reconcile_claim", {
      p_limit: Math.min(CHUNK, maxChecks - c.checked),
      p_lease_seconds: 600,
    });
    if (error) {
      bump(c, "claim_failed");
      break;
    }
    const rows = (claimed ?? []) as Claimed[];
    if (rows.length === 0) break;

    const reads = await mapLimit(rows, CONCURRENCY, read);
    c.checked += reads.length;
    const wanted = reads.filter((r) => r.decision?.action === "apply" && r.decision.downgrade).length;
    const downgradeOk = wanted === 0 || mayDowngrade(wanted, c.checked);

    for (const r of reads) {
      try {
        if (r.code) {
          // Google failed: nothing about the subscription is assumed. Back off and look again.
          bump(c, r.code);
          c.failed++;
          if (r.code === "temporary_error") temporaryErrors++;
          await finish(r.row, "error", r.code);
          continue;
        }
        const d = r.decision!;
        if (d.action === "replaced") {
          bump(c, "replaced");
          await finish(r.row, dryRun ? "skipped" : "replaced", "replaced");
          continue;
        }
        let entitlementStored = d.action === "skip" && d.reason === "unchanged";
        let abort = false;
        if (d.action === "apply") {
          if (d.downgrade && (!downgradeOk || dryRun)) {
            bump(c, dryRun ? "would_downgrade" : "downgrade_blocked");
            if (!dryRun) await finish(r.row, "error", "circuit_open");
            else await finish(r.row, "skipped");
            abort = true;
          } else if (dryRun) {
            bump(c, "would_change");
            await finish(r.row, "skipped");
            abort = true;
          } else {
            const result = await applySubscription(r.row, d.payload, r.nowMs);
            if (result === "rejected") {
              bump(c, "purchase_rejected");
              c.failed++;
              await finish(r.row, "error", "purchase_rejected");
              abort = true;
            } else {
              if (result === "applied") {
                c.changed++;
                if (d.downgrade) c.downgrades++;
              }
              entitlementStored = true;
            }
          }
        }
        if (abort) continue;

        // 2. Acknowledgement: only for a stored, running entitlement; kept apart from the grant.
        if (entitlementStored && r.payload) {
          const action = ackAction(r.googleAck, r.payload.status, r.row.ack_first_seen_at, r.nowMs);
          if (action === "note_pending") {
            await noteAck(r.row, "pending");
          } else if (action === "note_acknowledged") {
            if (r.row.ack_state !== "acknowledged") await noteAck(r.row, "acknowledged");
          } else if (action === "acknowledge" && !dryRun) {
            try {
              await googleAcknowledgeSubscription(r.payload.provider_product_id.split(":")[0], r.row.provider_subscription_id);
              await noteAck(r.row, "acknowledged");
              c.acked++;
            } catch (e) {
              const code = toBillingError(e).code;
              bump(c, `ack_${code}`);
              await noteAck(r.row, "failed", code);
            }
          }
        }
        await finish(r.row, "ok");
      } catch (e) {
        // Database trouble: leave the lease to expire; the subscription is picked up again.
        bump(c, "apply_failed");
        c.failed++;
        console.error(JSON.stringify({ fn: "billing-reconcile", code: "apply_failed", kind: e instanceof Error ? e.message : "error" }));
      }
    }
  }

  // 3. Voided purchases (refunds, chargebacks, revocations), about hourly -----------------------------
  try {
    const nowMs = Date.now();
    const { data: lastRun } = await admin.rpc("billing_reconcile_cursor_get", { p_key: "voided_last_run" });
    const due = dryRun || lastRun == null || nowMs - Number(lastRun) >= VOIDED_EVERY_MS;
    if (due && temporaryErrors < MAX_TEMPORARY_ERRORS) {
      const { data: cursor } = await admin.rpc("billing_reconcile_cursor_get", { p_key: "voided" });
      const win = voidedWindow(cursor == null ? null : Number(cursor), nowMs);
      if (win.gap) {
        bump(c, "voided_gap");
        console.error(JSON.stringify({ fn: "billing-reconcile", code: "voided_gap" }));
      }
      const items = [];
      let token: string | undefined;
      let complete = false;
      for (let page = 0; page < VOIDED_MAX_PAGES; page++) {
        const res = await googleVoidedPurchases(win.startMs, win.endMs, token);
        items.push(...res.items);
        token = res.nextToken;
        if (!token) {
          complete = true;
          break;
        }
      }
      if (!complete) bump(c, "voided_truncated");
      c.voided_seen = items.length;

      const { data: known } = await admin.rpc("billing_voided_known", {
        p_tokens: items.map((i) => i.purchaseToken).filter((t): t is string => !!t),
        p_orders: items.map((i) => i.orderId).filter((t): t is string => !!t),
      });
      const plan = planVoided(items, { tokens: known?.tokens ?? [], orders: known?.orders ?? [] });
      if (plan.unknown > 0) bump(c, "voided_unknown");
      let voidedOk = true;

      for (const tokenValue of plan.tokens) {
        try {
          const { data: stored } = await admin.from("subscriptions")
            .select("id, provider_subscription_id, status, current_period_end, cancel_at_period_end")
            .eq("provider", "google_play").eq("provider_subscription_id", tokenValue).maybeSingle();
          if (!stored) continue;
          const row: Claimed = {
            subscription_id: stored.id,
            provider_subscription_id: stored.provider_subscription_id,
            status: stored.status,
            current_period_end: stored.current_period_end,
            cancel_at_period_end: stored.cancel_at_period_end,
            failure_count: 0,
            ack_state: "unknown",
            ack_first_seen_at: null,
          };
          const sub = await googleSubscription(tokenValue);
          const at = Date.now();
          const payload = googlePlayPayload(tokenValue, sub, at, new Date(at).toISOString());
          const d = decide(row, sub, payload, at);
          if (d.action === "replaced") {
            bump(c, "voided_replaced");
          } else if (d.action === "skip") {
            // Google still shows the subscription as it is stored: a voided renewal order is not a
            // revocation. Access is not touched until the subscription itself says so.
            bump(c, "voided_no_change");
          } else if (d.downgrade && (dryRun || !mayDowngrade(1, Math.max(c.checked, 1)))) {
            bump(c, dryRun ? "would_downgrade" : "downgrade_blocked");
            if (!dryRun) voidedOk = false; // looked at again next hour
          } else if (dryRun) {
            bump(c, "would_change");
          } else {
            const result = await applySubscription(row, d.payload, at, voidedEventId("sub", stored.id, d.payload));
            if (result === "applied") {
              c.voided_applied++;
              c.changed++;
              if (d.downgrade) c.downgrades++;
            } else if (result === "rejected") {
              bump(c, "purchase_rejected");
              voidedOk = false;
            }
          }
        } catch (e) {
          const code = toBillingError(e).code;
          bump(c, code);
          voidedOk = false; // the cursor must not move past an item that could not be checked
        }
      }

      for (const order of plan.orders) {
        if (dryRun) {
          bump(c, "would_refund");
          continue;
        }
        const { data, error } = await admin.rpc("premium_apply_event", {
          p_provider: "google_play",
          p_provider_event_id: voidedEventId("order", order, { status: "refunded" }),
          p_event_type: "voided",
          p_payload: googleVoidedPayload(order, new Date().toISOString()),
        });
        if (error || data === "rejected") {
          bump(c, "voided_order_failed");
          voidedOk = false;
        } else if (data === "applied") {
          c.voided_applied++;
        }
      }

      // The cursor moves only after every page was read and every known item was handled.
      if (!dryRun && complete && voidedOk) {
        await admin.rpc("billing_reconcile_cursor_set", { p_key: "voided", p_ms: win.endMs });
        await admin.rpc("billing_reconcile_cursor_set", { p_key: "voided_last_run", p_ms: nowMs });
      }
    }
  } catch (e) {
    const code = toBillingError(e).code;
    bump(c, `voided_${code}`);
    console.error(JSON.stringify({ fn: "billing-reconcile", code: `voided_${code}` }));
  }

  await admin.rpc("billing_reconcile_record_run", { p_run: { ...c, started_at: startedAt.toISOString(), dry_run: dryRun } });
  console.log(JSON.stringify({ fn: "billing-reconcile", dry_run: dryRun, ...c }));
  return json({ result: dryRun ? "dry_run" : "ok", ...c });
});
