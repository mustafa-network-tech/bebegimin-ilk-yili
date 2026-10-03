// Output worker entry point (film: ADR 0004, offline archive: ADR 0005).
// One job at a time; stops after the current job on SIGTERM / SIGINT.
import { createClient } from "@supabase/supabase-js";
import { claimOne, processJob, PRODUCTS, type WorkerConfig } from "./worker.ts";

function env(name: string, fallback?: string): string {
  const value = Deno.env.get(name) ?? fallback;
  if (value === undefined || value === "") throw new Error(`missing env ${name}`);
  return value;
}

const products = env("WORKER_PRODUCTS", PRODUCTS.join(",")).split(",").map((p) => p.trim()).filter(Boolean);
for (const p of products) {
  if (!(PRODUCTS as readonly string[]).includes(p)) throw new Error(`unsupported product ${p}`);
}

const cfg: WorkerConfig = {
  workerId: env("WORKER_ID", `output-${crypto.randomUUID().slice(0, 8)}`),
  products,
  ffmpeg: env("FFMPEG_PATH", "ffmpeg"),
  ffprobe: env("FFPROBE_PATH", "ffprobe"),
  fontDir: env("FONT_DIR", "/app/fonts"),
  workRoot: env("WORK_DIR", "/tmp/film"),
  leaseSeconds: 300,
  heartbeatMs: 60_000,
};
const pollMs = Number(env("POLL_INTERVAL_MS", "15000"));

const client = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

let stopping = false;
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  try {
    Deno.addSignalListener(signal, () => {
      stopping = true;
    });
  } catch {
    // Not every platform supports every signal.
  }
}

console.log(`output worker ${cfg.workerId} started for ${products.join(", ")}`);
while (!stopping) {
  try {
    const claim = await claimOne(client, cfg);
    if (!claim) {
      await new Promise((r) => setTimeout(r, pollMs));
      continue;
    }
    const started = Date.now();
    const outcome = await processJob(client, cfg, claim);
    // Ids and outcome only: no URLs, paths or user content in logs.
    console.log(
      `job ${claim.job_id} attempt ${claim.attempt}: ${outcome} in ${Math.round((Date.now() - started) / 1000)}s`,
    );
  } catch (e) {
    console.error(`worker loop error: ${(e as Error).message}`);
    await new Promise((r) => setTimeout(r, pollMs));
  }
}
console.log("output worker stopped");
