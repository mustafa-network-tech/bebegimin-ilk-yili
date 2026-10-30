// Payment provider adapter contract. Each provider verifies the raw request
// (signature / receipt) server-side and normalises it. Subscription events go
// to public.billing_apply_event(), premium one-time purchases to
// public.premium_apply_event(); both are idempotent per provider event id.
// Clients never reach this path.
import { safeEqual } from "./cors.ts";
import { appStoreNotification } from "./app_store.ts";
import { googlePlayState, googlePremiumState } from "./google_play.ts";
import { googleVoidedPayload, type NormalizedPayload, type PremiumPayload } from "./store_status.ts";

export type NormalizedBillingEvent =
  | {
    kind: "subscription";
    provider: string;
    eventId: string;
    eventType: string;
    payload: NormalizedPayload & { family_account_id?: string; provider_customer_id?: string };
  }
  | { kind: "premium"; provider: string; eventId: string; eventType: string; payload: PremiumPayload };

export interface BillingProviderAdapter {
  readonly name: string;
  /** Throws when the request is not authentic; `null` = authentic but nothing to apply. */
  verify(rawBody: string, url: URL, headers: Headers): Promise<NormalizedBillingEvent | null>;
}

async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Development / staging provider. Body: { id, type, kind?, data: { ...payload } }
 * signed with `x-mock-signature: hex(HMAC-SHA256(BILLING_MOCK_SECRET, rawBody))`.
 */
export class MockBillingAdapter implements BillingProviderAdapter {
  readonly name = "mock";
  constructor(private readonly secret: string) {}

  async verify(rawBody: string, _url: URL, headers: Headers): Promise<NormalizedBillingEvent> {
    if (!this.secret) throw new Error("mock provider is not configured");
    const given = headers.get("x-mock-signature") ?? "";
    const expected = await hmacSha256Hex(this.secret, rawBody);
    if (!safeEqual(given, expected)) throw new Error("invalid signature");
    const body = JSON.parse(rawBody);
    if (typeof body?.id !== "string" || typeof body?.type !== "string" || typeof body?.data !== "object") {
      throw new Error("malformed event");
    }
    const kind = body.kind === "premium" ? "premium" : "subscription";
    return { kind, provider: this.name, eventId: body.id, eventType: body.type, payload: body.data };
  }
}

/** App Store Server Notifications V2: body { signedPayload } verified with the Apple roots. */
export class AppStoreAdapter implements BillingProviderAdapter {
  readonly name = "app_store";

  async verify(rawBody: string): Promise<NormalizedBillingEvent | null> {
    const body = JSON.parse(rawBody);
    if (typeof body?.signedPayload !== "string") throw new Error("malformed notification");
    const n = await appStoreNotification(body.signedPayload);
    if (!n) return null;
    return n.kind === "premium"
      ? { kind: "premium", provider: this.name, eventId: n.eventId, eventType: n.eventType, payload: n.payload }
      : { kind: "subscription", provider: this.name, eventId: n.eventId, eventType: n.eventType, payload: n.payload };
  }
}

/**
 * Google Play Real-time Developer Notifications through a Pub/Sub push
 * subscription whose endpoint URL carries `?provider=google_play&token=<GOOGLE_RTDN_TOKEN>`.
 * The message only says "something changed"; the state is re-read from the
 * Play Developer API.
 */
export class GooglePlayAdapter implements BillingProviderAdapter {
  readonly name = "google_play";
  constructor(private readonly token: string) {}

  async verify(rawBody: string, url: URL): Promise<NormalizedBillingEvent | null> {
    if (!this.token || !safeEqual(url.searchParams.get("token") ?? "", this.token)) {
      throw new Error("invalid push token");
    }
    const body = JSON.parse(rawBody);
    const messageId = body?.message?.messageId as string | undefined;
    const data = body?.message?.data ? JSON.parse(atob(body.message.data)) : null;
    if (!messageId || !data) throw new Error("malformed push message");
    if (data.packageName !== Deno.env.get("GOOGLE_PLAY_PACKAGE_NAME")) throw new Error("unexpected package");
    const eventTime = data.eventTimeMillis ? new Date(Number(data.eventTimeMillis)).toISOString() : undefined;

    const sn = data.subscriptionNotification;
    if (sn?.purchaseToken) {
      const payload = await googlePlayState(sn.purchaseToken, eventTime);
      if (!payload) return null; // pending purchase
      return { kind: "subscription", provider: this.name, eventId: messageId, eventType: `rtdn.${sn.notificationType}`, payload };
    }
    const otp = data.oneTimeProductNotification;
    if (otp?.purchaseToken && otp?.sku) {
      const payload = await googlePremiumState(otp.sku, otp.purchaseToken, eventTime);
      if (!payload) return null;
      return { kind: "premium", provider: this.name, eventId: messageId, eventType: `otp.${otp.notificationType}`, payload };
    }
    const voided = data.voidedPurchaseNotification;
    if (voided?.orderId && Number(voided.productType) === 2) {
      return {
        kind: "premium",
        provider: this.name,
        eventId: messageId,
        eventType: "voided",
        payload: googleVoidedPayload(voided.orderId, eventTime),
      };
    }
    if (voided?.purchaseToken && Number(voided.productType) === 1) {
      const payload = await googlePlayState(voided.purchaseToken, eventTime);
      if (!payload) return null;
      return { kind: "subscription", provider: this.name, eventId: messageId, eventType: "voided", payload };
    }
    return null; // test notifications
  }
}

export function adapterFor(provider: string): BillingProviderAdapter {
  switch (provider) {
    case "mock":
      return new MockBillingAdapter(Deno.env.get("BILLING_MOCK_SECRET") ?? "");
    case "app_store":
      return new AppStoreAdapter();
    case "google_play":
      return new GooglePlayAdapter(Deno.env.get("GOOGLE_RTDN_TOKEN") ?? "");
    default:
      throw new Error(`unsupported provider: ${provider}`);
  }
}
