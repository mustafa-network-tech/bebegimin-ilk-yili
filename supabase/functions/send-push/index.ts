// Delivers a row of public.notifications as a push notification through
// Firebase Cloud Messaging (HTTP v1).
//
// Trigger: Database Webhook on INSERT into public.notifications, with the
// HTTP header `x-webhook-secret: <PUSH_WEBHOOK_SECRET>`.
// Secrets: FCM_SERVICE_ACCOUNT (JSON of a Firebase service account),
//          PUSH_WEBHOOK_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2";
import { json, safeEqual } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET") ?? "";
const SERVICE_ACCOUNT = Deno.env.get("FCM_SERVICE_ACCOUNT");

type ServiceAccount = { client_email: string; private_key: string; project_id: string };

let cachedToken: { token: string; expires: number } | null = null;

function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function accessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expires > now + 60) return cachedToken.token;
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${base64url(signature)}`,
    }),
  });
  if (!res.ok) throw new Error(`oauth failed: ${res.status} ${await res.text()}`);
  const body = await res.json();
  cachedToken = { token: body.access_token, expires: now + (body.expires_in ?? 3600) };
  return cachedToken.token;
}

function routeFor(record: Record<string, any>): string | null {
  const data = record.data ?? {};
  switch (record.type) {
    case "book_ready":
    case "book_generated": return "/book";
    case "time_capsule_opened": return "/capsules";
    case "member_joined": return "/family";
    case "memories_of_the_day": return data.date ? `/calendar?date=${data.date}` : "/timeline";
  }
  const id = data.target_id;
  const babyId = record.baby_id;
  if (!id || !babyId) return null;
  return ({
    memories: `/babies/${babyId}/memories/${id}`,
    milestones: `/babies/${babyId}/milestones/${id}`,
    letters: `/babies/${babyId}/letters/${id}`,
  } as Record<string, string>)[data.target_type] ?? null;
}

Deno.serve(async (req) => {
  const given = req.headers.get("x-webhook-secret") ?? "";
  if (!WEBHOOK_SECRET || !safeEqual(given, WEBHOOK_SECRET)) return json({ error: "unauthorized" }, 401);
  if (!SERVICE_ACCOUNT) return json({ ok: true, skipped: "FCM_SERVICE_ACCOUNT not configured" });

  const payload = await req.json().catch(() => null);
  const record = payload?.record;
  if (payload?.type !== "INSERT" || payload?.table !== "notifications" || !record?.user_id) {
    return json({ ok: true, skipped: "not a notification insert" });
  }

  const sa = JSON.parse(SERVICE_ACCOUNT) as ServiceAccount;
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: tokens, error } = await admin.from("device_tokens").select("id, token").eq("user_id", record.user_id);
  if (error) return json({ error: error.message }, 500);
  if (!tokens?.length) return json({ ok: true, sent: 0 });

  const token = await accessToken(sa);
  const route = routeFor(record);
  let sent = 0;
  for (const t of tokens) {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token: t.token,
          notification: { title: record.title, body: record.body ?? undefined },
          // Only ids / routes travel through Google – never photos or texts beyond the title.
          data: { notification_id: record.id, ...(route ? { route } : {}), ...(record.baby_id ? { baby_id: record.baby_id } : {}) },
          android: { priority: "high", notification: { channel_id: "family" } },
          apns: { payload: { aps: { sound: "default" } } },
        },
      }),
    });
    if (res.ok) {
      sent++;
    } else if (res.status === 404 || res.status === 400) {
      const body = await res.text();
      if (body.includes("UNREGISTERED") || body.includes("INVALID_ARGUMENT")) {
        await admin.from("device_tokens").delete().eq("id", t.id);
      }
    }
  }
  return json({ ok: true, sent });
});
