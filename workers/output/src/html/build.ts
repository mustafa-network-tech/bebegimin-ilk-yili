// Builds the offline archive ZIP from a sealed snapshot (ADR 0005).

import { classifyMedia } from "../probe.ts";
import { denoRunner, probeFile, type Runner } from "../render.ts";
import { assertSafeArchivePath, mimeOf, slug } from "./paths.ts";
import { APP_CSS, APP_JS, buildPages, type MediaOutput, readme, type Snapshot } from "./site.ts";
import { readZipEntries, readZipEntry, writeZip, type ZipSource } from "./zip.ts";

export const MAX_ARCHIVE_BYTES = 2_147_483_648; // output bucket limit

export class ArchiveError extends Error {
  constructor(public code: string, public retryable: boolean, message: string) {
    super(message);
  }
}

export type ArchiveOptions = {
  ffmpeg: string;
  ffprobe: string;
  workDir: string;
  fontDir: string;
  snapshotId: string;
  /** Source bytes of a baby-media object, or null when it cannot be read. */
  fetchMedia: (storagePath: string) => Promise<Uint8Array | null>;
  run?: Runner;
  signal?: AbortSignal;
  onProgress?: (percent: number, stage: string) => void | Promise<void>;
};

export type ArchiveResult = {
  zipFile: string;
  root: string;
  entryCount: number;
  contentBytes: number;
  skipped: { media_id: string; reason: string }[];
  manifestSha256: string;
};

const FONTS: [string, string][] = [
  ["Nunito-Regular.ttf", "assets/fonts/nunito-regular.ttf"],
  ["Nunito-Bold.ttf", "assets/fonts/nunito-bold.ttf"],
  ["Lora-Regular.ttf", "assets/fonts/lora-regular.ttf"],
];

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Streaming SHA-256 is not in WebCrypto; files are hashed in one read (bounded by the bucket limit). */
async function sha256OfFile(path: string): Promise<string> {
  return sha256Hex(await Deno.readFile(path));
}

const base = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"];

export function photoArgs(input: string, output: string, box: number): string[] {
  return [
    ...base,
    "-i",
    input,
    "-vf",
    `scale='min(${box},iw)':'min(${box},ih)':force_original_aspect_ratio=decrease`,
    "-frames:v",
    "1",
    "-q:v",
    "3",
    "-map_metadata",
    "-1",
    output,
  ];
}

export function videoArgs(input: string, output: string): string[] {
  return [
    ...base,
    "-i",
    input,
    "-vf",
    "scale='min(1280,iw)':'min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p",
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-crf",
    "24",
    "-profile:v",
    "high",
    "-c:a",
    "aac",
    "-b:a",
    "128k",
    "-ac",
    "2",
    "-movflags",
    "+faststart",
    "-map_metadata",
    "-1",
    "-fflags",
    "+bitexact",
    output,
  ];
}

export function posterArgs(input: string, output: string): string[] {
  return [
    ...base,
    "-i",
    input,
    "-vf",
    "scale='min(960,iw)':'min(960,ih)':force_original_aspect_ratio=decrease",
    "-frames:v",
    "1",
    "-q:v",
    "4",
    "-map_metadata",
    "-1",
    output,
  ];
}

