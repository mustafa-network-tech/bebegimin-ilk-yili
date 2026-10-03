// Static pages of the offline archive (pure). Every user string goes
// through esc(); user text never reaches a script, style or URL context.

export type Person = {
  user_id?: string;
  name?: string | null;
  relation?: string | null;
  relation_label?: string | null;
};

export type Snapshot = {
  schema_version: number;
  baby: {
    id: string;
    first_name: string;
    last_name?: string | null;
    birth_date: string;
    birth_time?: string | null;
    birth_place?: string | null;
    birth_weight_grams?: number | null;
    birth_length_cm?: number | null;
    story?: string | null;
    avatar_path?: string | null;
    cover_path?: string | null;
  };
  lifecycle?: { effective_close_date?: string };
  members: Person[];
  milestones: {
    id: string;
    title?: string | null;
    emoji?: string | null;
    achieved_on: string;
    description?: string | null;
    author?: Person | null;
  }[];
  memories: { id: string; title: string; body?: string | null; memory_date: string; author?: Person | null }[];
  letters: { id: string; title?: string | null; body: string; written_on: string; author?: Person | null }[];
  media: {
    id: string;
    kind: "photo" | "video";
    storage_path: string;
    caption?: string | null;
    taken_on: string;
    memory_id?: string | null;
    milestone_id?: string | null;
    letter_id?: string | null;
  }[];
  comments: {
    id: string;
    memory_id?: string | null;
    milestone_id?: string | null;
    media_id?: string | null;
    body: string;
    author?: Person | null;
  }[];
};

/** What the media step produced for each media id. */
export type MediaOutput =
  | { kind: "photo"; full: string; thumb: string }
  | { kind: "video"; file: string; poster: string | null }
  | { kind: "skipped"; reason: string };

export const CSP = "default-src 'none'; img-src 'self' file: data:; media-src 'self' file:; " +
  "style-src 'self' file:; script-src 'self' file:; font-src 'self' file:; base-uri 'none'; form-action 'none'";

