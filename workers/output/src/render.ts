// Renders a verified manifest into one MP4 inside `workDir`.

import {
  cardVideoArgs,
  clipAudioArgs,
  clipVideoArgs,
  concatArgs,
  concatList,
  MUTED,
  muxArgs,
  photoVideoArgs,
  probeArgs,
  samplesFor,
  silenceAudioArgs,
  type TextBlock,
} from "./ffmpeg_args.ts";
import { type FilmManifest, planFrames, type Scene } from "./manifest.ts";
import { type MediaProbe, readProbe } from "./probe.ts";
import { sanitizeText, wrapText } from "./text.ts";

export type RunResult = { code: number; stdout: string; stderr: string };
export type Runner = (cmd: string, args: string[], cwd: string, signal?: AbortSignal) => Promise<RunResult>;

export type MediaInput = { file: string; probe: MediaProbe };

export type RenderOptions = {
  ffmpeg: string;
  ffprobe: string;
  workDir: string;
  run?: Runner;
  signal?: AbortSignal;
  sceneTimeoutMs?: number;
  onProgress?: (percent: number, stage: string) => void | Promise<void>;
};

export type FilmResult = {
  file: string;
  durationMs: number;
  width: number;
  height: number;
  fps: number;
  videoCodec: string;
  audioCodec: string;
};

/** A failure with the job error code the worker reports. */
export class RenderError extends Error {
  constructor(public code: string, public retryable: boolean, message: string, public mediaId?: string) {
    super(message);
  }
}

export const denoRunner: Runner = async (cmd, args, cwd, signal) => {
  const out = await new Deno.Command(cmd, { args, cwd, stdout: "piped", stderr: "piped", signal }).output();
  const dec = new TextDecoder();
  return { code: out.code, stdout: dec.decode(out.stdout), stderr: dec.decode(out.stderr) };
};

export async function probeFile(opts: RenderOptions, file: string): Promise<MediaProbe | null> {
  const run = opts.run ?? denoRunner;
  try {
    const res = await run(opts.ffprobe, probeArgs(file), opts.workDir, opts.signal);
    if (res.code !== 0) return null;
    return readProbe(JSON.parse(res.stdout));
  } catch (e) {
    if (opts.signal?.aborted) throw e;
    return null;
  }
}

/** Text layout per scene kind; files are written next to the segments. */
function layout(scene: Scene, write: (name: string, lines: string[]) => string): TextBlock[] {
  const t = (name: string, value: string | null | undefined, maxChars = 34, maxLines = 2) => {
    const lines = wrapText(value ?? "", maxChars, maxLines);
    return lines.length ? write(name, lines) : null;
  };
  const blocks: (TextBlock | null)[] = [];
  const add = (file: string | null, b: Omit<TextBlock, "file">) => blocks.push(file ? { file, ...b } : null);
  switch (scene.kind) {
    case "title":
    case "end":
      add(t("title", scene.title, 30, 2), { size: 92, bold: true, y: "(h/2)-text_h-10" });
      add(t("subtitle", scene.subtitle, 50, 1), { size: 44, color: MUTED, y: "(h/2)+40" });
      break;
    case "chapter":
      add(t("title", scene.title, 30, 1), { size: 120, bold: true, y: "(h/2)-text_h" });
      add(t("subtitle", scene.subtitle, 60, 1), { size: 40, color: MUTED, y: "(h/2)+50" });
      break;
    case "memory":
    case "milestone":
    case "letter":
      add(t("title", scene.title, 34, 2), { size: 72, bold: true, y: "h*0.16" });
      add(t("text", scene.text, 46, 7), { size: 44, y: "h*0.36" });
      add(t("subtitle", scene.subtitle, 60, 1), { size: 38, color: MUTED, y: "h*0.84" });
      break;
    case "photo":
    case "video": {
      const lines = [...wrapText(scene.caption ?? "", 60, 2), ...wrapText(scene.subtitle ?? "", 60, 1)];
      if (lines.length) {
        blocks.push({ file: write("caption", lines), size: 40, color: "white", x: "80", y: "h-text_h-80", box: true });
      }
      break;
    }
  }
  return blocks.filter((b): b is TextBlock => b !== null);
}

