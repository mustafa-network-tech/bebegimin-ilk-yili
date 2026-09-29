// Called by the app after a purchase or restore. The receipt is verified
// with the store (never trusted as sent), routed by product kind and bound
// to the caller's family account only if the caller is a parent there.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
  const { data: auth } = await userClient.auth.getUser();
  if (!auth?.user) return json({ error: "unauthorized" }, 401);

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
      const { data: productKind } = await admin.rpc("store_product_kind", {
        p_provider: "google_play",
        p_provider_product_id: body.product_id,
      });
      if (productKind === "premium") {
        kind = "premium";
        payload = await googlePremiumState(body.product_id, body.verification_data);
        eventId = `verify:${payload?.provider_order_ref}:${payload?.status}`;
      } else if (productKind === "subscription") {
        kind = "subscription";
        payload = await googlePlayState(body.verification_data);
        eventId = `verify:${body.verification_data}:${payload?.status}:${payload?.current_period_end}`;
      } else {
        return json({ error: "unknown product" }, 400);
      }
    } else {
      return json({ error: "unsupported provider" }, 400);
    }
  } catch (_) {
    return json({ error: "verification failed" }, 422);
  }
  if (!payload) return json({ result: "pending" });

  if (kind === "subscription" && body.checkout_intent_id) payload.checkout_intent_id = body.checkout_intent_id;
  if (kind === "premium" && body.order_id) payload.order_id = body.order_id;

  const { data, error } = await admin.rpc(
    kind === "premium" ? "premium_apply_verified_purchase" : "billing_apply_verified_purchase",
    { p_user: auth.user.id, p_provider: body.provider, p_provider_event_id: eventId, p_payload: payload },
  );
  if (error) {
    if (error.hint === "purchase_not_yours") return json({ error: "purchase_not_yours" }, 403);
    return json({ error: "processing failed" }, 500);
  }
  return json({ kind, result: data, status: payload.status });
});
