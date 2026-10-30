// Archive paths are never derived from user text: fixed page names and
// media/<uuid>(-k|-p).ext. Every path is checked against an allow-list.

export const MIME_BY_EXT: Record<string, string> = {
  html: "text/html; charset=utf-8",
  css: "text/css; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  ttf: "font/ttf",
  jpg: "image/jpeg",
  mp4: "video/mp4",
  json: "application/json",
  txt: "text/plain; charset=utf-8",
};

const SEGMENT = /^[a-z0-9][a-z0-9._-]{0,99}$/;

/** Relative, lower-case ASCII, no traversal, allowed extension only. */
export function assertSafeArchivePath(path: string, allowRoot = false): void {
  const parts = path.split("/");
  if (path.startsWith("/") || path.includes("\\") || parts.length > (allowRoot ? 4 : 3)) {
    throw new Error(`unsafe archive path: ${path}`);
  }
  for (const part of parts) {
    if (!SEGMENT.test(part) || part.includes("..")) throw new Error(`unsafe archive path: ${path}`);
  }
  const ext = parts[parts.length - 1].split(".").pop() ?? "";
  if (!(ext in MIME_BY_EXT)) throw new Error(`file type not allowed in archive: ${path}`);
}

export function mimeOf(path: string): string {
  return MIME_BY_EXT[path.split(".").pop() ?? ""] ?? "application/octet-stream";
}

const TR: Record<string, string> = { ç: "c", ğ: "g", ı: "i", i: "i", ö: "o", ş: "s", ü: "u", â: "a", î: "i", û: "u" };

/** "Çağla Nur" → "cagla-nur" (root folder name). */
export function slug(text: string): string {
  const s = text.toLocaleLowerCase("tr-TR").split("").map((c) => TR[c] ?? c).join("")
    .normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
  return s || "bebek";
}
