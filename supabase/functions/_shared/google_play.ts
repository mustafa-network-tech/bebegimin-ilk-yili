// Google Play Developer API: the only trusted source of a subscription's
// state. Purchase tokens from the app or from RTDN messages are always
// re-read from Google before anything is applied.
//
// Secrets: GOOGLE_PLAY_PACKAGE_NAME,
//          GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (JSON key with the "View financial data" /
//          "Manage orders and subscriptions" permission in Play Console).
import { BillingError, codeForGoogleStatus } from "./billing_errors.ts";
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
  // The old name remains a temporary compatibility fallback for environments
  // that have not rotated to the explicit server-only JSON variable yet.
  const raw = Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON") ?? Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT");
  if (!raw) throw new BillingError("not_configured");
  let sa: ServiceAccount;
  let key: CryptoKey;
  try {
    sa = JSON.parse(raw) as ServiceAccount;
    if (!sa.client_email || !sa.private_key) throw new Error("incomplete");
    const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
    const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
    key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  } catch (_) {
    // Malformed JSON or key: a configuration problem, never logged verbatim.
    throw new BillingError("not_configured");
  }
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  let res: Response;
  try {
    res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: `${header}.${claims}.${base64url(signature)}`,
      }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (_) {
    throw new BillingError("temporary_error");
  }
  if (!res.ok) throw new BillingError(codeForGoogleStatus(res.status, "oauth"));
  const body = await res.json();
  cachedToken = { token: body.access_token, expires: now + (body.expires_in ?? 3600) };
  return cachedToken.token;
}

async function androidPublisher<T>(path: string, init?: { method?: "POST"; body?: string }): Promise<T> {
  const pkg = Deno.env.get("GOOGLE_PLAY_PACKAGE_NAME");
  if (!pkg) throw new BillingError("not_configured");
  const url = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(pkg)}${path}`;
  const token = await accessToken();
  let res: Response;
  try {
    res = await fetch(url, {
      method: init?.method ?? "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        ...(init?.body !== undefined ? { "Content-Type": "application/json" } : {}),
      },
      body: init?.body,
      signal: AbortSignal.timeout(15_000),
    });
  } catch (_) {
    throw new BillingError("temporary_error");
  }
  if (!res.ok) {
    if (res.status === 401) cachedToken = null; // revoked / expired early: sign in again next time
    throw new BillingError(codeForGoogleStatus(res.status, "api"));
  }
  // acknowledge answers 204 with an empty body.
  const text = await res.text();
  return (text ? JSON.parse(text) : {}) as T;
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

export type GoogleVoidedPurchase = {
  purchaseToken?: string;
  orderId?: string;
  voidedTimeMillis?: string;
  voidedSource?: number;
  voidedReason?: number;
};

export type VoidedPage = { items: GoogleVoidedPurchase[]; nextToken?: string };

/**
 * purchases.voidedpurchases.list: refunds, chargebacks and revocations of subscriptions and
 * one-time products (type=1). Google keeps about 30 days; the quota is much tighter than
 * for the other calls, so the caller pages gently.
 */
export async function googleVoidedPurchases(
  startMs: number,
  endMs: number,
  pageToken?: string,
  maxResults = 100,
): Promise<VoidedPage> {
  const q = new URLSearchParams({
    startTime: String(startMs),
    endTime: String(endMs),
    type: "1",
    maxResults: String(maxResults),
  });
  if (pageToken) q.set("token", pageToken);
  const body = await androidPublisher<{
    voidedPurchases?: GoogleVoidedPurchase[];
    tokenPagination?: { nextPageToken?: string };
  }>(`/purchases/voidedpurchases?${q}`);
  return { items: body.voidedPurchases ?? [], nextToken: body.tokenPagination?.nextPageToken };
}

/**
 * Server-side acknowledgement of a subscription purchase (purchases.subscriptions.acknowledge).
 * Safe to race with the app: if Google rejects the call, the state is read again and an already
 * acknowledged purchase counts as success. Call only after the entitlement exists.
 */
export async function googleAcknowledgeSubscription(
  productId: string,
  purchaseToken: string,
): Promise<"acknowledged" | "already"> {
  try {
    await androidPublisher(
      `/purchases/subscriptions/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}:acknowledge`,
      { method: "POST", body: "{}" },
    );
    return "acknowledged";
  } catch (e) {
    const code = e instanceof BillingError ? e.code : "verification_failed";
    // 400 (already acknowledged / app was faster) and transient errors: look at the real state.
    if (code === "verification_failed" || code === "temporary_error") {
      const sub = await googleSubscription(purchaseToken);
      if (sub.acknowledgementState === "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED") return "already";
    }
    throw e;
  }
}
