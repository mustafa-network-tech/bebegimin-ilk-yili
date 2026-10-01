/// <reference lib="dom" />
// Builds a real archive with ffmpeg; with CHROME_PATH also opens it in
// headless Chrome with the network offline and records every request.
//   FFMPEG_PATH=... FFPROBE_PATH=... CHROME_PATH=... deno task test
import { test } from "node:test";
import assert from "node:assert/strict";
import puppeteer from "puppeteer-core";
import { buildArchive, verifyArchive } from "../src/html/build.ts";
import { readZipEntries, readZipEntry } from "../src/html/zip.ts";
import { denoRunner } from "../src/render.ts";
import { sampleSnapshot } from "./fixtures.ts";

const ffmpeg = Deno.env.get("FFMPEG_PATH");
const ffprobe = Deno.env.get("FFPROBE_PATH");
const chrome = Deno.env.get("CHROME_PATH");
const root = new URL("../../../", import.meta.url);
const repo = (rel: string) => decodeURIComponent(new URL(rel, root).pathname).replace(/^\/([A-Za-z]:)/, "$1");

const BABY = "11111111-1111-4111-8111-111111111111";
const P1 = "22222222-2222-4222-8222-222222222222";
const V1 = "33333333-3333-4333-8333-333333333333";
const P2 = "44444444-4444-4444-8444-444444444444";
const BROKEN = "55555555-5555-4555-8555-555555555555";
const GONE = "66666666-6666-4666-8666-666666666666";

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