export function esc(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Escaped paragraphs: blank lines split paragraphs, single newlines break lines. */
export function paragraphs(text: string | null | undefined): string {
  const t = (text ?? "").replace(/\r\n?/g, "\n").trim();
  if (!t) return "";
  return t.split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`).join("");
}

const MONTHS = [
  "Ocak",
  "Şubat",
  "Mart",
  "Nisan",
  "Mayıs",
  "Haziran",
  "Temmuz",
  "Ağustos",
  "Eylül",
  "Ekim",
  "Kasım",
  "Aralık",
];

type Ymd = { y: number; m: number; d: number };
const parse = (s: string): Ymd => ({ y: +s.slice(0, 4), m: +s.slice(5, 7), d: +s.slice(8, 10) });
const key = (x: Ymd) => x.y * 10000 + x.m * 100 + x.d;
const daysIn = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();

export function dateTr(s: string): string {
  const x = parse(s);
  return `${x.d} ${MONTHS[x.m - 1]} ${x.y}`;
}

function addMonths(x: Ymd, n: number): Ymd {
  const total = x.y * 12 + (x.m - 1) + n;
  const y = Math.floor(total / 12);
  const m = (total % 12) + 1;
  return { y, m, d: Math.min(x.d, daysIn(y, m)) };
}

function minusDay(x: Ymd): Ymd {
  if (x.d > 1) return { ...x, d: x.d - 1 };
  const p = addMonths({ ...x, d: 1 }, -1);
  return { ...p, d: daysIn(p.y, p.m) };
}

const fmt = (x: Ymd) => `${x.d} ${MONTHS[x.m - 1]} ${x.y}`;

/** Same chapters as the film: 0 before birth, 1 birth day, 2..13 month 1..12, 14 first birthday and later. */
export function chapterOf(birth: string, date: string): number {
  const b = parse(birth);
  const d = parse(date);
  if (key(d) < key(b)) return 0;
  if (key(d) === key(b)) return 1;
  if (key(d) >= key(addMonths(b, 12))) return 14;
  let months = (d.y - b.y) * 12 + (d.m - b.m);
  if (d.d < b.d) months -= 1;
  return 2 + months;
}

export function chapterTitle(c: number): string {
  if (c === 0) return "Seni beklerken";
  if (c === 1) return "Doğduğun gün";
  if (c === 14) return "Bir yaşında";
  return `${c - 1}. Ay`;
}

export function chapterSubtitle(birth: string, c: number): string {
  const b = parse(birth);
  if (c === 1) return fmt(b);
  if (c >= 2 && c <= 13) return `${fmt(addMonths(b, c - 2))} – ${fmt(minusDay(addMonths(b, c - 1)))}`;
  if (c === 14) return `${fmt(addMonths(b, 12))} ve sonrası`;
  return "";
}

export const chapterFile = (c: number) => `bolum-${String(c).padStart(2, "0")}.html`;

const POSSESSIVE: Record<string, string> = {
  anne: "Annesi",
  baba: "Babası",
  abla: "Ablası",
  abi: "Abisi",
  teyze: "Teyzesi",
  hala: "Halası",
  dayi: "Dayısı",
  amca: "Amcası",
  anneanne: "Anneannesi",
  babaanne: "Babaannesi",
  dede: "Dedesi",
};

/**
 * "Esra Teyzesi" – how a person is named in the official outputs (decision
 * P-11). The relation word is the custom label if set, else the possessive
 * of a known relation. Same rule and test vectors as outputPersonName()
 * (book, app) and output_person_name() (film, SQL).
 */
export function personLabel(p: Person | null | undefined): string {
  if (!p) return "";
  const name = (p.name ?? "").trim();
  const rel = p.relation_label?.trim() || (p.relation && POSSESSIVE[p.relation]) || "";
  if (!name) return rel || "Bir yakını";
  return rel ? `${name} ${rel}` : name;
}

function layout(title: string, babyName: string, body: string): string {
  return `<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="${CSP}">
<meta name="referrer" content="no-referrer">
<title>${esc(title)} · ${esc(babyName)}</title>
<link rel="stylesheet" href="assets/app.css">
</head>
<body>
<header class="top"><a class="home" href="index.html">${esc(babyName)}</a>
<nav><a href="index.html">İçindekiler</a><a href="ilkler.html">İlkler</a><a href="mektuplar.html">Mektuplar</a><a href="aile.html">Aile</a></nav></header>
<main>
${body}
</main>
<footer>Bu sayfa, ${
    esc(babyName)
  } için hazırlanan İlk Yıl Arşivi'nin mühürlenmiş, değiştirilemez çevrimdışı kopyasıdır. İnternet bağlantısı gerekmez.</footer>
<script src="assets/app.js"></script>
</body>
</html>
`;
}

function mediaFigure(media: Snapshot["media"][number], out: MediaOutput | undefined): string {
  const caption = [media.caption?.trim(), dateTr(media.taken_on)].filter(Boolean).map(esc).join(" · ");
  if (!out || out.kind === "skipped") {
    return `<figure class="missing"><div>Bu ${
      media.kind === "video" ? "video" : "fotoğraf"
    } pakete eklenemedi.</div><figcaption>${caption}</figcaption></figure>`;
  }
  if (out.kind === "photo") {
    return `<figure class="ph"><a class="lb" href="${out.full}"><img src="${out.thumb}" alt="${
      esc(media.caption?.trim() || "Fotoğraf")
    }" loading="lazy"></a><figcaption>${caption}</figcaption></figure>`;
  }
  const poster = out.poster ? ` poster="${out.poster}"` : "";
  return `<figure class="vd"><video controls preload="metadata" playsinline${poster} src="${out.file}"></video><figcaption>${caption}</figcaption></figure>`;
}

function commentsBlock(list: Snapshot["comments"]): string {
  if (!list.length) return "";
  return `<section class="comments"><h4>Yorumlar</h4>${
    list.map((c) => `<div class="comment"><strong>${esc(personLabel(c.author))}</strong>${paragraphs(c.body)}</div>`)
      .join("")
  }</section>`;
}

export type SiteStats = { memories: number; photos: number; videos: number; milestones: number; letters: number };

