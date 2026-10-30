import { test } from "node:test";
import assert from "node:assert/strict";
import { ManifestError, parseManifest, planFrames, sha256HexOfText } from "../src/manifest.ts";
import { sanitizeText, wrapText } from "../src/text.ts";
import {
  cardVideoArgs,
  clipAudioArgs,
  clipVideoArgs,
  concatList,
  drawtext,
  muxArgs,
  photoVideoArgs,
  samplesFor,
} from "../src/ffmpeg_args.ts";
import { classifyMedia, readProbe } from "../src/probe.ts";
import { manifest, output } from "./fixtures.ts";

const BABY = "11111111-1111-4111-8111-111111111111";
const MEDIA = "22222222-2222-4222-8222-222222222222";

const sample = () =>
  manifest([
    { kind: "title", duration_ms: 4000, title: "Nil'in İlk Yılı", subtitle: "1 Ocak 2025 – 1 Ocak 2026" },
    { kind: "photo", duration_ms: 3500, media_id: MEDIA, storage_path: `${BABY}/${MEDIA}/p.jpg` },
    { kind: "end", duration_ms: 4000, title: "Seni çok seviyoruz" },
  ]);

async function sealed(m: unknown) {
  const text = JSON.stringify(m);
  return { text, checksum: await sha256HexOfText(text) };
}

test("manifest: a sealed manifest parses", async () => {
  const { text, checksum } = await sealed(sample());
  const m = await parseManifest(text, checksum);
  assert.equal(m.scenes.length, 3);
  assert.equal(m.total_duration_ms, 11500);
});

test("manifest: tampering, overflow and inconsistencies are refused", async () => {
  const { text, checksum } = await sealed(sample());
  await assert.rejects(parseManifest(text.replace("Nil", "Ela"), checksum), ManifestError);
  const over = { ...sample(), total_duration_ms: 600001 };
  await assert.rejects(
    async () => parseManifest(...Object.values(await sealed(over)) as [string, string]),
    ManifestError,
  );
  const sum = { ...sample(), total_duration_ms: 11000 };
  await assert.rejects(
    async () => parseManifest(...Object.values(await sealed(sum)) as [string, string]),
    ManifestError,
  );
  const flagged = { ...sample(), over_limit: true };
  await assert.rejects(
    async () => parseManifest(...Object.values(await sealed(flagged)) as [string, string]),
    ManifestError,
  );
  const badPath = manifest([
    { kind: "title", duration_ms: 1000 },
    { kind: "photo", duration_ms: 1000, media_id: MEDIA, storage_path: "../../etc/passwd" },
  ]);
  await assert.rejects(
    async () => parseManifest(...Object.values(await sealed(badPath)) as [string, string]),
    ManifestError,
  );
});

test("frames: cumulative rounding keeps the film exactly as long as the manifest", () => {
  assert.deepEqual(planFrames([{ duration_ms: 3500 }, { duration_ms: 3500 }], 30), [105, 105]);
  const odd = planFrames(Array.from({ length: 300 }, () => ({ duration_ms: 2017 })), 30);
  assert.equal(odd.reduce((a, b) => a + b, 0), Math.round((300 * 2017 * 30) / 1000));
  assert.ok(odd.every((f) => f >= 60 && f <= 61));
  assert.equal(samplesFor(105, output), 168000);
});

test("text: emoji and control characters are removed, long text is wrapped and capped", () => {
  assert.equal(sanitizeText("İlk adım 👣\u0007  çok   güzel ❤️"), "İlk adım çok güzel");
  assert.deepEqual(wrapText("bir iki üç dört beş", 7, 5), ["bir iki", "üç dört", "beş"]);
  const capped = wrapText("a ".repeat(200), 10, 2);
  assert.equal(capped.length, 2);
  assert.ok(capped[1].endsWith("…"));
  assert.deepEqual(wrapText("çokuzunbirkelime", 5, 5), ["çokuz", "unbir", "kelim", "e"]);
});

test("ffmpeg: exact frame counts, profile, no metadata, text from files", () => {
  const card = cardVideoArgs(105, output, [{ file: "t.txt", size: 90, y: "100" }], "v.mp4");
  for (const flag of ["-frames:v", "105", "libx264", "yuv420p", "-map_metadata", "-an"]) {
    assert.ok(card.includes(flag), flag);
  }
  const dt = drawtext({ file: "t_0001_title.txt", size: 90, y: "100", box: true });
  assert.ok(dt.includes("textfile=t_0001_title.txt") && dt.includes("expansion=none") && dt.includes("box=1"));
  const photo = photoVideoArgs(60, output, "m_x.jpg", [], "v.mp4").join(" ");
  assert.ok(
    photo.includes("-loop 1") && photo.includes("force_original_aspect_ratio=decrease") && photo.includes("boxblur"),
  );
  const clip = clipVideoArgs(60, output, "m_x.mp4", 1500, [], "v.mp4").join(" ");
  assert.ok(clip.includes("-ss 1.500") && clip.includes("tpad=stop_mode=clone"), "short clips hold the last frame");
  const audio = clipAudioArgs(96000, output, "m_x.mp4", 0, "a.wav").join(" ");
  assert.ok(audio.includes("loudnorm=I=-16") && audio.includes("atrim=end_sample=96000"));
  const mux = muxArgs("v.mp4", "a.wav", "out.mp4");
  assert.ok(mux.includes("+faststart") && !mux.includes("-shortest") && mux.includes("aac"));
  assert.equal(concatList(["a.mp4", "b.mp4"]), "file 'a.mp4'\nfile 'b.mp4'\n");
});

test("probe: readable media is classified, broken media gets an error code", () => {
  const ok = readProbe({
    streams: [{ codec_type: "video", codec_name: "h264", width: 1080, height: 1920, avg_frame_rate: "30000/1001" }, {
      codec_type: "audio",
      codec_name: "aac",
    }],
    format: { duration: "12.480000" },
  });
  assert.deepEqual([ok.width, ok.height, ok.durationMs, ok.hasAudio, ok.fps], [1080, 1920, 12480, true, 29.97]);
  assert.equal(classifyMedia(ok, "video"), null);
  assert.equal(classifyMedia(null, "photo"), "media_corrupt");
  assert.equal(classifyMedia(readProbe({ streams: [{ codec_type: "audio" }] }), "video"), "media_unsupported");
  assert.equal(
    classifyMedia(readProbe({ streams: [{ codec_type: "video", width: 10, height: 10 }] }), "video"),
    "media_corrupt",
  );
  assert.equal(classifyMedia(readProbe({ streams: [{ codec_type: "video", width: 10, height: 10 }] }), "photo"), null);
});