export async function renderFilm(
  manifest: FilmManifest,
  media: Map<string, MediaInput>,
  opts: RenderOptions,
): Promise<FilmResult> {
  const run = opts.run ?? denoRunner;
  const out = manifest.output;
  const frames = planFrames(manifest.scenes, out.fps);
  const videos: string[] = [];
  const audios: string[] = [];

  const exec = async (args: string[], what: string, scene?: Scene) => {
    const signals = [AbortSignal.timeout(opts.sceneTimeoutMs ?? 180_000), ...(opts.signal ? [opts.signal] : [])];
    let res: RunResult;
    try {
      res = await run(opts.ffmpeg, args, opts.workDir, AbortSignal.any(signals));
    } catch (e) {
      if (opts.signal?.aborted) throw new RenderError("lease_lost", true, "render aborted");
      throw new RenderError("transcode_failed", true, `${what}: ${(e as Error).message}`, scene?.media_id);
    }
    if (res.code !== 0) {
      throw new RenderError(
        "transcode_failed",
        true,
        `${what} failed: ${sanitizeText(res.stderr).slice(-300)}`,
        scene?.media_id,
      );
    }
  };

  for (const scene of manifest.scenes) {
    const i = scene.index;
    const tag = String(i).padStart(4, "0");
    const n = frames[i];
    const write = (name: string, lines: string[]) => {
      const file = `t_${tag}_${name}.txt`;
      Deno.writeTextFileSync(`${opts.workDir}/${file}`, lines.join("\n"));
      return file;
    };
    const texts = layout(scene, write);
    const video = `v_${tag}.mp4`;
    const audio = `a_${tag}.wav`;
    const samples = samplesFor(n, out);

    if (scene.kind === "photo" || scene.kind === "video") {
      const input = media.get(scene.media_id!);
      if (!input) throw new RenderError("media_missing", false, "media not prepared", scene.media_id);
      if (scene.kind === "photo") {
        await exec(photoVideoArgs(n, out, input.file, texts, video), `scene ${i} photo`, scene);
        await exec(silenceAudioArgs(samples, out, audio), `scene ${i} silence`);
      } else {
        const start = scene.clip_start_ms ?? 0;
        await exec(clipVideoArgs(n, out, input.file, start, texts, video), `scene ${i} video`, scene);
        await exec(
          input.probe.hasAudio
            ? clipAudioArgs(samples, out, input.file, start, audio)
            : silenceAudioArgs(samples, out, audio),
          `scene ${i} audio`,
          scene,
        );
      }
    } else {
      await exec(cardVideoArgs(n, out, texts, video), `scene ${i} card`);
      await exec(silenceAudioArgs(samples, out, audio), `scene ${i} silence`);
    }
    videos.push(video);
    audios.push(audio);
    await opts.onProgress?.(10 + Math.floor((80 * (i + 1)) / manifest.scenes.length), "encoding");
  }

  await opts.onProgress?.(92, "muxing");
  Deno.writeTextFileSync(`${opts.workDir}/videos.txt`, concatList(videos));
  Deno.writeTextFileSync(`${opts.workDir}/audios.txt`, concatList(audios));
  await exec(concatArgs("videos.txt", "film_video.mp4"), "video concat");
  await exec(concatArgs("audios.txt", "film_audio.wav"), "audio concat");
  const file = "ilk-yil-filmi.mp4";
  await exec(muxArgs("film_video.mp4", "film_audio.wav", file), "mux");

  const probe = await probeFile({ ...opts, run }, file);
  if (!probe || !probe.durationMs || !probe.videoCodec || !probe.audioCodec || !probe.fps) {
    throw new RenderError("probe_failed", true, "final film could not be probed");
  }
  return {
    file,
    durationMs: probe.durationMs,
    width: probe.width,
    height: probe.height,
    fps: probe.fps,
    videoCodec: probe.videoCodec,
    audioCodec: probe.audioCodec,
  };
}
