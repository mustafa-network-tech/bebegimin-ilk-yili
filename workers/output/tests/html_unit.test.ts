import { test } from "node:test";
import assert from "node:assert/strict";
import { crc32Update, readZipEntries, readZipEntry, writeZip } from "../src/html/zip.ts";
import { assertSafeArchivePath, slug } from "../src/html/paths.ts";
import {
  buildPages,
  chapterOf,
  chapterSubtitle,
  CSP,
  esc,
  type MediaOutput,
  paragraphs,
  personLabel,
} from "../src/html/site.ts";
import { sampleSnapshot } from "./fixtures.ts";

const P1 = "22222222-2222-4222-8222-222222222222";
const V1 = "33333333-3333-4333-8333-333333333333";

test("zip: round trip with CRC-32, UTF-8 names, fixed order", async () => {
  assert.equal(crc32Update(0, new TextEncoder().encode("abc")), 0x352441c2);
  const dir = await Deno.makeTempDir();
  try {
    const src = `${dir}/big.bin`;
    const big = new Uint8Array(3 * 1024 * 1024).map((_, i) => i % 251);
    await Deno.writeFile(src, big);
    const zip = `${dir}/a.zip`;
    await writeZip(zip, [
      { path: "root/manifest.json", bytes: new TextEncoder().encode("{}") },
      { path: "root/media/x.jpg", file: src },
    ]);
    const entries = await readZipEntries(zip);
    assert.deepEqual(entries.map((e) => e.path), ["root/manifest.json", "root/media/x.jpg"]);
    let got = 0;
    let crc = 0;
    await readZipEntry(zip, entries[1], (c) => {
      got += c.length;
      crc = crc32Update(crc, c);
    });
    assert.equal(got, big.length);
    assert.equal(crc, entries[1].crc);
    // Deterministic: same input, same bytes.
    const again = `${dir}/b.zip`;
    await writeZip(again, [
      { path: "root/manifest.json", bytes: new TextEncoder().encode("{}") },
      { path: "root/media/x.jpg", file: src },
    ]);
    assert.deepEqual(await Deno.readFile(zip), await Deno.readFile(again));
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

test("paths: traversal, absolute paths, upper case and executables are refused", async () => {
  for (
    const bad of [
      "../x.html",
      "a/../../x.html",
      "/etc/passwd.txt",
      "a\\b.html",
      "Index.html",
      "run.exe",
      "x.sh",
      "a/b/c/d.html",
      "media/.hidden.jpg",
      "x.svg",
    ]
  ) {
    assert.throws(() => assertSafeArchivePath(bad), bad);
  }
  for (const ok of ["index.html", "media/abc-k.jpg", "assets/fonts/nunito-regular.ttf", "manifest.json"]) {
    assertSafeArchivePath(ok);
  }
  const dir = await Deno.makeTempDir();
  try {
    await assert.rejects(writeZip(`${dir}/x.zip`, [{ path: "root/../evil.html", bytes: new Uint8Array(1) }]));
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
  assert.equal(slug("Çağla Nur İşçi"), "cagla-nur-isci");
  assert.equal(slug("✨"), "bebek");
});

test("text: user content is escaped, never executable", () => {
  assert.equal(esc(`<a href="x" onclick='y'>&`), "&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;");
  assert.equal(paragraphs("a\nb\n\n<c>"), "<p>a<br>b</p><p>&lt;c&gt;</p>");
});

test("chapters match the film (leap-day birthday included)", () => {
  assert.equal(chapterOf("2024-02-29", "2024-02-28"), 0);
  assert.equal(chapterOf("2024-02-29", "2024-02-29"), 1);
  assert.equal(chapterOf("2024-02-29", "2024-03-28"), 2);
  assert.equal(chapterOf("2024-02-29", "2024-03-29"), 3);
  assert.equal(chapterOf("2024-02-29", "2025-02-27"), 13);
  assert.equal(chapterOf("2024-02-29", "2025-02-28"), 14);
  assert.equal(chapterSubtitle("2024-01-31", 3), "29 Şubat 2024 – 30 Mart 2024");
});

test("pages: escaped content, CSP, relative links only, no editing surface", () => {
  const media = new Map<string, MediaOutput>([
    [P1, { kind: "photo", full: `media/${P1}.jpg`, thumb: `media/${P1}-k.jpg` }],
    [V1, { kind: "skipped", reason: "transcode_failed" }],
  ]);
  const pages = buildPages(sampleSnapshot(), media, null);
  assert.deepEqual(
    [...pages.keys()].sort(),
    ["aile.html", "bolum-02.html", "bolum-03.html", "ilkler.html", "index.html", "mektuplar.html", "bolum-12.html"]
      .sort(),
  );
  const all = [...pages.values()].join("\n");
  assert.ok(!all.includes("<script>alert"), "script tag escaped");
  assert.ok(all.includes("&lt;script&gt;alert(1)&lt;/script&gt; İlk gün"));
  assert.ok(!all.includes("<img src=x"), "attribute injection escaped");
  assert.ok(all.includes("Uykucu &lt;b&gt;"));
  // Decision P-11: "Name + relation".
  assert.ok(all.includes("Ayşe Annesi") && all.includes("Zeynep Teyzesi") && all.includes("Komşu"));
  assert.ok(all.includes("Bu video pakete eklenemedi."));
  for (const [name, html] of pages) {
    assert.ok(html.includes(`content="${CSP}"`), `${name} has CSP`);
    assert.ok(!/(src|href|poster)="(https?:|\/\/|\/)/i.test(html), `${name} links stay relative`);
    assert.ok(!/<(form|input|textarea|iframe|button)\b/i.test(html), `${name} has no editing surface`);
    assert.equal((html.match(/<script\b/g) ?? []).length, 1, `${name} loads only app.js`);
  }
});

test("people are named Name + relation (same vectors as the book and the film)", () => {
  assert.equal(personLabel({ name: "Esra", relation: "teyze" }), "Esra Teyzesi");
  assert.equal(personLabel({ name: "Ahmet", relation: "amca" }), "Ahmet Amcası");
  assert.equal(personLabel({ name: "Elif", relation: "anne" }), "Elif Annesi");
  assert.equal(
    personLabel({ name: "Deniz", relation: "diger", relation_label: "Vaftiz annesi" }),
    "Deniz Vaftiz annesi",
  );
  assert.equal(personLabel({ name: "Deniz", relation: "diger" }), "Deniz");
  assert.equal(personLabel({ name: "  ", relation: "teyze" }), "Teyzesi");
});
