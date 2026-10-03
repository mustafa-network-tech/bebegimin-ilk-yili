// Authorizes an output artifact with the caller's JWT and returns a fixed,
// short-lived (60 s) Storage URL. The URL is a bearer link: it is never
// logged, and revocations take effect for every new request. Authenticated clients have no direct SELECT policy
// on the output-artifacts bucket, so they cannot choose a longer lifetime.
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import { refusal } from "../_shared/download.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EXPIRES_IN = 60;

type DownloadGrant = {
  allowed: boolean;
  reason: string | null;
  bucket_id: string;
  storage_path: string;
  file_name: string;
  mime_type: string;
  size_bytes: number;
  sha256: string;
  expires_in: number;
};

function noStore(body: unknown, status = 200): Response {
  const response = json(body, status);
  response.headers.set("Cache-Control", "no-store");
  return response;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return noStore({ error: "method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return noStore({ error: "Oturum doğrulanamadı." }, 401);
  }

  let artifactId = "";
  try {
    const body = await req.json() as Record<string, unknown>;
    artifactId = String(body.artifact_id ?? "");
  } catch {
    return noStore({ error: "Geçersiz istek." }, 400);
  }
  if (!UUID.test(artifactId)) {
    return noStore({ error: "Geçersiz artifact." }, 400);
  }

  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) {
    return noStore({ error: "Oturum doğrulanamadı." }, 401);
  }

  // Every request re-runs the full check (membership, lifecycle,
  // subscription, capacity, parent grant, entitlement, artifact state);
  // grants and refusals are audited and grants are rate limited.
  const { data, error } = await userClient.rpc("authorize_artifact_download", {
    p_artifact_id: artifactId,
  });
  if (error) {
    console.error("output-download authorization failed");
    return noStore({ error: "Dosya indirilemiyor." }, 500);
  }
  const grant = (Array.isArray(data) ? data[0] : data) as DownloadGrant | null;
  if (!grant?.allowed) {
    const r = refusal(grant?.reason);
    const res = noStore({ error: r.error, reason: r.reason }, r.status);
    if (r.status === 429) res.headers.set("Retry-After", "600");
    return res;
  }
  if (
    grant.bucket_id !== "output-artifacts" || grant.expires_in !== EXPIRES_IN
  ) {
    return noStore({ error: "Dosya indirilemiyor." }, 409);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  const { data: signed, error: signError } = await admin.storage
    .from(grant.bucket_id)
    .createSignedUrl(grant.storage_path, EXPIRES_IN, {
      download: grant.file_name,
    });
  if (signError || !signed?.signedUrl) {
    // Do not log the path, URL, JWT or signing error: provider errors can
    // contain request details that do not belong in application logs.
    console.error("output-download signing failed");
    return noStore({ error: "Dosya bağlantısı oluşturulamadı." }, 500);
  }

  return noStore({
    url: signed.signedUrl,
    expires_in: EXPIRES_IN,
    file_name: grant.file_name,
    mime_type: grant.mime_type,
    size_bytes: grant.size_bytes,
    sha256: grant.sha256,
  });
});