/** All pages (path → HTML). Media paths come from `media` outputs only. */
export function buildPages(
  s: Snapshot,
  media: Map<string, MediaOutput>,
  coverFile: string | null,
): Map<string, string> {
  const pages = new Map<string, string>();
  const baby = s.baby;
  const name = [baby.first_name, baby.last_name].filter((x) => x && x.trim()).join(" ");
  const birth = baby.birth_date;
  const commentsFor = (k: "memory_id" | "milestone_id" | "media_id", id: string) =>
    s.comments.filter((c) => c[k] === id);
  const fig = (m: Snapshot["media"][number]) => mediaFigure(m, media.get(m.id));

  type Item = { date: string; order: number; id: string; html: string };
  const chapters = new Map<number, Item[]>();
  const push = (date: string, order: number, id: string, html: string) => {
    const c = chapterOf(birth, date);
    if (!chapters.has(c)) chapters.set(c, []);
    chapters.get(c)!.push({ date, order, id, html });
  };

  for (const m of s.memories) {
    const attached = s.media.filter((x) => x.memory_id === m.id);
    push(
      m.memory_date,
      1,
      m.id,
      `<article class="card memory"><h3>${esc(m.title)}</h3><p class="meta">${esc(dateTr(m.memory_date))}${
        m.author ? " · " + esc(personLabel(m.author)) : ""
      }</p>${paragraphs(m.body)}${attached.length ? `<div class="grid">${attached.map(fig).join("")}</div>` : ""}${
        commentsBlock(commentsFor("memory_id", m.id))
      }</article>`,
    );
  }
  const milestoneCard = (ms: Snapshot["milestones"][number]) => {
    const attached = s.media.filter((x) => x.milestone_id === ms.id);
    return `<article class="card milestone"><h3>${
      esc([ms.emoji, ms.title || "İlk"].filter(Boolean).join(" "))
    }</h3><p class="meta">${esc(dateTr(ms.achieved_on))}</p>${paragraphs(ms.description)}${
      attached.length ? `<div class="grid">${attached.map(fig).join("")}</div>` : ""
    }${commentsBlock(commentsFor("milestone_id", ms.id))}</article>`;
  };
  for (const ms of s.milestones) push(ms.achieved_on, 2, ms.id, milestoneCard(ms));
  const loose = s.media.filter((x) => !x.memory_id && !x.milestone_id && !x.letter_id);
  for (const m of loose) {
    push(m.taken_on, 3, m.id, `<div class="loose">${fig(m)}${commentsBlock(commentsFor("media_id", m.id))}</div>`);
  }

  const order = [...chapters.keys()].sort((a, b) => a - b);
  order.forEach((c, i) => {
    const items = chapters.get(c)!.sort((a, b) =>
      a.date.localeCompare(b.date) || a.order - b.order || a.id.localeCompare(b.id)
    );
    const prev = i > 0
      ? `<a href="${chapterFile(order[i - 1])}">← ${esc(chapterTitle(order[i - 1]))}</a>`
      : "<span></span>";
    const next = i < order.length - 1
      ? `<a href="${chapterFile(order[i + 1])}">${esc(chapterTitle(order[i + 1]))} →</a>`
      : "<span></span>";
    const sub = chapterSubtitle(birth, c);
    pages.set(
      chapterFile(c),
      layout(
        chapterTitle(c),
        name,
        `<h1>${esc(chapterTitle(c))}</h1>${sub ? `<p class="sub">${esc(sub)}</p>` : ""}<div class="stream">${
          items.map((x) => x.html).join("\n")
        }</div><nav class="pager">${prev}${next}</nav>`,
      ),
    );
  });

  const milestones = [...s.milestones].sort((a, b) =>
    a.achieved_on.localeCompare(b.achieved_on) || a.id.localeCompare(b.id)
  );
  pages.set(
    "ilkler.html",
    layout(
      "İlkler",
      name,
      `<h1>İlkler</h1><div class="stream">${
        milestones.map(milestoneCard).join("\n") || "<p>Kayıtlı ilk yok.</p>"
      }</div>`,
    ),
  );

  const letters = [...s.letters].sort((a, b) => a.written_on.localeCompare(b.written_on) || a.id.localeCompare(b.id));
  pages.set(
    "mektuplar.html",
    layout(
      "Ailemden sana",
      name,
      `<h1>Ailemden sana</h1><div class="stream">${
        letters.map((l) => {
          const attached = s.media.filter((x) => x.letter_id === l.id);
          return `<article class="card letter"><h3>${esc(l.title?.trim() || "Sana bir mektup")}</h3><p class="meta">${
            esc(dateTr(l.written_on))
          }</p>${paragraphs(l.body)}<p class="sign">${esc(personLabel(l.author))}</p>${
            attached.length ? `<div class="grid">${attached.map(fig).join("")}</div>` : ""
          }</article>`;
        }).join("\n") || "<p>Kayıtlı mektup yok.</p>"
      }</div>`,
    ),
  );

  pages.set(
    "aile.html",
    layout(
      "Aile",
      name,
      `<h1>Aile</h1><ul class="family">${
        s.members.map((m) => `<li>${esc(personLabel(m))}</li>`).join("") || "<li>Kayıtlı aile üyesi yok.</li>"
      }</ul>`,
    ),
  );

  const stats: SiteStats = {
    memories: s.memories.length,
    photos: s.media.filter((m) => m.kind === "photo").length,
    videos: s.media.filter((m) => m.kind === "video").length,
    milestones: s.milestones.length,
    letters: s.letters.length,
  };
  const facts = [
    ["Doğum", dateTr(birth) + (baby.birth_time ? ` · ${baby.birth_time.slice(0, 5)}` : "")],
    ["Yer", baby.birth_place],
    ["Kilo", baby.birth_weight_grams ? `${(baby.birth_weight_grams / 1000).toFixed(2).replace(".", ",")} kg` : null],
    ["Boy", baby.birth_length_cm ? `${String(baby.birth_length_cm).replace(".", ",")} cm` : null],
  ].filter(([, v]) => v);
  const closed = s.lifecycle?.effective_close_date ? dateTr(s.lifecycle.effective_close_date) : null;
  pages.set(
    "index.html",
    layout(
      "İlk Yıl Arşivi",
      name,
      `<section class="hero">${coverFile ? `<img class="cover" src="${coverFile}" alt="${esc(name)}">` : ""}<div><h1>${
        esc(name)
      }</h1><p class="sub">İlk Yıl Arşivi${
        closed ? ` · ${esc(closed)} tarihinde mühürlendi` : ""
      }</p><dl class="facts">${
        facts.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")
      }</dl></div></section>${baby.story ? `<section class="story">${paragraphs(baby.story)}</section>` : ""}
<p class="stats">${stats.memories} anı · ${stats.photos} fotoğraf · ${stats.videos} video · ${stats.milestones} ilk · ${stats.letters} mektup</p>
<h2>İçindekiler</h2><ol class="toc">${
        order.map((c) =>
          `<li><a href="${chapterFile(c)}">${esc(chapterTitle(c))}</a><span>${
            esc(chapterSubtitle(birth, c))
          }</span></li>`
        ).join("")
      }<li><a href="ilkler.html">İlkler</a></li><li><a href="mektuplar.html">Ailemden sana</a></li><li><a href="aile.html">Aile</a></li></ol>`,
    ),
  );
  return pages;
}

