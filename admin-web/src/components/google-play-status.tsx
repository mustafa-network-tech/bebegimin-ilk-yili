import { Badge } from "@/components/ui";
import type {
  GooglePlayCatalogCheckRow,
  GooglePlayCatalogItemRow,
} from "@/lib/admin/types";
import { dateTime, money } from "@/lib/format";

const connection = {
  success: { label: "Google Play bağlantısı başarılı", tone: "good" as const },
  not_configured: { label: "API bağlantısı yapılandırılmadı", tone: "neutral" as const },
  permission_denied: { label: "API yetki hatası", tone: "bad" as const },
  unavailable: { label: "API geçici olarak kullanılamıyor", tone: "warn" as const },
};

const details: Record<string, string> = {
  subscription_product_missing: "Google Play’de abonelik ürünü bulunamadı",
  base_plan_missing: "Temel plan bulunamadı",
  one_time_product_missing: "Google Play’de ürün bulunamadı",
  buy_option_missing: "Satın alma seçeneği bulunamadı",
  catalog_item_inactive: "Google Play kataloğunda aktif değil",
  not_available_in_tr: "Türkiye’de satışa açık değil",
  tr_price_missing: "Türkiye fiyatı alınamadı",
  currency_mismatch: "Para birimi uyuşmuyor",
  price_mismatch: "Fiyat uyuşmuyor",
};

export function GooglePlayCheckSummary({ check }: { check: GooglePlayCatalogCheckRow | null }) {
  if (!check) {
    return <div className="notice"><Badge>Henüz kontrol edilmedi</Badge> Google Play’den gerçek katalog verisi alınmadı.</div>;
  }
  const state = connection[check.connection_status];
  return (
    <div className={`notice ${check.connection_status === "permission_denied" ? "danger-notice" : ""}`}>
      <Badge tone={state.tone}>{state.label}</Badge>{" "}
      Son kontrol: {dateTime(check.checked_at)} · {check.checked_by_name}
      {check.error_code && <span className="code"> · {check.error_code}</span>}
    </div>
  );
}

export function findGooglePlayItem(
  check: GooglePlayCatalogCheckRow | null,
  kind: GooglePlayCatalogItemRow["kind"],
  productId: string | null,
  basePlanId: string | null = null,
) {
  if (!check || check.connection_status !== "success" || !productId) return null;
  return check.results.find((item) =>
    item.kind === kind && item.product_id === productId && item.base_plan_id === basePlanId) ?? null;
}

export function GooglePlayItemStatus({ item }: { item: GooglePlayCatalogItemRow | null }) {
  if (!item) return <><Badge>Doğrulanmadı</Badge><small>Gerçek Google Play verisi yok</small></>;
  if (item.status === "verified") {
    return <><Badge tone="good">Google Play’de doğrulandı</Badge><small>{item.play_state} · {money(item.play_price_minor!, item.play_currency!)}</small></>;
  }
  if (item.status === "not_found") {
    return <><Badge tone="bad">Google Play’de bulunamadı</Badge><small>{details[item.detail_code ?? ""] ?? "Ürün bulunamadı"}</small></>;
  }
  return <><Badge tone="warn">Fiyat veya plan uyuşmazlığı</Badge><small>{details[item.detail_code ?? ""] ?? "Katalog bilgileri eşleşmiyor"}{item.play_price_minor != null && item.play_currency ? ` · Play: ${money(item.play_price_minor, item.play_currency)}` : ""}</small></>;
}
