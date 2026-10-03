// App Store verification: every JWS (notification, transaction, renewal info)
// is verified against the Apple root certificates before it is trusted.
//
// Secrets:
//   APPLE_BUNDLE_ID, APPLE_APP_APPLE_ID (numeric, required in Production),
//   APPLE_ENVIRONMENT = Production | Sandbox,
//   APPLE_ROOT_CERTS_B64 = comma separated base64 DER of Apple Root CA G3 (+ others),
//   optional App Store Server API key for authoritative status lookups:
//   APPLE_ISSUER_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY (PKCS#8 .p8 contents).
import { Buffer } from "node:buffer";
import {
  AppStoreServerAPIClient,
  Environment,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";
import {
  type AppleOneTimeTransaction,
  type AppleRenewalInfo,
  type AppleTransaction,
  appStoreOneTimePayload,
  appStorePayload,
  isAppleSubscription,
  type NormalizedPayload,
  type PremiumPayload,
} from "./store_status.ts";

function env(name: string): string {
  return Deno.env.get(name) ?? "";
}

function environment(): Environment {
  return env("APPLE_ENVIRONMENT") === "Sandbox" ? Environment.SANDBOX : Environment.PRODUCTION;
}

let verifier: SignedDataVerifier | null = null;

export function appleVerifier(): SignedDataVerifier {
  if (verifier) return verifier;
  const roots = env("APPLE_ROOT_CERTS_B64").split(",").filter(Boolean).map((b) => Buffer.from(b.trim(), "base64"));
  const bundleId = env("APPLE_BUNDLE_ID");
  if (!roots.length || !bundleId) throw new Error("App Store verification is not configured");
  const appAppleId = env("APPLE_APP_APPLE_ID") ? Number(env("APPLE_APP_APPLE_ID")) : undefined;
  verifier = new SignedDataVerifier(roots, true, environment(), bundleId, appAppleId);
  return verifier;
}

function apiClient(): AppStoreServerAPIClient | null {
  const key = env("APPLE_PRIVATE_KEY");
  if (!key || !env("APPLE_KEY_ID") || !env("APPLE_ISSUER_ID")) return null;
  return new AppStoreServerAPIClient(key, env("APPLE_KEY_ID"), env("APPLE_ISSUER_ID"), env("APPLE_BUNDLE_ID"), environment());
}

/** Verifies a StoreKit 2 signed transaction and decodes it. */
export async function verifyAppleTransaction(signedTransaction: string): Promise<AppleOneTimeTransaction> {
  return (await appleVerifier().verifyAndDecodeTransaction(signedTransaction)) as AppleOneTimeTransaction;
}

export { isAppleSubscription };

/** Premium (consumable) purchase from a verified transaction. */
export function appStorePremiumFromTransaction(tx: AppleOneTimeTransaction): PremiumPayload {
  return appStoreOneTimePayload(tx);
}

/**
 * Current state of the subscription a (verified) transaction belongs to.
 * Uses the App Store Server API when configured (latest renewal state),
 * otherwise the verified transaction alone.
 */
export async function appStoreStateForTransaction(
  signedTransaction: string,
  nowMs = Date.now(),
): Promise<{ transactionId: string; payload: NormalizedPayload }> {
  const v = appleVerifier();
  const tx = (await v.verifyAndDecodeTransaction(signedTransaction)) as AppleTransaction;
  let latest = tx;
  let renewal: AppleRenewalInfo | undefined;
  const client = apiClient();
  if (client) {
    const statuses = await client.getAllSubscriptionStatuses(tx.originalTransactionId);
    for (const group of statuses.data ?? []) {
      for (const item of group.lastTransactions ?? []) {
        if (item.originalTransactionId !== tx.originalTransactionId) continue;
        if (item.signedTransactionInfo) {
          latest = (await v.verifyAndDecodeTransaction(item.signedTransactionInfo)) as AppleTransaction;
        }
        if (item.signedRenewalInfo) {
          renewal = (await v.verifyAndDecodeRenewalInfo(item.signedRenewalInfo)) as AppleRenewalInfo;
        }
      }
    }
  }
  return {
    transactionId: latest.transactionId ?? latest.originalTransactionId,
    payload: appStorePayload(latest, renewal, nowMs),
  };
}

/** App Store Server Notification V2 → normalised event (null = nothing to apply). */
export async function appStoreNotification(signedPayload: string, nowMs = Date.now()) {
  const v = appleVerifier();
  const n = await v.verifyAndDecodeNotification(signedPayload);
  const signedTx = n.data?.signedTransactionInfo;
  if (!signedTx || !n.notificationUUID) return null; // e.g. TEST notifications
  const tx = (await v.verifyAndDecodeTransaction(signedTx)) as AppleOneTimeTransaction;
  const eventType = [n.notificationType, n.subtype].filter(Boolean).join(".");
  if (!isAppleSubscription(tx)) {
    // Consumable premium product (purchase, REFUND, REVOKE).
    return {
      kind: "premium" as const,
      eventId: n.notificationUUID,
      eventType,
      payload: appStoreOneTimePayload(tx, n.signedDate),
    };
  }
  const renewal = n.data?.signedRenewalInfo
    ? ((await v.verifyAndDecodeRenewalInfo(n.data.signedRenewalInfo)) as AppleRenewalInfo)
    : undefined;
  return {
    kind: "subscription" as const,
    eventId: n.notificationUUID,
    eventType,
    payload: appStorePayload(tx, renewal, nowMs, n.signedDate),
  };
}
