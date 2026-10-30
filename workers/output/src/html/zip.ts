// Minimal deterministic ZIP (STORE only): fixed 1980-01-01 timestamps,
// UTF-8 names, CRC-32, entries < 4 GB, < 65 535 entries. Large files are
// streamed from disk; nothing is compressed (media is already compressed).

import { assertSafeArchivePath } from "./paths.ts";

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32Update(crc: number, bytes: Uint8Array): number {
  let c = crc ^ 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

const DOS_TIME = 0;
const DOS_DATE = (0 << 9) | (1 << 5) | 1; // 1980-01-01
const UTF8_FLAG = 0x0800;
const MAX_U32 = 0xffffffff;

type Entry = { name: Uint8Array; crc: number; size: number; offset: number };

export type ZipSource = { path: string; bytes: Uint8Array } | { path: string; file: string };

async function* chunks(source: ZipSource): AsyncGenerator<Uint8Array> {
  if ("bytes" in source) {
    yield source.bytes;
    return;
  }
  // The readable stream closes the file when it is fully consumed.
  const f = await Deno.open(source.file, { read: true });
  for await (const chunk of f.readable) yield chunk;
}

/** Writes all sources (in the given order) to `output`. */
export async function writeZip(output: string, sources: ZipSource[]): Promise<void> {
  if (sources.length >= 0xffff) throw new Error("too many entries");
  const out = await Deno.open(output, { write: true, create: true, truncate: true });
  const enc = new TextEncoder();
  const entries: Entry[] = [];
  let offset = 0;
  const write = async (bytes: Uint8Array) => {
    let done = 0;
    while (done < bytes.length) done += await out.write(bytes.subarray(done));
    offset += bytes.length;
  };
  try {
    const seen = new Set<string>();
    for (const source of sources) {
      assertSafeArchivePath(source.path, true);
      if (seen.has(source.path)) throw new Error(`duplicate entry ${source.path}`);
      seen.add(source.path);
      // Pass 1: CRC and size (streamed).
      let crc = 0;
      let size = 0;
      for await (const c of chunks(source)) {
        crc = crc32Update(crc, c);
        size += c.length;
      }
      if (size >= MAX_U32 || offset >= MAX_U32) throw new Error("entry too large for ZIP32");
      const name = enc.encode(source.path);
      const header = new DataView(new ArrayBuffer(30));
      header.setUint32(0, 0x04034b50, true);
      header.setUint16(4, 20, true);
      header.setUint16(6, UTF8_FLAG, true);
      header.setUint16(8, 0, true);
      header.setUint16(10, DOS_TIME, true);
      header.setUint16(12, DOS_DATE, true);
      header.setUint32(14, crc, true);
      header.setUint32(18, size, true);
      header.setUint32(22, size, true);
      header.setUint16(26, name.length, true);
      header.setUint16(28, 0, true);
      entries.push({ name, crc, size, offset });
      await write(new Uint8Array(header.buffer));
      await write(name);
      // Pass 2: data.
      for await (const c of chunks(source)) await write(c);
    }
    const cdStart = offset;
    for (const e of entries) {
      const h = new DataView(new ArrayBuffer(46));
      h.setUint32(0, 0x02014b50, true);
      h.setUint16(4, 20, true);
      h.setUint16(6, 20, true);
      h.setUint16(8, UTF8_FLAG, true);
      h.setUint16(10, 0, true);
      h.setUint16(12, DOS_TIME, true);
      h.setUint16(14, DOS_DATE, true);
      h.setUint32(16, e.crc, true);
      h.setUint32(20, e.size, true);
      h.setUint32(24, e.size, true);
      h.setUint16(28, e.name.length, true);
      h.setUint16(30, 0, true);
      h.setUint16(32, 0, true);
      h.setUint16(34, 0, true);
      h.setUint16(36, 0, true);
      h.setUint32(38, 0, true);
      h.setUint32(42, e.offset, true);
      await write(new Uint8Array(h.buffer));
      await write(e.name);
    }
    const cdSize = offset - cdStart;
    if (offset >= MAX_U32) throw new Error("archive too large for ZIP32");
    const end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true);
    end.setUint16(8, entries.length, true);
    end.setUint16(10, entries.length, true);
    end.setUint32(12, cdSize, true);
    end.setUint32(16, cdStart, true);
    await write(new Uint8Array(end.buffer));
  } finally {
    out.close();
  }
}

export type ZipEntryInfo = { path: string; size: number; crc: number; dataOffset: number };

/** Reads the central directory of a STORE archive written by writeZip. */
export async function readZipEntries(file: string): Promise<ZipEntryInfo[]> {
  const f = await Deno.open(file, { read: true });
  try {
    const total = (await f.stat()).size;
    const readAt = async (pos: number, len: number) => {
      const buf = new Uint8Array(len);
      await f.seek(pos, Deno.SeekMode.Start);
      let done = 0;
      while (done < len) {
        const n = await f.read(buf.subarray(done));
        if (n === null) throw new Error("unexpected end of zip");
        done += n;
      }
      return buf;
    };
    const endBuf = await readAt(total - 22, 22);
    const end = new DataView(endBuf.buffer);
    if (end.getUint32(0, true) !== 0x06054b50) throw new Error("no end of central directory (comment not allowed)");
    const count = end.getUint16(10, true);
    const cdSize = end.getUint32(12, true);
    const cdStart = end.getUint32(16, true);
    const cd = await readAt(cdStart, cdSize);
    const view = new DataView(cd.buffer);
    const dec = new TextDecoder("utf-8", { fatal: true });
    const entries: ZipEntryInfo[] = [];
    let p = 0;
    for (let i = 0; i < count; i++) {
      if (view.getUint32(p, true) !== 0x02014b50) throw new Error("bad central directory");
      if (view.getUint16(p + 10, true) !== 0) throw new Error("only STORE entries are expected");
      const crc = view.getUint32(p + 16, true);
      const size = view.getUint32(p + 24, true);
      const nameLen = view.getUint16(p + 28, true);
      const extraLen = view.getUint16(p + 30, true);
      const commentLen = view.getUint16(p + 32, true);
      const localOffset = view.getUint32(p + 42, true);
      const path = dec.decode(cd.subarray(p + 46, p + 46 + nameLen));
      const local = new DataView((await readAt(localOffset, 30)).buffer);
      if (local.getUint32(0, true) !== 0x04034b50) throw new Error("bad local header");
      const dataOffset = localOffset + 30 + local.getUint16(26, true) + local.getUint16(28, true);
      entries.push({ path, size, crc, dataOffset });
      p += 46 + nameLen + extraLen + commentLen;
    }
    return entries;
  } finally {
    f.close();
  }
}

/** Streams one entry's bytes to `onChunk` (for hashing / extraction). */
export async function readZipEntry(
  file: string,
  entry: ZipEntryInfo,
  onChunk: (chunk: Uint8Array) => void | Promise<void>,
): Promise<void> {
  const f = await Deno.open(file, { read: true });
  try {
    await f.seek(entry.dataOffset, Deno.SeekMode.Start);
    let left = entry.size;
    const buf = new Uint8Array(1 << 20);
    while (left > 0) {
      const n = await f.read(buf.subarray(0, Math.min(buf.length, left)));
      if (n === null) throw new Error("unexpected end of zip entry");
      await onChunk(buf.slice(0, n));
      left -= n;
    }
  } finally {
    f.close();
  }
}
