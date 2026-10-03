// Google Play Developer API: the only trusted source of a subscription's
// state. Purchase tokens from the app or from RTDN messages are always
// re-read from Google before anything is applied.
//
// Secrets: GOOGLE_PLAY_PACKAGE_NAME,
//          GOOGLE_PLAY_SERVICE_ACCOUNT (JSON key with the "View financial data" /
//          "Manage orders and subscriptions" permission in Play Console).
import {
  type GoogleProductPurchase,
  googlePlayPayload,
  googlePlayProductPayload,
  type GoogleSubscriptionV2,
  type NormalizedPayload,
  type PremiumPayload,
} from "./store_status.ts";

type ServiceAccount = { client_email: string; private_key: string };

let cachedToken: { token: string; expires: number } | null = null;

function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function accessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expires > now + 60) return cachedToken.token;
  const raw = Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT");
  if (!raw) throw new Error("Google Play verification is not configured");
  const sa = JSON.parse(raw) as ServiceAccount;
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${base64url(signature)}`,
    }),
  });
  if (!res.ok) throw new Error(`google oauth failed: ${res.status}`);
  const body = await res.json();
  cachedToken = { token: body.access_token, expires: now + (body.expires_in ?? 3600) };
  return cachedToken.token;
}

async function androidPublisher<T>(path: string): Promise<T> {
  const pkg = Deno.env.get("GOOGLE_PLAY_PACKAGE_NAME");
  if (!pkg) throw new Error("Google Play verification is not configured");
  const url = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(pkg)}${path}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${await accessToken()}` } });
  if (!res.ok) throw new Error(`google play lookup failed: ${res.status}`);
  return await res.json();
}

export function googleSubscription(purchaseToken: string): Promise<GoogleSubscriptionV2> {
  return androidPublisher(`/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`);
}

export function googleProductPurchase(productId: string, purchaseToken: string): Promise<GoogleProductPurchase> {
  return androidPublisher(
    `/purchases/products/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`,
  );
}

/** Premium one-time purchase state (`null` while pending). */
export async function googlePremiumState(
  productId: string,
  purchaseToken: string,
  eventTimeIso?: string,
): Promise<PremiumPayload | null> {
  return googlePlayProductPayload(productId, purchaseToken, await googleProductPurchase(productId, purchaseToken), eventTimeIso);
}

export async function googlePlayState(
  purchaseToken: string,
  eventTimeIso?: string,
  nowMs = Date.now(),
): Promise<NormalizedPayload | null> {
  return googlePlayPayload(purchaseToken, await googleSubscription(purchaseToken), nowMs, eventTimeIso);
}
