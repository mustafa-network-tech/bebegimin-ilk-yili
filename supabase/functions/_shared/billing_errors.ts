// Safe error classification and outcome mapping for purchase verification.
// No I/O and no Deno APIs (unit-tested in ../tests/billing_errors.test.ts).
//
// The codes are the only error detail that ever leaves the server: never a
// token, key, service-account value or store response body.

export type BillingErrorCode =
  | "not_configured"
  | "google_401"
  | "google_403"
  | "google_404"
  | "product_not_found"
  | "base_plan_unavailable"
  | "verification_failed"
  | "purchase_rejected"
  | "temporary_error"
  | "purchase_not_yours";

export class BillingError extends Error {
  readonly code: BillingErrorCode;

  constructor(code: BillingErrorCode) {
    super(code);
    this.name = "BillingError";
    this.code = code;
  }
}

/** HTTP status the app receives for each code (the body carries `{ error: code }`). */
export const BILLING_HTTP_STATUS: Record<BillingErrorCode, number> = {
  not_configured: 503,
  google_401: 502,
  google_403: 502,
  google_404: 422,
  product_not_found: 400,
  base_plan_unavailable: 422,
  verification_failed: 422,
  purchase_rejected: 409,
  temporary_error: 503,
  purchase_not_yours: 403,
};

/** Maps a failed Google call to a code. `oauth` = the token endpoint, `api` = Android Publisher. */
export function codeForGoogleStatus(status: number, stage: "oauth" | "api"): BillingErrorCode {
  if (status === 401) return "google_401";
  if (status === 403) return "google_403";
  if (status === 404 || status === 410) return "google_404";
  if (status === 429 || status >= 500) return "temporary_error";
  // invalid_grant / invalid_client from the token endpoint: the key is unusable.
  if (stage === "oauth" && status === 400) return "google_401";
  return "verification_failed";
}

/** Any thrown value → a safe error. Unknown errors never expose their message. */
export function toBillingError(error: unknown): BillingError {
  if (error instanceof BillingError) return error;
  // googlePlayPayload() throws this when the line item names no base plan.
  if (error instanceof Error && error.message.startsWith("subscription has no line item")) {
    return new BillingError("base_plan_unavailable");
  }
  return new BillingError("verification_failed");
}

/** Why the database rejected an event (its stored `error` text) → code. */
export function rejectionCode(dbError: string | null | undefined): BillingErrorCode {
  if ((dbError ?? "").toLowerCase().includes("unknown provider product")) return "base_plan_unavailable";
  return "purchase_rejected";
}

export type VerifyOutcome = "granted" | "inactive" | "rejected";

/**
 * Result token of billing_apply_verified_purchase / premium_apply_verified_purchase.
 * The RPCs re-read the stored subscription / order, so `applied`, `duplicate`,
 * `stale` and `duplicate_payment` already mean access / the entitlement exists.
 * Anything unknown is treated as not granted.
 */
export function verifyOutcome(result: unknown): VerifyOutcome {
  switch (result) {
    case "applied":
    case "duplicate":
    case "stale":
    case "duplicate_payment":
      return "granted";
    case "inactive":
      return "inactive";
    default:
      return "rejected";
  }
}
