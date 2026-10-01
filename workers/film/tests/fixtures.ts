// Shared test manifest builder (schema version 1).
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
