import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export type StorageObject = { bucket_id: string; path: string };

/** Removes objects through the Storage API in chunks (direct SQL deletes on
 * storage.objects are not allowed). Missing objects are ignored. */
export async function removeObjects(
  admin: SupabaseClient,
  objects: StorageObject[],
): Promise<number> {
  const byBucket = new Map<string, string[]>();
  for (const o of objects) {
    if (!o?.path) continue;
    const list = byBucket.get(o.bucket_id) ?? [];
    list.push(o.path);
    byBucket.set(o.bucket_id, list);
  }
  let removed = 0;
  for (const [bucket, paths] of byBucket) {
    const unique = [...new Set(paths)];
    for (let i = 0; i < unique.length; i += 100) {
      const chunk = unique.slice(i, i + 100);
      const { data, error } = await admin.storage.from(bucket).remove(chunk);
      if (error) console.error(`storage remove failed (${bucket})`, error.name);
      removed += data?.length ?? 0;
    }
  }
  return removed;
}
