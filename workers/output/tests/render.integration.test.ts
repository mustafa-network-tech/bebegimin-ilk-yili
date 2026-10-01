// Real ffmpeg render. Runs when FFMPEG_PATH and FFPROBE_PATH are set:
//   FFMPEG_PATH=... FFPROBE_PATH=... deno task test
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseManifest, sha256HexOfText } from "../src/manifest.ts";
import { classifyMedia } from "../src/probe.ts";
import { denoRunner, probeFile, renderFilm } from "../src/render.ts";
import { FONT_BOLD, FONT_REGULAR } from "../src/ffmpeg_args.ts";
import { manifest } from "./fixtures.ts";

const ffmpeg = Deno.env.get("FFMPEG_PATH");
const ffprobe = Deno.env.get("FFPROBE_PATH");
const root = new URL("../../../", import.meta.url);
const path = (rel: string) => decodeURIComponent(new URL(rel, root).pathname).replace(/^\/([A-Za-z]:)/, "$1");

const BABY = "11111111-1111-4111-8111-111111111111";
const PHOTO = "22222222-2222-4222-8222-222222222222";
const LANDSCAPE = "22222222-2222-4222-8222-222222222223";
const PORTRAIT_VIDEO = "44444444-4444-4444-8444-444444444444";
const SHORT_SILENT = "55555555-5555-4555-8555-555555555555";

test("renders a film whose probe matches the manifest (portrait + landscape, audio + silent, short clip)", {
  skip: !ffmpeg || !ffprobe ? "FFMPEG_PATH / FFPROBE_PATH not set" : false,
}, async () => {
  const workDir = await Deno.makeTempDir({ prefix: "film-it-" });
  try {
    await Deno.copyFile(path("assets/fonts/Nunito-Regular.ttf"), `${workDir}/${FONT_REGULAR}`);
    await Deno.copyFile(path("assets/fonts/Nunito-Bold.ttf"), `${workDir}/${FONT_BOLD}`);
    await Deno.copyFile(path("test/fixtures/portrait.jpg"), `${workDir}/m_${PHOTO}.jpg`);
    await Deno.copyFile(path("test/fixtures/landscape.jpg"), `${workDir}/m_${LANDSCAPE}.jpg`);
    // A portrait phone video with sound and a 0.5 s silent clip.
    const gen = async (args: string[]) => {
      const r = await denoRunner(ffmpeg!, ["-hide_banner", "-loglevel", "error", ...args], workDir);
      assert.equal(r.code, 0, r.stderr);
    };
    await gen([
      "-f",
      "lavfi",
      "-i",
      "testsrc2=s=720x1280:r=30:d=3",
      "-f",
      "lavfi",
      "-i",
      "sine=f=440:d=3",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-shortest",
      `m_${PORTRAIT_VIDEO}.mp4`,
    ]);
    await gen([
      "-f",
      "lavfi",
      "-i",
      "testsrc=s=640x360:r=25:d=0.5",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      `m_${SHORT_SILENT}.mp4`,
    ]);

    const m = manifest([
      { kind: "title", duration_ms: 1500, title: "Nil'in İlk Yılı 💛", subtitle: "1 Ocak 2025 – 1 Ocak 2026" },
      { kind: "chapter", duration_ms: 900, title: "1. Ay", subtitle: "1 Ocak 2025 – 31 Ocak 2025" },
      {
        kind: "photo",
        duration_ms: 1234,
        media_id: PHOTO,
        storage_path: `${BABY}/${PHOTO}/p.jpg`,
        caption: "Uykucu",
        subtitle: "3 Ocak 2025",
      },
      { kind: "photo", duration_ms: 1001, media_id: LANDSCAPE, storage_path: `${BABY}/${LANDSCAPE}/p.jpg` },
      {
        kind: "video",
        duration_ms: 2000,
        media_id: PORTRAIT_VIDEO,
        storage_path: `${BABY}/${PORTRAIT_VIDEO}/v.mp4`,
        clip_start_ms: 500,
      },
      {
        kind: "video",
        duration_ms: 1500,
        media_id: SHORT_SILENT,
        storage_path: `${BABY}/${SHORT_SILENT}/v.mp4`,
        clip_start_ms: 0,
      },
      {
        kind: "letter",
        duration_ms: 1300,
        title: "Sana bir mektup",
        text: "Canım Nil, ".repeat(40),
        subtitle: "Zeynep",
      },
      { kind: "end", duration_ms: 1000, title: "Seni çok seviyoruz", subtitle: "Nil" },
    ]);
    const text = JSON.stringify(m);
    const verified = await parseManifest(text, await sha256HexOfText(text));

    const opts = { ffmpeg: ffmpeg!, ffprobe: ffprobe!, workDir };
    const media = new Map();
    for (
      const [id, ext, kind] of [
        [PHOTO, "jpg", "photo"],
        [LANDSCAPE, "jpg", "photo"],
        [PORTRAIT_VIDEO, "mp4", "video"],
        [SHORT_SILENT, "mp4", "video"],
      ] as const
    ) {
      const file = `m_${id}.${ext}`;
      const probe = await probeFile(opts, file);
      assert.equal(classifyMedia(probe, kind), null, id);
      media.set(id, { file, probe });
    }
    assert.equal(media.get(SHORT_SILENT).probe.hasAudio, false);

    const progress: number[] = [];
    const result = await renderFilm(verified, media, { ...opts, onProgress: (p) => void progress.push(p) });
    assert.equal(result.width, 1920);
    assert.equal(result.height, 1080);
    assert.equal(result.videoCodec, "h264");
    assert.equal(result.audioCodec, "aac");
    assert.equal(result.fps, 30);
    // Within one frame + AAC priming of the planned 10.435 s; never longer than planned + 100 ms.
    assert.ok(
      Math.abs(result.durationMs - verified.total_duration_ms) <= 100,
      `${result.durationMs} vs ${verified.total_duration_ms}`,
    );
    assert.ok(progress.at(-1)! >= 90);
    const keep = Deno.env.get("FILM_KEEP_DIR");
    if (keep) await Deno.copyFile(`${workDir}/${result.file}`, `${keep}/${result.file}`);

    const garbage = `${workDir}/m_broken.mp4`;
    await Deno.writeFile(garbage, new TextEncoder().encode("not a video at all"));
    assert.equal(classifyMedia(await probeFile(opts, "m_broken.mp4"), "video"), "media_corrupt");
  } finally {
    await Deno.remove(workDir, { recursive: true }).catch(() => {});
  }
});
