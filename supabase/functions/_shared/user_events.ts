// Server-side journey / payment-stage recording for the Edge Functions.
// No Deno APIs and no I/O of its own (unit-tested in ../tests/user_events.test.ts).
//
// Contract:
//   * `recordUserEvent` is AWAITED by the caller before the response is returned, so the
//     runtime can never cut the write short.
//   * It NEVER throws and never changes the purchase decision: every error (RPC error,
//     rejection, timeout) is swallowed and logged as a safe code only.
//   * It is bounded by a timeout, so a slow database cannot hold the purchase response.
//   * Only fixed vocabularies leave this module: no token, receipt, key, e-mail or
//     store response body is ever passed on (the database CHECK lists enforce the same).

export type ServerEventType =
  | "payment_verified" // the store itself reports the purchase as paid
  | "payment_pending" // the store reports the purchase as not settled yet
  | "store_verification_failed" // the store could not be checked: payment state UNKNOWN
  | "activation_granted" // the server confirmed access / the entitlement exists
  | "activation_failed"; // the store check passed but access was not opened

export type EventPlatform = "android" | "ios" | "unknown";
export type EventStatus = "ok" | "failed" | "pending";
export type ProductKind = "subscription" | "premium";

/** Must match the error_code CHECK list of public.user_events. */
const SAFE_ERROR_CODES = new Set([
  "not_configured",
  "google_401",
  "google_403",
  "google_404",
  "product_not_found",
  "base_plan_unavailable",
  "verification_failed",
  "purchase_rejected",
  "temporary_error",
  "purchase_not_yours",
  "purchase_inactive",
]);

export function safeErrorCode(code: string | null | undefined): string | null {
  return code && SAFE_ERROR_CODES.has(code) ? code : null;
}

/** Store product ids that look like our plan / product codes only; anything else is dropped. */
export function safePlanCode(productId: string | null | undefined): string | null {
  return productId && /^[a-z][a-z0-9_]{0,39}$/.test(productId) ? productId : null;
}

export function platformFor(provider: string | null | undefined): EventPlatform {
  if (provider === "google_play") return "android";
  if (provider === "app_store") return "ios";
  return "unknown";
}

/** Does the store's own state mean "money was paid / the entitlement is paid"? */
export function storeConfirmsPayment(kind: ProductKind, status: string | undefined): boolean {
  return kind === "premium"
    ? status === "paid"
    : status === "active" || status === "trialing" || status === "grace";
}

export type ServerEvent = {
  userId: string;
  type: ServerEventType;
  platform: EventPlatform;
  planCode?: string | null;
  kind?: ProductKind | null;
  status?: EventStatus;
  errorCode?: string | null;
};

/** The one method of the service-role Supabase client this module needs. */
export type EventRpcClient = {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
};

export const EVENT_TIMEOUT_MS = 2000;

export async function recordUserEvent(
  client: EventRpcClient,
  event: ServerEvent,
  timeoutMs = EVENT_TIMEOUT_MS,
): Promise<boolean> {
  let timer: number | undefined;
  try {
    const write = client.rpc("record_server_user_event", {
      p_user: event.userId,
      p_event_type: event.type,
      p_platform: event.platform,
      p_plan_code: safePlanCode(event.planCode),
      p_product_kind: event.kind ?? null,
      p_status: event.status ?? "ok",
      p_error_code: safeErrorCode(event.errorCode),
    });
    const timeout = new Promise<"timeout">((resolve) => {
      timer = setTimeout(() => resolve("timeout"), timeoutMs) as unknown as number;
    });
    const result = await Promise.race([Promise.resolve(write), timeout]);
    if (result === "timeout") {
      console.error(JSON.stringify({ fn: "user-events", event: event.type, code: "timeout" }));
      return false;
    }
    if (result.error) {
      console.error(JSON.stringify({ fn: "user-events", event: event.type, code: "rpc_error" }));
      return false;
    }
    return result.data === true;
  } catch (_) {
    // Never log the error object: it could carry request details.
    console.error(JSON.stringify({ fn: "user-events", event: event.type, code: "exception" }));
    return false;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
