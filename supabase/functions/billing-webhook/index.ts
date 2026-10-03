// Store server notifications:
//   App Store Server Notifications V2 → POST /billing-webhook?provider=app_store
//   Google Play RTDN (Pub/Sub push)   → POST /billing-webhook?provider=google_play&token=<GOOGLE_RTDN_TOKEN>
//   Mock (development)                → POST /billing-webhook?provider=mock (x-mock-signature)
// The adapter verifies the request; only then is the normalised event handed
// to public.billing_apply_event() (subscriptions) or public.premium_apply_event()
// (premium one-time products), both idempotent per provider event id.
import { createClient } from "npm:@supabase/supabase-js@2";
import { json } from "../_shared/cors.ts";
import { adapterFor } from "../_shared/billing.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const url = new URL(req.url);
  const raw = await req.text();

  let event;
  try {
    event = await adapterFor(url.searchParams.get("provider") ?? "").verify(raw, url, req.headers);
  } catch (_) {
    // Do not reveal why verification failed.
    return json({ error: "unauthorized" }, 401);
  }
  if (!event) return json({ result: "ignored" });

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data, error } = await admin.rpc(event.kind === "premium" ? "premium_apply_event" : "billing_apply_event", {
    p_provider: event.provider,
    p_provider_event_id: event.eventId,
    p_event_type: event.eventType,
    p_payload: event.payload,
  });
  // 5xx makes the store retry; applied / duplicate / stale / rejected are final.
  if (error) return json({ error: "processing failed" }, 500);
  return json({ result: data });
});
