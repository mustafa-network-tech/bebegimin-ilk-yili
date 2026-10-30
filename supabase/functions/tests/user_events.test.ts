// Runs with `deno test` or `node --experimental-strip-types --test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  type EventRpcClient,
  platformFor,
  recordUserEvent,
  safeErrorCode,
  safePlanCode,
  storeConfirmsPayment,
} from "../_shared/user_events.ts";

const USER = "00000000-0000-4000-8000-000000000001";

function client(handler: (args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const c: EventRpcClient = {
    rpc(name, args) {
      calls.push({ name, args });
      return handler(args);
    },
  };
  return { c, calls };
}

test("a successful write is awaited and reported", async () => {
  const { c, calls } = client(() => Promise.resolve({ data: true, error: null }));
  const ok = await recordUserEvent(c, { userId: USER, type: "payment_verified", platform: "android", planCode: "small_family", kind: "subscription" });
  assert.equal(ok, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "record_server_user_event");
  assert.equal(calls[0].args.p_user, USER);
  assert.equal(calls[0].args.p_plan_code, "small_family");
  assert.equal(calls[0].args.p_product_kind, "subscription");
});

test("an RPC error never throws and never changes the caller's flow", async () => {
  const { c } = client(() => Promise.resolve({ data: null, error: { message: "permission denied for table x" } }));
  assert.equal(await recordUserEvent(c, { userId: USER, type: "activation_failed", platform: "android" }), false);
});

test("a thrown client error is swallowed", async () => {
  const { c } = client(() => Promise.reject(new Error("network down")));
  assert.equal(await recordUserEvent(c, { userId: USER, type: "activation_failed", platform: "android" }), false);
});

test("a synchronously throwing client is swallowed", async () => {
  const c: EventRpcClient = {
    rpc() {
      throw new Error("boom");
    },
  };
  assert.equal(await recordUserEvent(c, { userId: USER, type: "activation_failed", platform: "android" }), false);
});

test("a slow database cannot hold the purchase response", async () => {
  const { c } = client(() => new Promise(() => {})); // never settles
  const started = Date.now();
  const ok = await recordUserEvent(c, { userId: USER, type: "payment_verified", platform: "android" }, 30);
  assert.equal(ok, false);
  assert.ok(Date.now() - started < 1000);
});

test("error text of a failed write is never logged", async () => {
  const logged: string[] = [];
  const original = console.error;
  console.error = (...a: unknown[]) => logged.push(a.join(" "));
  try {
    const { c } = client(() => Promise.resolve({ data: null, error: { message: "secret-token-abc" } }));
    await recordUserEvent(c, { userId: USER, type: "payment_verified", platform: "android" });
  } finally {
    console.error = original;
  }
  assert.equal(logged.length, 1);
  assert.ok(!logged[0].includes("secret-token-abc"));
});

test("only the fixed vocabularies are sent", () => {
  assert.equal(safeErrorCode("google_403"), "google_403");
  assert.equal(safeErrorCode("ya29.some-token-value"), null);
  assert.equal(safeErrorCode(undefined), null);
  assert.equal(safePlanCode("small_family"), "small_family");
  assert.equal(safePlanCode("com.example.app.sub"), null);
  assert.equal(safePlanCode("Token-ABC"), null);
  assert.equal(safePlanCode(undefined), null);
});

test("an unsafe error code or product id is dropped before it leaves the function", async () => {
  const { c, calls } = client(() => Promise.resolve({ data: true, error: null }));
  await recordUserEvent(c, { userId: USER, type: "activation_failed", platform: "android", planCode: "a.b.c", errorCode: "tok_123" });
  assert.equal(calls[0].args.p_plan_code, null);
  assert.equal(calls[0].args.p_error_code, null);
});

test("platform and payment confirmation are derived, not guessed", () => {
  assert.equal(platformFor("google_play"), "android");
  assert.equal(platformFor("app_store"), "ios");
  assert.equal(platformFor("mock"), "unknown");
  assert.equal(platformFor(undefined), "unknown");
  assert.equal(storeConfirmsPayment("subscription", "active"), true);
  assert.equal(storeConfirmsPayment("subscription", "grace"), true);
  assert.equal(storeConfirmsPayment("subscription", "expired"), false);
  assert.equal(storeConfirmsPayment("subscription", "past_due"), false);
  assert.equal(storeConfirmsPayment("premium", "paid"), true);
  assert.equal(storeConfirmsPayment("premium", "refunded"), false);
});
