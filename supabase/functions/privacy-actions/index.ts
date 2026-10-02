// Privacy operations that need the service role:
//   { action: "delete_account", delete_content?: boolean }
//   { action: "delete_baby", baby_id: string }
// The caller is identified from their JWT; the database functions enforce
// who may do what (only Anne / Baba can delete a baby, a parent who is alone
// on a baby deletes it before the account, etc.).
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { removeObjects, type StorageObject } from "../_shared/storage.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return json({ error: "Oturum doğrulanamadı." }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Geçersiz istek." }, 400);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  try {
    if (body.action === "delete_account") {
      const { data, error } = await admin.rpc("prepare_account_deletion", {
        p_user: user.id,
        p_delete_content: body.delete_content === true,
      });
      // Decision P-10: a parent who is alone on a baby deletes the babies first.
      if (error?.hint === "delete_babies_first") {
        return json({
          error:
            "Hesabınızı silmeden önce tek ebeveyni olduğunuz bebek profillerini silmelisiniz.",
          reason: "delete_babies_first",
        }, 409);
      }
      if (error) throw error;
      const removed = await removeObjects(
        admin,
        (data ?? []) as StorageObject[],
      );
      const { error: delError } = await admin.auth.admin.deleteUser(user.id);
      if (delError) throw delError;
      return json({ ok: true, removed_files: removed });
    }

    if (body.action === "delete_baby") {
      const babyId = String(body.baby_id ?? "");
      if (!UUID.test(babyId)) return json({ error: "Geçersiz bebek." }, 400);
      const { data, error } = await admin.rpc("delete_baby_for_user", {
        p_user: user.id,
        p_baby_id: babyId,
      });
      if (error) {
        const forbidden = error.code === "42501";
        return json({
          error: forbidden
            ? "Bebeği yalnızca Anne veya Baba silebilir."
            : error.message,
        }, forbidden ? 403 : 400);
      }
      const removed = await removeObjects(
        admin,
        (data ?? []) as StorageObject[],
      );
      return json({ ok: true, removed_files: removed });
    }

    return json({ error: "Bilinmeyen işlem." }, 400);
  } catch (e) {
    // Error details can contain storage paths or ids: log the type only.
    console.error("privacy-actions failed", (e as Error)?.name ?? "unknown");
    return json({ error: "İşlem tamamlanamadı. Lütfen tekrar deneyin." }, 500);
  }
});
