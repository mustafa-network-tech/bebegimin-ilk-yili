// ffprobe JSON → what the renderer needs, plus the media error class.

export type MediaErrorCode = "media_corrupt" | "media_missing" | "media_unsupported";

export type MediaProbe = {
  hasVideo: boolean;
  hasAudio: boolean;
  width: number;
  height: number;
  durationMs: number | null;
  videoCodec: string | null;
  audioCodec: string | null;
  fps: number | null;
};

type Stream = {
  codec_type?: string;
  codec_name?: string;
  width?: number;
  height?: number;
  r_frame_rate?: string;
  avg_frame_rate?: string;
  duration?: string;
};

export type FfprobeJson = { streams?: Stream[]; format?: { duration?: string; format_name?: string } };

function rate(value: string | undefined): number | null {
  if (!value) return null;
  const [n, d] = value.split("/").map(Number);
  if (!Number.isFinite(n) || !Number.isFinite(d) || d === 0 || n === 0) return null;
  return Math.round((n / d) * 1000) / 1000;
}

export function readProbe(json: FfprobeJson): MediaProbe {
  const streams = json.streams ?? [];
  const video = streams.find((s) => s.codec_type === "video");
  const audio = streams.find((s) => s.codec_type === "audio");
  const seconds = Number(json.format?.duration ?? video?.duration);
  return {
    hasVideo: !!video,
    hasAudio: !!audio,
    width: video?.width ?? 0,
    height: video?.height ?? 0,
    durationMs: Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds * 1000) : null,
    videoCodec: video?.codec_name ?? null,
    audioCodec: audio?.codec_name ?? null,
    fps: rate(video?.avg_frame_rate) ?? rate(video?.r_frame_rate),
  };
}

/** null = usable; otherwise why the source cannot go into the film. */
export function classifyMedia(probe: MediaProbe | null, kind: "photo" | "video"): MediaErrorCode | null {
  if (!probe) return "media_corrupt";
  if (!probe.hasVideo || probe.width <= 0 || probe.height <= 0) return "media_unsupported";
  if (kind === "video" && (probe.durationMs === null || probe.durationMs < 100)) return "media_corrupt";
  return null;
}
