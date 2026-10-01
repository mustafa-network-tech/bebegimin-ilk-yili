// Runs with `deno test` or `node --experimental-strip-types --test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { refusal } from "../_shared/download.ts";

test("download refusals map to safe HTTP answers", () => {
  assert.equal(refusal("not_found").status, 404);
  assert.equal(refusal("permission_denied").status, 403);
  assert.equal(refusal("member_downloads_disabled").status, 403);
  assert.equal(refusal("rate_limited").status, 429);
  for (
    const r of [
      "subscription_required",
      "capacity_exceeded",
      "entitlement_required",
      "artifact_not_ready",
    ]
  ) {
    assert.equal(refusal(r).status, 409, r);
  }
  assert.deepEqual(refusal("something_new"), {
    status: 409,
    error: "Dosya indirilemiyor.",
    reason: "something_new",
  });
  assert.equal(refusal(null).reason, "unknown");
});
