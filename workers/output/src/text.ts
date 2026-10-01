// Text for drawtext. The bundled fonts have no emoji; drawtext reads the
// text from files (expansion=none), so no filter escaping is needed.

const EMOJI =
  /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]/gu;
// Control characters are exactly what this pattern removes.
// deno-lint-ignore no-control-regex
const CONTROL = /[\u0000-\u0008\u000B-\u001F\u007F]/g;

export function sanitizeText(input: string | null | undefined): string {
  return (input ?? "")
    .replace(EMOJI, "")
    .replace(CONTROL, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .trim();
}

/** Greedy word wrap; long words are split, extra lines end with "…". */
export function wrapText(input: string, maxChars: number, maxLines: number): string[] {
  const lines: string[] = [];
  for (const paragraph of sanitizeText(input).split("\n")) {
    let line = "";
    for (const raw of paragraph.split(" ")) {
      let word = raw;
      while (word.length > maxChars) {
        if (line) {
          lines.push(line);
          line = "";
        }
        lines.push(word.slice(0, maxChars));
        word = word.slice(maxChars);
      }
      if (!word) continue;
      if (!line) line = word;
      else if (line.length + 1 + word.length <= maxChars) line += " " + word;
      else {
        lines.push(line);
        line = word;
      }
    }
    if (line) lines.push(line);
  }
  if (lines.length <= maxLines) return lines;
  const kept = lines.slice(0, maxLines);
  const last = kept[maxLines - 1];
  kept[maxLines - 1] = (last.length >= maxChars ? last.slice(0, maxChars - 1) : last) + "…";
  return kept;
}
