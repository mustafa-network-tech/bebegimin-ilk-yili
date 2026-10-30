// Runs with `deno test` or `node --experimental-strip-types --test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bookClientWorker,
  finalizeAction,
  looksLikePdf,
  parseFinalizeRequest,
  sha256Hex,
} from "../_shared/book_artifact.ts";

const enc = new TextEncoder();
const pdf = (body: string) => enc.encode(`%PDF-1.7\n${body}\n%%EOF\n`);

test("finalize request: valid artifact id and page count", () => {
  assert.deepEqual(
    parseFinalizeRequest({
      artifact_id: "8d2c1a52-0000-4000-8000-000000000001",
      page_count: 48,
    }),
    { artifactId: "8d2c1a52-0000-4000-8000-000000000001", pageCount: 48 },
  );
});

test("finalize request: malformed bodies are rejected", () => {
  assert.equal(parseFinalizeRequest(null), null);
  assert.equal(parseFinalizeRequest({ artifact_id: "x", page_count: 1 }), null);
  assert.equal(
    parseFinalizeRequest({
      artifact_id: "8d2c1a52-0000-4000-8000-000000000001",
      page_count: 0,
    }),
    null,
  );
  assert.equal(
    parseFinalizeRequest({
      artifact_id: "8d2c1a52-0000-4000-8000-000000000001",
      page_count: 2.5,
    }),
    null,
  );
  assert.equal(
    parseFinalizeRequest({
      artifact_id: "8d2c1a52-0000-4000-8000-000000000001",
      page_count: "4",
    }),
    null,
  );
  assert.equal(
    parseFinalizeRequest({
      artifact_id: "8d2c1a52-0000-4000-8000-000000000001",
      page_count: 5001,
    }),
    null,
  );
});

test("PDF check: header and trailing EOF marker", () => {
  assert.equal(looksLikePdf(pdf("x".repeat(100))), true);
  assert.equal(
    looksLikePdf(enc.encode("<html>" + "x".repeat(100) + "%%EOF")),
    false,
  );
  assert.equal(
    looksLikePdf(enc.encode("%PDF-1.7" + "x".repeat(100))),
    false,
    "truncated upload",
  );
  assert.equal(looksLikePdf(enc.encode("%PDF-")), false, "too small");
  const eofThenJunk = new Uint8Array([
    ...pdf("y".repeat(100)),
    ...new Uint8Array(2000),
  ]);
  assert.equal(
    looksLikePdf(eofThenJunk),
    false,
    "EOF marker must be in the last kilobyte",
  );
});

test("sha256 is lowercase hex of the exact bytes", async () => {
  assert.equal(
    await sha256Hex(enc.encode("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

test("lease owner matches book_client_worker()", () => {
  assert.equal(
    bookClientWorker("9e000000-0000-4000-8000-000000000001"),
    "book-client:9e000000-0000-4000-8000-000000000001",
  );
});

test("finalize is safe to repeat: every artifact state has one action", () => {
  assert.equal(finalizeAction("staging"), "verify");
  // Verified earlier, but the move or the publish did not finish.
  assert.equal(finalizeAction("verified"), "resume");
  // Published earlier; the reply to the app was lost.
  assert.equal(finalizeAction("ready"), "already_ready");
  assert.equal(finalizeAction("quarantined"), "refuse");
  assert.equal(finalizeAction("revoked"), "refuse");
});
