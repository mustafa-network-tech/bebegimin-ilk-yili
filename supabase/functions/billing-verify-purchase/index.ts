// Called by the app after a purchase or restore. The receipt is verified
// with the store (never trusted as sent), routed by product kind and bound
// to the caller's family account only if the caller is a parent there.
//
// Response: { kind, result, status, granted } on success. `granted` is true only
// when the family really has access / the baby really owns the product (the RPC
// re-reads the stored state). Failures are `{ error: <code> }` with a safe code
// (see _shared/billing_errors.ts); nothing from the store or the receipt is echoed.
//
// POST {
//   provider: "app_store" | "google_play",
//   verification_data,   // app_store: StoreKit 2 signed transaction (JWS); google_play: purchase token
//   product_id?,         // store product id (required for google_play)
//   checkout_intent_id?, // subscription purchase intent
//   order_id?            // premium order
// }
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  appStorePremiumFromTransaction,
  appStoreStateForTransaction,
  isAppleSubscription,
  verifyAppleTransaction,
} from "../_shared/app_store.ts";
import { googlePlayState, googlePremiumState } from "../_shared/google_play.ts";
import {
  BILLING_HTTP_STATUS,
  BillingError,
  type BillingErrorCode,
  rejectionCode,
  toBillingError,
  verifyOutcome,
} from "../_shared/billing_errors.ts";
import {
  platformFor,
  type ProductKind,
  recordUserEvent,
  type ServerEventType,
  storeConfirmsPayment,
} from "../_shared/user_events.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

type Body = {
  provider?: string;
  verification_data?: string;
  product_id?: string;
  checkout_intent_id?: string;
  order_id?: string;
};

function fail(provider: string | undefined, code: BillingErrorCode): Response {
  // Only the safe code is logged: no tokens, keys, receipts or user data.
  console.error(JSON.stringify({ fn: "billing-verify-purchase", provider: provider ?? null, code }));
  return json({ error: code }, BILLING_HTTP_STATUS[code]);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: auth } = await userClient.auth.getUser();
  if (!auth?.user) return json({ error: "unauthorized" }, 401);
  const userId = auth.user.id;

  let body: Body;
  try {
    body = await req.json();
  } catch (_) {
    return json({ error: "malformed request" }, 400);
  }
  if (!body.verification_data || typeof body.verification_data !== "string" || body.verification_data.length > 20000) {
    return json({ error: "malformed request" }, 400);
  }
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  // Journey / payment-stage record (see _shared/user_events.ts): awaited before every
  // response, never throws, bounded by a timeout, and never changes the decision below.
  const platform = platformFor(body.provider);
  let knownKind: ProductKind | null = null;
  const track = (type: ServerEventType, status: "ok" | "failed" | "pending", errorCode?: string) =>
    recordUserEvent(admin, { userId, type, platform, planCode: body.product_id, kind: knownKind, status, errorCode });

  let kind: "subscription" | "premium";
  let eventId: string;
  let payload: Record<string, unknown> | null;
  try {
    if (body.provider === "app_store") {
      const tx = await verifyAppleTransaction(body.verification_data);
      if (isAppleSubscription(tx)) {
        kind = "subscription";
        const state = await appStoreStateForTransaction(body.verification_data);
        eventId = `verify:${state.transactionId}:${state.payload.status}`;
        payload = state.payload;
      } else {
        kind = "premium";
        payload = appStorePremiumFromTransaction(tx);
        eventId = `verify:${payload.provider_order_ref}:${payload.status}`;
      }
    } else if (body.provider === "google_play") {
      if (!body.product_id) return json({ error: "malformed request" }, 400);
      const { data: productKind, error: kindError } = await admin.rpc("store_product_kind", {
        p_provider: "google_play",
        p_provider_product_id: body.product_id,
      });
      if (kindError) throw new BillingError("temporary_error");
      if (productKind === "premium" || productKind === "subscription") knownKind = productKind;
      if (productKind === "premium") {
        kind = "premium";
        payload = await googlePremiumState(body.product_id, body.verification_data);
        eventId = `verify:${payload?.provider_order_ref}:${payload?.status}`;
      } else if (productKind === "subscription") {
        kind = "subscription";
        payload = await googlePlayState(body.verification_data);
        eventId = `verify:${body.verification_data}:${payload?.status}:${payload?.current_period_end}`;
      } else {
        throw new BillingError("product_not_found");
      }
    } else {
      return json({ error: "unsupported provider" }, 400);
    }
  } catch (e) {
    const code = toBillingError(e).code;
    // The store could not be checked: whether any money moved is unknown.
    await track("store_verification_failed", "failed", code);
    return fail(body.provider, code);
  }
  knownKind = kind;
  if (!payload) {
    await track("payment_pending", "pending");
    return json({ result: "pending", granted: false });
  }
  // The store itself reports the purchase as paid (distinct from a failed check).
  const paymentConfirmed = storeConfirmsPayment(kind, String(payload.status));
  if (paymentConfirmed) await track("payment_verified", "ok");

  if (kind === "subscription" && body.checkout_intent_id) payload.checkout_intent_id = body.checkout_intent_id;
  if (kind === "premium" && body.order_id) payload.order_id = body.order_id;

  const { data, error } = await admin.rpc(
    kind === "premium" ? "premium_apply_verified_purchase" : "billing_apply_verified_purchase",
    { p_user: auth.user.id, p_provider: body.provider, p_provider_event_id: eventId, p_payload: payload },
  );
  if (error) {
    const code = error.hint === "purchase_not_yours" ? "purchase_not_yours" : "temporary_error";
    await track("activation_failed", "failed", code);
    return fail(body.provider, code);
  }
  const outcome = verifyOutcome(data);
  if (outcome === "rejected") {
    // Why it was rejected is stored with the (append-only) event; only a code is returned.
    const { data: rows } = await admin
      .from(kind === "premium" ? "premium_order_events" : "billing_events")
      .select("error")
      .eq("provider", body.provider!)
      .like("provider_event_id", `${eventId}*`)
      .order("id", { ascending: false })
      .limit(1);
    const code = rejectionCode(rows?.[0]?.error as string | undefined);
    await track("activation_failed", "failed", code);
    return fail(body.provider, code);
  }
  if (outcome === "granted") {
    await track("activation_granted", "ok");
  } else if (paymentConfirmed) {
    // Paid according to the store, but no access to open (expired / refunded afterwards).
    await track("activation_failed", "failed", "purchase_inactive");
  }
  return json({ kind, result: data, status: payload.status, granted: outcome === "granted" });
});
