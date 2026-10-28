// Runs with `deno test` or `node --experimental-strip-types --test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BILLING_HTTP_STATUS,
  BillingError,
  codeForGoogleStatus,
  rejectionCode,
  toBillingError,
  verifyOutcome,
} from "../_shared/billing_errors.ts";
import { googlePlayPayload } from "../_shared/store_status.ts";

test("Google API statuses map to safe codes", () => {
  assert.equal(codeForGoogleStatus(401, "api"), "google_401");
  assert.equal(codeForGoogleStatus(403, "api"), "google_403");
  assert.equal(codeForGoogleStatus(404, "api"), "google_404");
  assert.equal(codeForGoogleStatus(410, "api"), "google_404");
  assert.equal(codeForGoogleStatus(429, "api"), "temporary_error");
  assert.equal(codeForGoogleStatus(503, "api"), "temporary_error");
  assert.equal(codeForGoogleStatus(400, "api"), "verification_failed");
});

test("a rejected service-account grant is a credential problem, not a bad purchase", () => {
  assert.equal(codeForGoogleStatus(400, "oauth"), "google_401");
  assert.equal(codeForGoogleStatus(500, "oauth"), "temporary_error");
});

test("unknown errors never leak their message", () => {
  const e = toBillingError(new Error("private_key = -----BEGIN PRIVATE KEY----- secret token abc"));
  assert.equal(e.code, "verification_failed");
  assert.equal(e.message, "verification_failed");
  assert.equal(toBillingError("boom").code, "verification_failed");
  assert.equal(toBillingError(new BillingError("not_configured")).code, "not_configured");
});

test("a Play subscription without a base plan is base_plan_unavailable", () => {
  let thrown: unknown;
  try {
    googlePlayPayload("tok", { subscriptionState: "SUBSCRIPTION_STATE_ACTIVE", lineItems: [] }, Date.now());
  } catch (e) {
    thrown = e;
  }
  assert.equal(toBillingError(thrown).code, "base_plan_unavailable");
});

test("every code has an HTTP status; only purchase_not_yours is a 403", () => {
  for (const code of Object.keys(BILLING_HTTP_STATUS)) {
    const status = BILLING_HTTP_STATUS[code as keyof typeof BILLING_HTTP_STATUS];
    assert.ok(status >= 400 && status < 600, code);
  }
  assert.equal(BILLING_HTTP_STATUS.purchase_not_yours, 403);
  assert.equal(BILLING_HTTP_STATUS.temporary_error, 503);
  assert.equal(BILLING_HTTP_STATUS.not_configured, 503);
});

test("database rejections are classified without exposing the database text", () => {
  assert.equal(rejectionCode("unknown provider product"), "base_plan_unavailable");
  assert.equal(rejectionCode("checkout intent is not open"), "purchase_rejected");
  assert.equal(rejectionCode("a checkout intent is required for a new subscription"), "purchase_rejected");
  assert.equal(rejectionCode(undefined), "purchase_rejected");
  assert.equal(rejectionCode(null), "purchase_rejected");
});

test("only a verified state counts as granted: rejected / unknown never do", () => {
  for (const r of ["applied", "duplicate", "stale", "duplicate_payment"]) assert.equal(verifyOutcome(r), "granted", r);
  assert.equal(verifyOutcome("inactive"), "inactive");
  assert.equal(verifyOutcome("rejected"), "rejected");
  assert.equal(verifyOutcome("pending"), "rejected");
  assert.equal(verifyOutcome(null), "rejected");
  assert.equal(verifyOutcome(undefined), "rejected");
  assert.equal(verifyOutcome("something-new"), "rejected");
});
