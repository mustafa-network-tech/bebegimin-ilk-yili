// Finalizes an official book PDF rendered by a parent's app (Phase 9).
//
// The app leased a book job (book_render_start), rendered the PDF from the
// sealed snapshot + frozen manifest, created the artifact row
// (book_artifact_begin) and uploaded the file to its staging path. Here the
// server re-reads the staged bytes itself, checks they are a PDF, hashes
// them, and only then verifies, moves and publishes the artifact. The app's
// own checksum claim is never trusted on its own.
//
// The app retries this call after a network error, so every step is safe to
// repeat (see finalizeAction): a verified artifact whose move or publish did
// not finish is re-hashed and continued, and a published one is answered
// with its version again instead of an error.
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";
import {
  bookClientWorker,
  finalizeAction,
  looksLikePdf,
  parseFinalizeRequest,
  sha256Hex,
} from "../_shared/book_artifact.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const BUCKET = "output-artifacts";

type ArtifactRow = {
  id: string;
  job_id: string;
  product_code: string;
  status: string;
  staging_path: string;
  storage_path: string;
  size_bytes: number;
  sha256: string;
  verified_sha256: string | null;
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

  let request;
  try {
    request = parseFinalizeRequest(await req.json());
  } catch {
    request = null;
  }
  if (!request) {
    return noStore({ error: "Geçersiz istek." }, 400);
  }

  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) {
    return noStore({ error: "Oturum doğrulanamadı." }, 401);
  }
  const worker = bookClientWorker(user.id);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  const { data: artifact } = await admin
    .from("output_artifacts")
    .select(
      "id, job_id, product_code, status, staging_path, storage_path, size_bytes, sha256, verified_sha256",
    )
    .eq("id", request.artifactId)
    .maybeSingle<ArtifactRow>();
  if (!artifact || artifact.product_code !== "first_year_book") {
    return noStore({ error: "Dosya bulunamadı." }, 404);
  }

  // The reply for an artifact that is already published (by this call, an
  // earlier one whose reply was lost, or a concurrent retry); null if not.
  const publishedReply = async (): Promise<Response | null> => {
    const { data: current } = await admin
      .from("output_artifacts")
      .select("status, sha256, verified_sha256")
      .eq("id", artifact.id)
      .maybeSingle<
        { status: string; sha256: string; verified_sha256: string | null }
      >();
    if (current?.status !== "ready") return null;
    const { data: published } = await admin
      .from("book_exports")
      .select("id, version")
      .eq("artifact_id", artifact.id)
      .maybeSingle<{ id: string; version: number }>();
    if (!published) return null;
    return noStore({
      status: "ready",
      artifact_id: artifact.id,
      export_id: published.id,
      version: published.version,
      sha256: current.verified_sha256 ?? current.sha256,
      size_bytes: artifact.size_bytes,
    });
  };

  const action = finalizeAction(artifact.status);
  if (action === "already_ready") {
    // Only the parent whose job it was gets the answer; the lease is
    // already released, so ownership is checked on the job itself.
    const { data: job } = await admin
      .from("output_jobs")
      .select("requested_by")
      .eq("id", artifact.job_id)
      .maybeSingle<{ requested_by: string | null }>();
    if (!job || job.requested_by !== user.id) {
      return noStore({ error: "Dosya bulunamadı." }, 404);
    }
    return await publishedReply() ??
      noStore({ error: "Kitap yayınlanamadı." }, 409);
  }
  if (action === "refuse") {
    return noStore({
      error: "Bu yükleme kullanılamıyor.",
      reason: `artifact_${artifact.status}`,
    }, 409);
  }

  // Ownership, lease and the full book gate (lifecycle, subscription,
  // entitlement) are re-checked with the caller's JWT; the lease is extended
  // while the server hashes the file.
  const { error: leaseError } = await userClient.rpc("book_render_heartbeat", {
    p_job_id: artifact.job_id,
  });
  if (leaseError) {
    const status = leaseError.code === "P0002" ? 404 : 409;
    return noStore({
      error: status === 404
        ? "Dosya bulunamadı."
        : "Kitap şu anda tamamlanamıyor.",
      reason: leaseError.hint ?? null,
    }, status);
  }
  const failJob = (code: string, message: string) =>
    admin.rpc("output_job_fail", {
      p_job_id: artifact.job_id,
      p_worker: worker,
      p_error_code: code,
      p_error: message,
      p_retryable: true,
    });

  const download = async (path: string): Promise<Uint8Array | null> => {
    const { data, error } = await admin.storage.from(BUCKET).download(path);
    return error || !data ? null : new Uint8Array(await data.arrayBuffer());
  };
  const moveToFinal = async (): Promise<Response | null> => {
    const { error: moveError } = await admin.storage.from(BUCKET).move(
      artifact.staging_path,
      artifact.storage_path,
    );
    if (!moveError) return null;
    console.error("book finalize: move failed");
    await failJob("move_failed", "verified object could not be moved");
    return noStore({
      error: "Kitap kaydedilemedi, lütfen tekrar deneyin.",
      reason: "move_failed",
    }, 500);
  };

  let verifiedSha: string | null = null;
  if (action === "verify") {
    const bytes = await download(artifact.staging_path);
    if (bytes) {
      if (!looksLikePdf(bytes)) {
        await failJob("invalid_pdf", "uploaded file is not a PDF");
        return noStore({
          error: "Yüklenen dosya geçerli bir PDF değil.",
          reason: "invalid_pdf",
        }, 422);
      }
      verifiedSha = await sha256Hex(bytes);
    }

    // A missing object or a hash that differs from the declared checksum
    // quarantines the artifact inside output_artifact_verify.
    const { data: verifyResult, error: verifyError } = await admin.rpc(
      "output_artifact_verify",
      {
        p_artifact_id: artifact.id,
        p_worker: worker,
        p_verified_sha256: verifiedSha,
      },
    );
    if (verifyError) {
      console.error("book finalize: verify failed");
      return noStore({ error: "Kitap doğrulanamadı." }, 500);
    }
    if (verifyResult !== "verified") {
      return noStore({
        error: "Yüklenen dosya doğrulanamadı.",
        reason: verifyResult,
      }, 409);
    }
    const moveFailure = await moveToFinal();
    if (moveFailure) return moveFailure;
  } else {
    // Resume: verified by an earlier call whose move or publish did not
    // finish. The object (final if moved, staging otherwise) is hashed again
    // and must still be the exact bytes that were verified.
    let bytes = await download(artifact.storage_path);
    const moved = bytes !== null;
    if (!moved) bytes = await download(artifact.staging_path);
    if (!bytes) {
      await failJob("object_missing", "verified object missing");
      return noStore({
        error: "Yüklenen dosya bulunamadı.",
        reason: "object_missing",
      }, 409);
    }
    verifiedSha = await sha256Hex(bytes);
    if (verifiedSha !== artifact.verified_sha256 || !looksLikePdf(bytes)) {
      await failJob("checksum_mismatch", "verified object changed");
      return noStore({
        error: "Yüklenen dosya doğrulanamadı.",
        reason: "checksum_mismatch",
      }, 409);
    }
    if (!moved) {
      const moveFailure = await moveToFinal();
      if (moveFailure) return moveFailure;
    }
  }

  const { data: published, error: publishError } = await admin.rpc(
    "book_artifact_publish",
    {
      p_artifact_id: artifact.id,
      p_worker: worker,
      p_page_count: request.pageCount,
    },
  );
  const row = (Array.isArray(published) ? published[0] : published) as
    | { status: string; export_id: string | null; book_version: number | null }
    | null;
  if (publishError || !row) {
    console.error("book finalize: publish failed");
    return noStore({ error: "Kitap yayınlanamadı." }, 500);
  }
  if (row.status !== "ready") {
    // A concurrent retry may have published it first.
    return await publishedReply() ??
      noStore({ error: "Kitap yayınlanamadı.", reason: row.status }, 409);
  }

  return noStore({
    status: "ready",
    artifact_id: artifact.id,
    export_id: row.export_id,
    version: row.book_version,
    sha256: verifiedSha,
    size_bytes: artifact.size_bytes,
  });
});