export async function buildArchive(
  snapshotText: string,
  checksum: string,
  opts: ArchiveOptions,
): Promise<ArchiveResult> {
  if ((await sha256Hex(new TextEncoder().encode(snapshotText))) !== checksum) {
    throw new ArchiveError("snapshot_invalid", false, "snapshot checksum mismatch");
  }
  const snapshot = JSON.parse(snapshotText) as Snapshot;
  if (snapshot.schema_version !== 1) throw new ArchiveError("snapshot_invalid", false, "unsupported snapshot");

  const run = opts.run ?? denoRunner;
  const work = opts.workDir;
  const stage = `${work}/bundle`;
  await Deno.mkdir(`${stage}/media`, { recursive: true });
  await Deno.mkdir(`${stage}/assets/fonts`, { recursive: true });

  const ffmpeg = async (args: string[], timeoutMs: number) => {
    const signals = [AbortSignal.timeout(timeoutMs), ...(opts.signal ? [opts.signal] : [])];
    try {
      const res = await run(opts.ffmpeg, args, work, AbortSignal.any(signals));
      return res.code === 0;
    } catch {
      if (opts.signal?.aborted) throw new ArchiveError("lease_lost", true, "aborted");
      return false;
    }
  };
  const exists = async (p: string) => {
    try {
      return (await Deno.stat(p)).size > 0;
    } catch {
      return false;
    }
  };

  // Media: re-encoded (metadata stripped); a failure skips that item only.
  const outputs = new Map<string, MediaOutput>();
  const skipped: { media_id: string; reason: string }[] = [];
  const items = [...snapshot.media].sort((a, b) => a.id.localeCompare(b.id));
  for (let i = 0; i < items.length; i++) {
    const m = items[i];
    if (!/^[0-9a-f-]{36}$/.test(m.id)) throw new ArchiveError("snapshot_invalid", false, "invalid media id");
    const skip = (reason: string) => {
      outputs.set(m.id, { kind: "skipped", reason });
      skipped.push({ media_id: m.id, reason });
    };
    const bytes = await opts.fetchMedia(m.storage_path);
    if (!bytes) {
      skip("media_missing");
    } else {
      const src = `src_${m.id}`;
      await Deno.writeFile(`${work}/${src}`, bytes);
      const probe = await probeFile({
        ffmpeg: opts.ffmpeg,
        ffprobe: opts.ffprobe,
        workDir: work,
        run,
        signal: opts.signal,
      }, src);
      const bad = classifyMedia(probe, m.kind);
      if (bad) {
        skip(bad);
      } else if (m.kind === "photo") {
        const full = `media/${m.id}.jpg`;
        const thumb = `media/${m.id}-k.jpg`;
        const ok = (await ffmpeg(photoArgs(src, `bundle/${full}`, 2048), 120_000)) &&
          (await ffmpeg(photoArgs(src, `bundle/${thumb}`, 480), 120_000)) &&
          (await exists(`${stage}/${full}`)) && (await exists(`${stage}/${thumb}`));
        if (ok) outputs.set(m.id, { kind: "photo", full, thumb });
        else skip("transcode_failed");
      } else {
        const file = `media/${m.id}.mp4`;
        const poster = `media/${m.id}-p.jpg`;
        const ok = (await ffmpeg(videoArgs(src, `bundle/${file}`), 900_000)) && (await exists(`${stage}/${file}`));
        if (!ok) {
          skip("transcode_failed");
        } else {
          const hasPoster = (await ffmpeg(posterArgs(src, `bundle/${poster}`), 120_000)) &&
            (await exists(`${stage}/${poster}`));
          outputs.set(m.id, { kind: "video", file, poster: hasPoster ? poster : null });
        }
      }
      await Deno.remove(`${work}/${src}`).catch(() => {});
    }
    await opts.onProgress?.(5 + Math.floor((75 * (i + 1)) / Math.max(items.length, 1)), "media");
  }

  // Cover picture (optional).
  let cover: string | null = null;
  const coverPath = snapshot.baby.cover_path || snapshot.baby.avatar_path;
  if (coverPath) {
    const bytes = await opts.fetchMedia(coverPath);
    if (bytes) {
      await Deno.writeFile(`${work}/src_cover`, bytes);
      if (
        (await ffmpeg(photoArgs("src_cover", "bundle/media/kapak.jpg", 1200), 120_000)) &&
        (await exists(`${stage}/media/kapak.jpg`))
      ) {
        cover = "media/kapak.jpg";
      }
    }
  }

  await opts.onProgress?.(82, "pages");
  const enc = new TextEncoder();
  const files = new Map<string, Uint8Array | string>(); // path → bytes, or a file inside `stage`
  for (const [path, html] of buildPages(snapshot, outputs, cover)) files.set(path, enc.encode(html));
  files.set("assets/app.css", enc.encode(APP_CSS));
  files.set("assets/app.js", enc.encode(APP_JS));
  for (const [src, dest] of FONTS) {
    files.set(dest, await Deno.readFile(`${opts.fontDir}/${src}`));
  }
  for (const out of outputs.values()) {
    if (out.kind === "photo") {
      files.set(out.full, `${stage}/${out.full}`);
      files.set(out.thumb, `${stage}/${out.thumb}`);
    } else if (out.kind === "video") {
      files.set(out.file, `${stage}/${out.file}`);
      if (out.poster) files.set(out.poster, `${stage}/${out.poster}`);
    }
  }
  if (cover) files.set(cover, `${stage}/${cover}`);
  const babyName = [snapshot.baby.first_name, snapshot.baby.last_name].filter((x) => x && x.trim()).join(" ");
  files.set("benioku.txt", enc.encode(readme(babyName)));
  files.set(
    "surum.txt",
    enc.encode(
      `Bebeğimin İlk Yılı - çevrimdışı arşiv\nPaket biçimi: 1\nSnapshot: ${opts.snapshotId}\nSnapshot checksum: ${checksum}\n`,
    ),
  );

  // Manifest of every entry (sorted), then the ZIP with a single root folder.
  const entries: { path: string; size: number; sha256: string; mime: string }[] = [];
  for (const path of [...files.keys()].sort()) {
    assertSafeArchivePath(path);
    const v = files.get(path)!;
    const bytes = typeof v === "string" ? null : v;
    entries.push({
      path,
      size: bytes ? bytes.length : (await Deno.stat(v as string)).size,
      sha256: bytes ? await sha256Hex(bytes) : await sha256OfFile(v as string),
      mime: mimeOf(path),
    });
  }
  const totalBytes = entries.reduce((n, e) => n + e.size, 0);
  const root = `${slug(snapshot.baby.first_name)}-ilk-yil-arsivi`;
  const manifest = {
    format: "bebegimin-offline-archive",
    version: 1,
    product: "first_year_html",
    baby_id: snapshot.baby.id,
    snapshot_id: opts.snapshotId,
    snapshot_checksum: checksum,
    root,
    entry_count: entries.length,
    total_bytes: totalBytes,
    skipped,
    entries,
  };
  const manifestBytes = enc.encode(JSON.stringify(manifest, null, 2) + "\n");
  if (totalBytes + manifestBytes.length > MAX_ARCHIVE_BYTES) {
    throw new ArchiveError("bundle_too_large", false, "archive exceeds the output limit");
  }

  await opts.onProgress?.(88, "packing");
  const sources: ZipSource[] = [
    { path: `${root}/manifest.json`, bytes: manifestBytes },
    ...entries.map((e): ZipSource => {
      const v = files.get(e.path)!;
      return typeof v === "string" ? { path: `${root}/${e.path}`, file: v } : { path: `${root}/${e.path}`, bytes: v };
    }),
  ];
  const zipFile = `${work}/ilk-yil-arsivi.zip`;
  await writeZip(zipFile, sources);
  if ((await Deno.stat(zipFile)).size > MAX_ARCHIVE_BYTES) {
    throw new ArchiveError("bundle_too_large", false, "archive exceeds the output limit");
  }

  await opts.onProgress?.(92, "verifying");
  await verifyArchive(zipFile, root, manifestBytes);
  return {
    zipFile,
    root,
    entryCount: entries.length + 1,
    contentBytes: totalBytes + manifestBytes.length,
    skipped,
    manifestSha256: await sha256Hex(manifestBytes),
  };
}

