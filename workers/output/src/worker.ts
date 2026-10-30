// One claimed output job end to end (service role): the first-year film
// (Phase 10) or the offline HTML archive (Phase 11).

import type { SupabaseClient } from "@supabase/supabase-js";
import { ManifestError, parseManifest } from "./manifest.ts";
import { classifyMedia, type MediaErrorCode } from "./probe.ts";
import { type MediaInput, probeFile, RenderError, renderFilm } from "./render.ts";
import { FONT_BOLD, FONT_REGULAR } from "./ffmpeg_args.ts";
import { ArchiveError, buildArchive } from "./html/build.ts";

export const PRODUCTS = ["first_year_film", "first_year_html"] as const;

export type WorkerConfig = {
  workerId: string;
  products: string[];
  ffmpeg: string;
  ffprobe: string;
  fontDir: string;
  workRoot: string;
  leaseSeconds: number;
  heartbeatMs: number;
};

export type Claim = { job_id: string; snapshot_id: string; baby_id: string; product_code: string; attempt: number };

type Job = {
  client: SupabaseClient;
  cfg: WorkerConfig;
  id: string;
  worker: string;
  workDir: string;
  signal: AbortSignal;
};

const MEDIA_ERRORS = new Set<string>(["media_corrupt", "media_missing", "media_unsupported"]);
const OUTPUT_BUCKET = "output-artifacts";

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function first<T>(data: unknown): T | null {
  return (Array.isArray(data) ? data[0] : data) as T | null;
}

export async function claimOne(client: SupabaseClient, cfg: WorkerConfig): Promise<Claim | null> {
  const { data, error } = await client.rpc("output_claim_jobs", {
    p_worker: cfg.workerId,
    p_products: cfg.products,
    p_limit: 1,
    p_lease_seconds: cfg.leaseSeconds,
  });
  if (error) throw new Error(`claim failed: ${error.message}`);
  return first<Claim>(data);
}

/**
 * Artifact protocol shared by every product: row first, staging upload,
 * re-read + hash, verify, move. Returns the slot, or the verify outcome
 * when the upload did not verify (the database already failed the attempt).
 */
async function uploadArtifact(
  job: Job,
  localFile: string,
  fileName: string,
  mime: string,
): Promise<{ artifact_id: string } | string> {
  const { client, id, worker } = job;
  const bytes = await Deno.readFile(localFile);
  const { data: begun, error: beginError } = await client.rpc("output_artifact_begin", {
    p_job_id: id,
    p_worker: worker,
    p_file_name: fileName,
    p_mime_type: mime,
    p_sha256: await sha256Hex(bytes),
    p_size_bytes: bytes.length,
  });
  if (beginError) throw new RenderError("lease_lost", true, beginError.message);
  const slot = first<{ artifact_id: string; staging_path: string; storage_path: string }>(begun)!;
  const { error: upError } = await client.storage.from(OUTPUT_BUCKET).upload(slot.staging_path, bytes, {
    contentType: mime,
    upsert: false,
  });
  if (upError) throw new RenderError("upload_failed", true, upError.message);

  const { data: staged } = await client.storage.from(OUTPUT_BUCKET).download(slot.staging_path);
  const stagedHash = staged ? await sha256Hex(new Uint8Array(await staged.arrayBuffer())) : null;
  const { data: verified } = await client.rpc("output_artifact_verify", {
    p_artifact_id: slot.artifact_id,
    p_worker: worker,
    p_verified_sha256: stagedHash,
  });
  if (verified !== "verified") return String(verified);

  const { error: moveError } = await client.storage.from(OUTPUT_BUCKET).move(slot.staging_path, slot.storage_path);
  if (moveError) throw new RenderError("upload_failed", true, moveError.message);
  return { artifact_id: slot.artifact_id };
}

async function runFilm(job: Job): Promise<string> {
  const { client, cfg, id, worker, workDir, signal } = job;
  const progress = async (percent: number, stage: string) => {
    await client.rpc("film_job_progress_update", {
      p_job_id: id,
      p_worker: worker,
      p_percent: percent,
      p_stage: stage,
    });
  };
  const { data: rows, error } = await client.rpc("film_job_manifest", { p_job_id: id, p_worker: worker });
  if (error) {
    throw error.hint === "manifest_missing"
      ? new RenderError("manifest_missing", false, "film job has no manifest")
      : new RenderError("lease_lost", true, error.message);
  }
  const row = first<{ manifest_content: string; manifest_checksum: string }>(rows)!;
  const manifest = await parseManifest(row.manifest_content, row.manifest_checksum).catch((e) => {
    throw e instanceof ManifestError ? new RenderError("manifest_invalid", false, e.message) : e;
  });
  await Deno.copyFile(`${cfg.fontDir}/Nunito-Regular.ttf`, `${workDir}/${FONT_REGULAR}`);
  await Deno.copyFile(`${cfg.fontDir}/Nunito-Bold.ttf`, `${workDir}/${FONT_BOLD}`);

  // Sources: download, probe, classify. Deterministic media problems end
  // the job (no retry) and name the media for the app.
  await progress(2, "downloading");
  const media = new Map<string, MediaInput>();
  for (const scene of manifest.scenes.filter((s) => s.kind === "photo" || s.kind === "video")) {
    if (media.has(scene.media_id!)) continue;
    const { data: blob, error: dlError } = await client.storage.from("baby-media").download(scene.storage_path!);
    if (dlError || !blob) throw new RenderError("media_missing", false, "source not found", scene.media_id);
    const ext = (scene.storage_path!.split(".").pop() ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "");
    const file = `m_${scene.media_id}.${ext}`;
    await Deno.writeFile(`${workDir}/${file}`, new Uint8Array(await blob.arrayBuffer()));
    const probe = await probeFile({ ffmpeg: cfg.ffmpeg, ffprobe: cfg.ffprobe, workDir, signal }, file);
    const bad: MediaErrorCode | null = classifyMedia(probe, scene.kind as "photo" | "video");
    if (bad) throw new RenderError(bad, false, "unusable source", scene.media_id);
    media.set(scene.media_id!, { file, probe: probe! });
  }

  const result = await renderFilm(manifest, media, {
    ffmpeg: cfg.ffmpeg,
    ffprobe: cfg.ffprobe,
    workDir,
    signal,
    onProgress: progress,
  });

  await progress(95, "uploading");
  const slot = await uploadArtifact(job, `${workDir}/${result.file}`, "ilk-yil-filmi.mp4", "video/mp4");
  if (typeof slot === "string") return slot;
  const { data: published, error: publishError } = await client.rpc("film_artifact_publish", {
    p_artifact_id: slot.artifact_id,
    p_worker: worker,
    p_duration_ms: result.durationMs,
    p_width: result.width,
    p_height: result.height,
    p_fps: result.fps,
    p_video_codec: result.videoCodec,
    p_audio_codec: result.audioCodec,
  });
  if (publishError) throw new RenderError("render_failed", true, publishError.message);
  return String(published);
}

