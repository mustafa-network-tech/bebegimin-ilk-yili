// Maps an authorize_artifact_download refusal to an HTTP answer (pure).

export type DownloadRefusal = { status: number; error: string; reason: string };

const MESSAGES: Record<string, [number, string]> = {
  not_found: [404, "Dosya bulunamadı."],
  // Decision P-12: only Anne / Baba download the outputs.
  not_parent: [
    403,
    "Kitap, film ve çevrimdışı arşivi yalnızca Anne veya Baba indirebilir.",
  ],
  permission_denied: [403, "Bu dosya sizinle paylaşılmadı."],
  membership_inactive: [403, "Aile üyeliğiniz etkin değil."],
  member_downloads_disabled: [
    403,
    "Aile üyesi indirmeleri geçici olarak kapalı.",
  ],
  rate_limited: [
    429,
    "Çok fazla indirme isteği. Lütfen birkaç dakika sonra tekrar deneyin.",
  ],
  subscription_required: [
    409,
    "İndirmek için aile paketinin etkin olması gerekiyor.",
  ],
  capacity_exceeded: [
    409,
    "Aile paketinin üye sınırı aşıldığı için aile üyeleri şu anda indiremiyor.",
  ],
  entitlement_required: [409, "Bu ürünün satın alımı etkin değil."],
  premium_requires_locked: [409, "Arşiv yeniden açıkken dosya indirilemez."],
  artifact_not_ready: [409, "Dosya henüz hazır değil."],
};

export function refusal(reason: string | null | undefined): DownloadRefusal {
  const key = reason ?? "";
  const [status, error] = MESSAGES[key] ?? [409, "Dosya indirilemiyor."];
  return { status, error, reason: key || "unknown" };
}
