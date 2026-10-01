// Pure helpers of the book-artifact-finalize function (unit-tested).

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const MAX_BOOK_PAGES = 5000;

export type FinalizeRequest = { artifactId: string; pageCount: number };

/** Validates the app's request body; null when it is malformed. */
export function parseFinalizeRequest(body: unknown): FinalizeRequest | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  const artifactId = String(b.artifact_id ?? "");
  const pageCount = b.page_count;
  if (!UUID.test(artifactId)) return null;
  if (
    typeof pageCount !== "number" || !Number.isInteger(pageCount) ||
    pageCount < 1 || pageCount > MAX_BOOK_PAGES
  ) {
    return null;
  }
  return { artifactId, pageCount };
}

const PDF_HEADER = [0x25, 0x50, 0x44, 0x46, 0x2d]; // "%PDF-"
const PDF_EOF = [0x25, 0x25, 0x45, 0x4f, 0x46]; // "%%EOF"

/** Header at the start and an end-of-file marker in the last kilobyte. */
export function looksLikePdf(bytes: Uint8Array): boolean {
  if (bytes.length < 64) return false;
  for (let i = 0; i < PDF_HEADER.length; i++) {
    if (bytes[i] !== PDF_HEADER[i]) return false;
  }
  const from = Math.max(0, bytes.length - 1024);
  outer: for (let i = bytes.length - PDF_EOF.length; i >= from; i--) {
    for (let k = 0; k < PDF_EOF.length; k++) {
      if (bytes[i + k] !== PDF_EOF[k]) continue outer;
    }
    return true;
  }
  return false;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(
    new Uint8Array(digest),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}

/** The lease owner a parent's app renders as (see book_client_worker()). */
export function bookClientWorker(userId: string): string {
  return `book-client:${userId}`;
}
