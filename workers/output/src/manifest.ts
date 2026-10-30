// Film scene manifest (build_film_manifest, schema version 1).

export const MAX_FILM_MS = 600_000;

export type SceneKind = "title" | "chapter" | "memory" | "milestone" | "photo" | "video" | "letter" | "end";

export type Scene = {
  index: number;
  kind: SceneKind;
  chapter: number;
  duration_ms: number;
  title?: string | null;
  subtitle?: string | null;
  text?: string | null;
  caption?: string | null;
  media_id?: string;
  storage_path?: string;
  clip_start_ms?: number;
  source_duration_ms?: number | null;
};

export type FilmOutput = {
  width: number;
  height: number;
  fps: number;
  video_codec: string;
  audio_codec: string;
  audio_rate: number;
};

export type FilmManifest = {
  manifest_version: 1;
  product: "first_year_film";
  baby_id: string;
  snapshot_id: string;
  snapshot_checksum: string;
  output: FilmOutput;
  max_duration_ms: number;
  total_duration_ms: number;
  over_limit: boolean;
  scenes: Scene[];
};

export class ManifestError extends Error {}

const KINDS = new Set<SceneKind>(["title", "chapter", "memory", "milestone", "photo", "video", "letter", "end"]);
const STORAGE_PATH = /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[A-Za-z0-9._-]{1,120}$/i;

export async function sha256HexOfText(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Verifies the sealed checksum, then the structure the renderer relies on. */
export async function parseManifest(text: string, checksum: string): Promise<FilmManifest> {
  if ((await sha256HexOfText(text)) !== checksum) {
    throw new ManifestError("manifest checksum mismatch");
  }
  const m = JSON.parse(text) as FilmManifest;
  if (m.manifest_version !== 1 || m.product !== "first_year_film") {
    throw new ManifestError("unsupported manifest");
  }
  if (m.over_limit || m.max_duration_ms !== MAX_FILM_MS || m.total_duration_ms > MAX_FILM_MS) {
    throw new ManifestError("manifest exceeds the film limit");
  }
  const o = m.output;
  if (!o || o.width <= 0 || o.height <= 0 || o.fps <= 0 || o.audio_rate <= 0) {
    throw new ManifestError("invalid output profile");
  }
  if (!Array.isArray(m.scenes) || m.scenes.length < 2) {
    throw new ManifestError("manifest has no scenes");
  }
  let sum = 0;
  m.scenes.forEach((s, i) => {
    if (s.index !== i || !KINDS.has(s.kind) || !Number.isInteger(s.duration_ms) || s.duration_ms <= 0) {
      throw new ManifestError(`invalid scene ${i}`);
    }
    if ((s.kind === "photo" || s.kind === "video") && (!s.media_id || !STORAGE_PATH.test(s.storage_path ?? ""))) {
      throw new ManifestError(`invalid media scene ${i}`);
    }
    sum += s.duration_ms;
  });
  if (sum !== m.total_duration_ms) {
    throw new ManifestError("scene durations do not add up");
  }
  return m;
}

/**
 * Frames per scene with cumulative rounding: the film is exactly
 * round(total * fps) frames long, whatever the individual durations are.
 */
export function planFrames(scenes: Pick<Scene, "duration_ms">[], fps: number): number[] {
  const frames: number[] = [];
  let elapsed = 0;
  let done = 0;
  for (const s of scenes) {
    elapsed += s.duration_ms;
    const end = Math.round((elapsed * fps) / 1000);
    frames.push(Math.max(end - done, 1));
    done += frames[frames.length - 1];
  }
  return frames;
}