export const APP_CSS =
  `@font-face{font-family:Nunito;src:url("fonts/nunito-regular.ttf") format("truetype");font-weight:400}
@font-face{font-family:Nunito;src:url("fonts/nunito-bold.ttf") format("truetype");font-weight:700}
@font-face{font-family:Lora;src:url("fonts/lora-regular.ttf") format("truetype");font-weight:400}
:root{--paper:#fbf4ec;--ink:#3d2c29;--muted:#8a6f66;--card:#fffaf5;--line:#ead9cc;--accent:#c9776b}
@media (prefers-color-scheme:dark){:root{--paper:#1f1a18;--ink:#f3e9e2;--muted:#bba49a;--card:#2a2321;--line:#3d3330;--accent:#e39a8e}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);font:17px/1.6 Nunito,system-ui,sans-serif}
a{color:var(--accent)}main{max-width:980px;margin:0 auto;padding:16px}
h1,h2,h3{font-family:Lora,Georgia,serif;line-height:1.25}h1{font-size:2.1rem;margin:.6em 0 .1em}
.top{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--line);background:var(--card)}
.top .home{font-weight:700;text-decoration:none;color:var(--ink)}.top nav{display:flex;flex-wrap:wrap;gap:14px}
.sub,.meta{color:var(--muted)}.meta{margin:.1em 0 .6em;font-size:.92rem}
.hero{display:flex;flex-wrap:wrap;gap:24px;align-items:center;margin:16px 0}.cover{width:220px;height:220px;object-fit:cover;border-radius:24px}
.facts{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;margin:0}.facts dt{color:var(--muted)}.facts dd{margin:0}
.stats{font-weight:700}.toc{padding-left:1.2em}.toc li{margin:.35em 0}.toc span{color:var(--muted);margin-left:.6em;font-size:.9rem}
.stream{display:flex;flex-direction:column;gap:18px}.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:16px 18px}
.card h3{margin:.1em 0}.sign{text-align:right;font-style:italic;color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px;margin-top:10px}
figure{margin:0}figure img,figure video{width:100%;border-radius:12px;display:block;background:#0001}
figure img{aspect-ratio:1/1;object-fit:cover}figcaption{font-size:.85rem;color:var(--muted);margin-top:4px}
.loose figure{max-width:520px}.missing div{padding:28px;border:1px dashed var(--line);border-radius:12px;color:var(--muted);text-align:center}
.comments{margin-top:12px;border-top:1px solid var(--line);padding-top:8px}.comments h4{margin:.2em 0;font-size:.95rem}.comment p{margin:.2em 0}
.pager{display:flex;justify-content:space-between;margin:28px 0}.family{padding-left:1.2em}
footer{max-width:980px;margin:24px auto;padding:16px;color:var(--muted);font-size:.85rem;border-top:1px solid var(--line)}
.lightbox{position:fixed;inset:0;background:#000d;display:flex;align-items:center;justify-content:center;z-index:9}.lightbox[hidden]{display:none}
.lightbox img{max-width:96vw;max-height:94vh;object-fit:contain}
`;