test("offline archive: real media, manifest-verified ZIP, opens offline in Chrome without remote requests", {
  skip: !ffmpeg || !ffprobe ? "FFMPEG_PATH / FFPROBE_PATH not set" : false,
}, async () => {
  const work = await Deno.makeTempDir({ prefix: "html-it-" });
  try {
    // Sources: portrait photo (with EXIF from the fixture), landscape photo,
    // a portrait video with sound, a corrupt file, a missing object.
    const store = new Map<string, Uint8Array>();
    store.set(`${BABY}/${P1}/p.jpg`, await Deno.readFile(repo("test/fixtures/portrait.jpg")));
    store.set(`${BABY}/${P2}/p.jpg`, await Deno.readFile(repo("test/fixtures/landscape.jpg")));
    store.set(`${BABY}/${BROKEN}/v.mp4`, new TextEncoder().encode("definitely not a video"));
    const gen = await denoRunner(ffmpeg!, [
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "lavfi",
      "-i",
      "testsrc2=s=720x1280:r=30:d=2",
      "-f",
      "lavfi",
      "-i",
      "sine=f=440:d=2",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-shortest",
      "-y",
      "gen.mp4",
    ], work);
    assert.equal(gen.code, 0, gen.stderr);
    store.set(`${BABY}/${V1}/v.mp4`, await Deno.readFile(`${work}/gen.mp4`));
    store.set(`${BABY}/profile/cover.jpg`, await Deno.readFile(repo("test/fixtures/landscape.jpg")));

    const snap = sampleSnapshot();
    snap.baby.cover_path = `${BABY}/profile/cover.jpg`;
    snap.media.push(
      { id: P2, kind: "photo", storage_path: `${BABY}/${P2}/p.jpg`, caption: "Deniz kenarı", taken_on: "2024-08-15" },
      { id: BROKEN, kind: "video", storage_path: `${BABY}/${BROKEN}/v.mp4`, caption: null, taken_on: "2024-09-01" },
      { id: GONE, kind: "photo", storage_path: `${BABY}/${GONE}/p.jpg`, caption: null, taken_on: "2024-09-02" },
    );
    const text = JSON.stringify(snap);
    const checksum = await sha256Hex(new TextEncoder().encode(text));
    const buildDir = `${work}/build`;
    await Deno.mkdir(buildDir);
    const progress: number[] = [];
    const result = await buildArchive(text, checksum, {
      ffmpeg: ffmpeg!,
      ffprobe: ffprobe!,
      workDir: buildDir,
      fontDir: repo("assets/fonts"),
      snapshotId: "77777777-7777-4777-8777-777777777777",
      fetchMedia: (path) => Promise.resolve(store.get(path) ?? null),
      onProgress: (p) => void progress.push(p),
    });
    await assert.rejects(
      buildArchive(text.replace("Çağla", "Ceren"), checksum, {
        ffmpeg: ffmpeg!,
        ffprobe: ffprobe!,
        workDir: buildDir,
        fontDir: repo("assets/fonts"),
        snapshotId: "x",
        fetchMedia: () => Promise.resolve(null),
      }),
      /checksum/,
    );

    assert.equal(result.root, "cagla-ilk-yil-arsivi");
    assert.deepEqual(result.skipped.map((s) => `${s.media_id}:${s.reason}`).sort(), [
      `${BROKEN}:media_corrupt`,
      `${GONE}:media_missing`,
    ]);
    assert.ok(progress.at(-1)! >= 90);

    // ZIP ↔ manifest, byte for byte.
    const entries = await readZipEntries(result.zipFile);
    const files = new Map<string, Uint8Array>();
    for (const e of entries) {
      const parts: Uint8Array[] = [];
      await readZipEntry(result.zipFile, e, (c) => void parts.push(c));
      const all = new Uint8Array(e.size);
      let o = 0;
      for (const p of parts) {
        all.set(p, o);
        o += p.length;
      }
      files.set(e.path.slice(result.root.length + 1), all);
    }
    const manifestBytes = files.get("manifest.json")!;
    const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
    assert.equal(manifest.entry_count + 1, entries.length);
    assert.equal(result.entryCount, entries.length);
    assert.equal(await sha256Hex(manifestBytes), result.manifestSha256);
    await verifyArchive(result.zipFile, result.root, manifestBytes);
    for (
      const required of [
        "index.html",
        "benioku.txt",
        "surum.txt",
        "assets/app.css",
        "assets/app.js",
        `media/${P1}.jpg`,
        `media/${P1}-k.jpg`,
        `media/${V1}.mp4`,
        "media/kapak.jpg",
      ]
    ) {
      assert.ok(files.has(required), required);
    }
    assert.ok(new TextDecoder().decode(files.get("surum.txt")).includes("77777777-7777-4777-8777-777777777777"));

    // No remote reference anywhere in text entries; media metadata stripped.
    for (const [path, bytes] of files) {
      if (!/\.(html|css|js)$/.test(path)) continue;
      const t = new TextDecoder().decode(bytes);
      assert.ok(!/(https?:)?\/\/[a-z0-9]/i.test(t.replace(/<!doctype html>/i, "")), `${path} has no remote reference`);
    }
    const photo = new TextDecoder("latin1").decode(files.get(`media/${P1}.jpg`)!);
    assert.ok(!photo.includes("Exif\0\0"), "EXIF removed from photos");

    if (!chrome) return;
    // Extract and open from disk, network offline.
    const site = `${work}/site`;
    for (const [path, bytes] of files) {
      const full = `${site}/${path}`;
      await Deno.mkdir(full.slice(0, full.lastIndexOf("/")), { recursive: true });
      await Deno.writeFile(full, bytes);
    }
    const url = (p: string) => "file:///" + `${site}/${p}`.replace(/\\/g, "/").replace(/^\/+/, "");
    const browser = await puppeteer.launch({
      executablePath: chrome,
      headless: true,
      args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required"],
    });
    try {
      const page = await browser.newPage();
      await page.setOfflineMode(true);
      const requests: string[] = [];
      const problems: string[] = [];
      let dialogs = 0;
      page.on("request", (r) => requests.push(r.url()));
      // A media request cancelled by navigating away is not a load failure.
      page.on("requestfailed", (r) => {
        const reason = r.failure()?.errorText ?? "";
        if (reason !== "net::ERR_ABORTED") problems.push(`failed ${r.url()} ${reason}`);
      });
      page.on("console", (m) => m.type() === "error" && problems.push(m.text()));
      page.on("pageerror", (e) => problems.push(String(e)));
      page.on("dialog", (d) => {
        dialogs++;
        void d.dismiss();
      });

      await page.goto(url("index.html"), { waitUntil: "load" });
      assert.match(await page.title(), /İlk Yıl Arşivi · Çağla Öz/);
      assert.deepEqual(
        await page.$$eval("ol.toc a", (a) => a.map((x) => x.getAttribute("href"))),
        [
          "bolum-02.html",
          "bolum-03.html",
          "bolum-07.html",
          "bolum-08.html",
          "bolum-12.html",
          "ilkler.html",
          "mektuplar.html",
          "aile.html",
        ],
      );

      await page.goto(url("bolum-02.html"), { waitUntil: "load" });
      const memoryTitle = await page.$eval("article.memory h3", (h) => h.textContent);
      assert.equal(memoryTitle, "<script>alert(1)</script> İlk gün", "user text shown literally");
      assert.equal(await page.$$eval("script", (s) => s.length), 1);
      // Page images (the lightbox <img> has no src until it is opened).
      await page.waitForFunction(
        () =>
          Array.from(document.images).filter((i) => i.getAttribute("src")).every((i) =>
            i.complete && i.naturalWidth > 0
          ),
        { timeout: 10_000 },
      );
      await page.click("a.lb");
      assert.equal(await page.$eval(".lightbox", (b) => (b as HTMLElement).hidden), false, "lightbox opens offline");

      await page.goto(url("bolum-03.html"), { waitUntil: "load" });
      await page.waitForFunction(() => {
        const v = document.querySelector("video");
        return !!v && v.readyState >= 1 && v.videoWidth > 0;
      }, { timeout: 15_000 });
      const playing = await page.evaluate(async () => {
        const v = document.querySelector("video")!;
        v.muted = true;
        await v.play();
        await new Promise((r) => setTimeout(r, 600));
        return v.currentTime > 0;
      });
      assert.ok(playing, "video plays offline");

      await page.goto(url("mektuplar.html"), { waitUntil: "load" });
      assert.ok((await page.$eval("main", (m) => m.textContent ?? "")).includes('Canım "kızım" & sevgim'));

      const shots = Deno.env.get("ARCHIVE_SCREENSHOT_DIR");
      if (shots) {
        await page.setViewport({ width: 1100, height: 900 });
        for (const p of ["index.html", "bolum-02.html", "bolum-03.html", "mektuplar.html"]) {
          await page.goto(url(p), { waitUntil: "load" });
          await page.screenshot({ path: `${shots}/${p.replace(".html", "")}.png` as `${string}.png` });
        }
      }

      assert.equal(dialogs, 0, "no script injection");
      assert.deepEqual(
        requests.filter((u) => !u.startsWith("file:") && !u.startsWith("data:")),
        [],
        "no remote requests",
      );
      assert.deepEqual(problems, []);
    } finally {
      await browser.close();
    }
  } finally {
    await Deno.remove(work, { recursive: true }).catch(() => {});
  }
});
