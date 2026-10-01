// ffmpeg argument builders (pure). Every command runs with the job work
// directory as cwd, so inputs, text files and fonts are plain relative names.
//
// Each scene becomes a video-only H.264 segment of exactly `frames` frames
// and a PCM WAV of exactly frames * (audioRate / fps) samples. Segments are
// joined with the concat demuxer (stream copy) and muxed with one AAC
// encode, so the film is exactly as long as the manifest (± one frame).

import type { FilmOutput } from "./manifest.ts";

export const FONT_REGULAR = "font-regular.ttf";
export const FONT_BOLD = "font-bold.ttf";

const INK = "0x3D2C29";
export const MUTED = "0x8A6F66";
const PAPER = "0xFBF4EC";

export type TextBlock = {
  file: string; // relative text file name
  size: number;
  bold?: boolean;
  color?: string;
  y: string; // drawtext y expression
  box?: boolean;
  x?: string;
};

export function samplesFor(frames: number, out: FilmOutput): number {
  return Math.round((frames * out.audio_rate) / out.fps);
}

export function drawtext(t: TextBlock): string {
  return [
    `drawtext=fontfile=${t.bold ? FONT_BOLD : FONT_REGULAR}`,
    `textfile=${t.file}`,
    "expansion=none",
    `fontsize=${t.size}`,
    `fontcolor=${t.color ?? INK}`,
    "line_spacing=14",
    `x=${t.x ?? "(w-text_w)/2"}`,
    `y=${t.y}`,
    ...(t.box ? ["box=1", "boxcolor=black@0.38", "boxborderw=18"] : []),
  ].join(":");
}

function encodeVideo(frames: number, out: FilmOutput, output: string): string[] {
  return [
    "-an",
    "-frames:v",
    String(frames),
    "-r",
    String(out.fps),
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-crf",
    "23",
    "-maxrate",
    "8M",
    "-bufsize",
    "16M",
    "-pix_fmt",
    "yuv420p",
    "-profile:v",
    "high",
    "-g",
    String(out.fps * 2),
    "-video_track_timescale",
    "90000",
    "-fflags",
    "+bitexact",
    "-flags:v",
    "+bitexact",
    "-map_metadata",
    "-1",
    "-y",
    output,
  ];
}

const base = ["-hide_banner", "-nostdin", "-loglevel", "error"];

/** Paper-coloured text card (title, chapter, memory, milestone, letter, end). */
export function cardVideoArgs(frames: number, out: FilmOutput, texts: TextBlock[], output: string): string[] {
  const filter = ["format=yuv420p", ...texts.map(drawtext)].join(",");
  return [
    ...base,
    "-f",
    "lavfi",
    "-i",
    `color=c=${PAPER}:s=${out.width}x${out.height}:r=${out.fps}`,
    "-vf",
    filter,
    ...encodeVideo(frames, out, output),
  ];
}

/** Fit inside the frame over a blurred, filled copy (portrait and landscape alike). */
function fitFilter(out: FilmOutput, input: string): string {
  const { width: w, height: h } = out;
  return `${input}fps=${out.fps},split[bgsrc][fgsrc];` +
    `[bgsrc]scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h},boxblur=24:2,eq=brightness=-0.06[bg];` +
    `[fgsrc]scale=${w}:${h}:force_original_aspect_ratio=decrease[fg];` +
    `[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1,format=yuv420p`;
}

export function photoVideoArgs(
  frames: number,
  out: FilmOutput,
  input: string,
  texts: TextBlock[],
  output: string,
): string[] {
  const overlay = texts.length ? "," + texts.map(drawtext).join(",") : "";
  return [
    ...base,
    "-loop",
    "1",
    "-framerate",
    String(out.fps),
    "-i",
    input,
    "-filter_complex",
    `${fitFilter(out, "[0:v]")}${overlay}[v]`,
    "-map",
    "[v]",
    ...encodeVideo(frames, out, output),
  ];
}

/** A clip from `startMs`; a short source holds its last frame (never loops). */
export function clipVideoArgs(
  frames: number,
  out: FilmOutput,
  input: string,
  startMs: number,
  texts: TextBlock[],
  output: string,
): string[] {
  const overlay = texts.length ? "," + texts.map(drawtext).join(",") : "";
  return [
    ...base,
    "-ss",
    (startMs / 1000).toFixed(3),
    "-i",
    input,
    "-filter_complex",
    `${fitFilter(out, "[0:v]")},tpad=stop_mode=clone:stop=-1${overlay}[v]`,
    "-map",
    "[v]",
    ...encodeVideo(frames, out, output),
  ];
}

export function silenceAudioArgs(samples: number, out: FilmOutput, output: string): string[] {
  return [
    ...base,
    "-f",
    "lavfi",
    "-i",
    `anullsrc=r=${out.audio_rate}:cl=stereo`,
    "-af",
    `atrim=end_sample=${samples}`,
    "-c:a",
    "pcm_s16le",
    "-y",
    output,
  ];
}

/** Clip sound, loudness-normalised, padded / cut to the exact sample count. */
export function clipAudioArgs(
  samples: number,
  out: FilmOutput,
  input: string,
  startMs: number,
  output: string,
): string[] {
  return [
    ...base,
    "-ss",
    (startMs / 1000).toFixed(3),
    "-i",
    input,
    "-vn",
    "-af",
    `aresample=${out.audio_rate},aformat=sample_fmts=s16:channel_layouts=stereo,` +
    `loudnorm=I=-16:TP=-1.5:LRA=11,aresample=${out.audio_rate},apad=whole_len=${samples},atrim=end_sample=${samples}`,
    "-ar",
    String(out.audio_rate),
    "-ac",
    "2",
    "-c:a",
    "pcm_s16le",
    "-y",
    output,
  ];
}

export function concatArgs(listFile: string, output: string): string[] {
  return [...base, "-f", "concat", "-safe", "0", "-i", listFile, "-c", "copy", "-y", output];
}

export function muxArgs(video: string, audio: string, output: string): string[] {
  return [
    ...base,
    "-i",
    video,
    "-i",
    audio,
    "-map",
    "0:v:0",
    "-map",
    "1:a:0",
    "-c:v",
    "copy",
    "-c:a",
    "aac",
    "-b:a",
    "128k",
    "-ar",
    "48000",
    "-ac",
    "2",
    "-movflags",
    "+faststart",
    "-map_metadata",
    "-1",
    "-fflags",
    "+bitexact",
    "-flags:a",
    "+bitexact",
    "-y",
    output,
  ];
}

export function probeArgs(input: string): string[] {
  return ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", input];
}

export function concatList(files: string[]): string {
  return files.map((f) => `file '${f}'`).join("\n") + "\n";
}