async function runHtml(job: Job): Promise<string> {
  const { client, cfg, id, worker, workDir, signal } = job;
  const progress = async (percent: number, stage: string) => {
    await client.rpc("output_job_progress_update", {
      p_job_id: id,
      p_worker: worker,
      p_percent: percent,
      p_stage: stage,
    });
  };
  const { data: rows, error } = await client.rpc("html_job_payload", { p_job_id: id, p_worker: worker });
  if (error) throw new RenderError("lease_lost", true, error.message);
  const payload = first<{ snapshot_id: string; snapshot_content: string; snapshot_checksum: string }>(rows)!;

  await progress(2, "media");
  const archive = await buildArchive(payload.snapshot_content, payload.snapshot_checksum, {
    ffmpeg: cfg.ffmpeg,
    ffprobe: cfg.ffprobe,
    workDir,
    fontDir: cfg.fontDir,
    snapshotId: payload.snapshot_id,
    signal,
    onProgress: progress,
    fetchMedia: async (path) => {
      const { data: blob, error: dlError } = await client.storage.from("baby-media").download(path);
      return dlError || !blob ? null : new Uint8Array(await blob.arrayBuffer());
    },
  });

  await progress(95, "uploading");
  const slot = await uploadArtifact(job, archive.zipFile, "ilk-yil-arsivi.zip", "application/zip");
  if (typeof slot === "string") return slot;
  const { data: published, error: publishError } = await client.rpc("html_artifact_publish", {
    p_artifact_id: slot.artifact_id,
    p_worker: worker,
    p_entry_count: archive.entryCount,
    p_content_bytes: archive.contentBytes,
    p_skipped_media: archive.skipped.length,
    p_manifest_sha256: archive.manifestSha256,
  });
  if (publishError) throw new RenderError("render_failed", true, publishError.message);
  return String(published);
}

/** Produces and publishes one claimed job; returns the final outcome. */
export async function processJob(client: SupabaseClient, cfg: WorkerConfig, claim: Claim): Promise<string> {
  await Deno.mkdir(cfg.workRoot, { recursive: true });
  const workDir = await Deno.makeTempDir({ dir: cfg.workRoot, prefix: "job-" });
  const abort = new AbortController();
  const job: Job = { client, cfg, id: claim.job_id, worker: cfg.workerId, workDir, signal: abort.signal };

  const heartbeat = setInterval(async () => {
    const { data, error } = await client.rpc("output_job_heartbeat", {
      p_job_id: job.id,
      p_worker: job.worker,
      p_lease_seconds: cfg.leaseSeconds,
    });
    if (error || data !== true) abort.abort();
  }, cfg.heartbeatMs);

  try {
    if (claim.product_code === "first_year_film") return await runFilm(job);
    if (claim.product_code === "first_year_html") return await runHtml(job);
    throw new RenderError("unsupported_product", false, claim.product_code);
  } catch (e) {
    const err = e instanceof RenderError || e instanceof ArchiveError
      ? e
      : new RenderError("render_failed", true, (e as Error)?.message ?? String(e));
    if (err.code === "lease_lost") return "lease_lost";
    if (claim.product_code === "first_year_film" && MEDIA_ERRORS.has(err.code)) {
      await client.rpc("film_job_media_error", {
        p_job_id: job.id,
        p_worker: job.worker,
        p_code: err.code,
        p_media_id: (err as RenderError).mediaId ?? null,
      });
    } else {
      await client.rpc("output_job_fail", {
        p_job_id: job.id,
        p_worker: job.worker,
        p_error_code: err.code,
        p_error: err.message,
        p_retryable: err.retryable,
      });
    }
    return err.code;
  } finally {
    clearInterval(heartbeat);
    await Deno.remove(workDir, { recursive: true }).catch(() => {});
  }
}
