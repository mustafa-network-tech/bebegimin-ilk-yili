// Removes files whose database rows were deleted by cascades
// (public.storage_cleanup_queue). Schedule it (e.g. hourly) with pg_cron +
// pg_net, sending the header `x-cleanup-secret: <STORAGE_CLEANUP_SECRET>`.
import { createClient } from "npm:@supabase/supabase-js@2";
import { json, safeEqual } from "../_shared/cors.ts";
import { removeObjects, type StorageObject } from "../_shared/storage.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("STORAGE_CLEANUP_SECRET") ?? "";

Deno.serve(async (req) => {
  const given = req.headers.get("x-cleanup-secret") ?? "";
  if (!SECRET || !safeEqual(given, SECRET)) return json({ error: "unauthorized" }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data, error } = await admin
    .from("storage_cleanup_queue")
    .select("id, bucket_id, path")
    .order("id")
    .limit(500);
  if (error) return json({ error: error.message }, 500);
  if (!data?.length) return json({ ok: true, removed: 0 });

  // Never delete a file that is still referenced (e.g. re-uploaded path).
  const paths = data.map((r) => r.path);
  const [{ data: media }, { data: books }] = await Promise.all([
    admin.from("media").select("storage_path, thumb_path").or(`storage_path.in.(${paths.map((p) => `"${p}"`).join(",")}),thumb_path.in.(${paths.map((p) => `"${p}"`).join(",")})`),
    admin.from("book_exports").select("storage_path").in("storage_path", paths),
  ]);
  const referenced = new Set<string>([
    ...(media ?? []).flatMap((m) => [m.storage_path, m.thumb_path]).filter(Boolean),
    ...(books ?? []).map((b) => b.storage_path),
  ]);
  const toRemove = data.filter((r) => !referenced.has(r.path)) as StorageObject[];
  const removed = await removeObjects(admin, toRemove);
  await admin.from("storage_cleanup_queue").delete().in("id", data.map((r) => r.id));
  return json({ ok: true, removed });
});