/** The ZIP holds exactly the manifest entries, byte for byte. */
export async function verifyArchive(zipFile: string, root: string, manifestBytes: Uint8Array): Promise<void> {
  const manifest = JSON.parse(new TextDecoder().decode(manifestBytes)) as {
    entries: { path: string; size: number; sha256: string }[];
  };
  const zipEntries = await readZipEntries(zipFile);
  const expected = [`${root}/manifest.json`, ...manifest.entries.map((e) => `${root}/${e.path}`)];
  const actual = zipEntries.map((e) => e.path);
  if (expected.length !== actual.length || expected.some((p, i) => p !== actual[i])) {
    throw new ArchiveError("archive_mismatch", true, "zip entries differ from the manifest");
  }
  for (const entry of zipEntries.slice(1)) {
    const want = manifest.entries.find((e) => `${root}/${e.path}` === entry.path)!;
    const parts: Uint8Array[] = [];
    await readZipEntry(zipFile, entry, (c) => void parts.push(c));
    const all = new Uint8Array(entry.size);
    let o = 0;
    for (const p of parts) {
      all.set(p, o);
      o += p.length;
    }
    if (entry.size !== want.size || (await sha256Hex(all)) !== want.sha256) {
      throw new ArchiveError("archive_mismatch", true, `zip entry differs: ${entry.path}`);
    }
  }
}