/** Optional enhancement only (works without it): photo lightbox. No user data. */
export const APP_JS = `(function () {
  "use strict";
  var links = Array.prototype.slice.call(document.querySelectorAll("a.lb"));
  if (!links.length) return;
  var box = document.createElement("div");
  box.className = "lightbox";
  box.hidden = true;
  var img = document.createElement("img");
  box.appendChild(img);
  document.body.appendChild(box);
  var index = 0;
  function show(n) {
    index = (n + links.length) % links.length;
    var thumb = links[index].querySelector("img");
    img.src = links[index].getAttribute("href");
    img.alt = thumb ? thumb.alt : "";
    box.hidden = false;
  }
  links.forEach(function (a, n) {
    a.addEventListener("click", function (e) { e.preventDefault(); show(n); });
  });
  box.addEventListener("click", function () { box.hidden = true; });
  document.addEventListener("keydown", function (e) {
    if (box.hidden) return;
    if (e.key === "Escape") box.hidden = true;
    else if (e.key === "ArrowRight") show(index + 1);
    else if (e.key === "ArrowLeft") show(index - 1);
  });
})();
`;

export function readme(babyName: string): string {
  return `${babyName} - İlk Yıl Arşivi (çevrimdışı kopya)
================================================

Nasıl açılır?
1. Bu ZIP dosyasını önce bir klasöre çıkarın (sağ tık > "Tümünü ayıkla" /
   çift tıklayarak açın). ZIP'in içinden doğrudan açmayın.
2. Çıkan klasördeki index.html dosyasına çift tıklayın. Arşiv varsayılan
   tarayıcınızda (Chrome, Edge, Firefox, Safari) açılır.
3. İnternet bağlantısı gerekmez. Her şey bu klasörün içindedir.

Telefon ve tablet
- iPhone / iPad: Dosyalar uygulamasında ZIP'e dokunun, çıkan klasördeki
  index.html dosyasını açın.
- Android: Dosyalar uygulamasıyla çıkarın, index.html'i yerel dosya açabilen
  bir tarayıcıda (ör. Firefox) açın.

Güvenlik
- Bu paket yalnızca HTML, CSS, JavaScript, yazı tipi, fotoğraf ve video
  dosyaları içerir. Çalıştırılabilir program içermez; bir şey yüklemeniz
  gerekmez.
- Arşiv mühürlüdür: içine yeni anı eklenemez, mevcut içerik değiştirilemez.
- manifest.json her dosyanın SHA-256 özetini listeler; dosyaların bozulup
  bozulmadığını bununla kontrol edebilirsiniz.
`;
}
