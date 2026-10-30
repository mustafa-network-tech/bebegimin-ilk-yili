// Shared test fixtures: film manifest builder and an archive snapshot.
import type { Snapshot } from "../src/html/site.ts";

export const output = {
  width: 1920,
  height: 1080,
  fps: 30,
  video_codec: "h264",
  audio_codec: "aac",
  audio_rate: 48000,
};
const BABY = "11111111-1111-4111-8111-111111111111";

export function manifest(scenes: Record<string, unknown>[]) {
  const total = scenes.reduce((n, s) => n + (s.duration_ms as number), 0);
  return {
    manifest_version: 1,
    product: "first_year_film",
    baby_id: BABY,
    snapshot_id: "33333333-3333-4333-8333-333333333333",
    snapshot_checksum: "a".repeat(64),
    output,
    max_duration_ms: 600000,
    base_duration_ms: total,
    min_duration_ms: total,
    total_duration_ms: total,
    over_limit: false,
    excess_ms: 0,
    scenes: scenes.map((s, i) => ({ chapter: 0, ...s, index: i })),
  };
}

const SNAP_BABY = "11111111-1111-4111-8111-111111111111";
const P1 = "22222222-2222-4222-8222-222222222222";
const V1 = "33333333-3333-4333-8333-333333333333";

export function sampleSnapshot(): Snapshot {
  return {
    schema_version: 1,
    baby: {
      id: SNAP_BABY,
      first_name: "Çağla",
      last_name: "Öz",
      birth_date: "2024-02-29",
      birth_time: "04:35:00",
      birth_place: "İzmir",
      story: "Bir şubat sabahı…",
    },
    lifecycle: { effective_close_date: "2025-03-10" },
    members: [{ user_id: "u1", name: "Ayşe", relation: "anne" }, {
      user_id: "u2",
      name: "",
      relation: "diger",
      relation_label: "Komşu",
    }],
    milestones: [{ id: "m1", title: "İlk adımım", emoji: "👣", achieved_on: "2025-01-10", description: "Salonda" }],
    memories: [{
      id: "a1",
      title: "<script>alert(1)</script> İlk gün",
      body: "Satır 1\nSatır 2\n\n<img src=x onerror=alert(2)>",
      memory_date: "2024-03-05",
      author: { user_id: "u1", name: "Ayşe", relation: "anne" },
    }],
    letters: [{
      id: "l1",
      title: null,
      body: 'Canım "kızım" & sevgim',
      written_on: "2024-06-01",
      author: { name: "Zeynep", relation: "teyze" },
    }],
    media: [
      {
        id: P1,
        kind: "photo",
        storage_path: `${SNAP_BABY}/${P1}/p.jpg`,
        caption: "Uykucu <b>",
        taken_on: "2024-03-05",
        memory_id: "a1",
      },
      { id: V1, kind: "video", storage_path: `${SNAP_BABY}/${V1}/v.mp4`, caption: null, taken_on: "2024-04-01" },
    ],
    comments: [{ id: "c1", memory_id: "a1", body: "Çok tatlı <3", author: { name: "Zeynep", relation: "teyze" } }],
  };
}
