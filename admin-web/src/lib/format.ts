export const money = (minor: number, currency = "TRY") =>
  new Intl.NumberFormat("tr-TR", { style: "currency", currency }).format(minor / 100);

export const date = (value: string | null | undefined) =>
  value ? new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium" }).format(new Date(value)) : "—";

export const dateTime = (value: string | null | undefined) =>
  value
    ? new Intl.DateTimeFormat("tr-TR", { dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Istanbul" }).format(
        new Date(value),
      )
    : "—";

export const planName = (code: string) =>
  ({ small_family: "Small Family", normal_family: "Normal Family", large_family: "Large Family" })[code] ?? code;

export const productName = (code: string) =>
  ({
    first_year_book: "Dijital İlk Yıl Kitabı",
    first_year_html: "Offline HTML Hatırası",
    first_year_film: "İlk Yıl Filmi",
  })[code] ?? code;

export const statusLabel = (status: string | null) =>
  ({
    active: "Aktif",
    trialing: "Deneme",
    grace: "Ek süre",
    past_due: "Ödeme sorunu",
    canceled: "İptal edildi",
    expired: "Süresi doldu",
    pending: "Bekliyor",
    paid: "Ödendi",
    refunded: "İade edildi",
    revoked: "Geri alındı",
    applied: "Uygulandı",
    rejected: "Reddedildi",
    approved: "Onaylandı",
  })[status ?? ""] ?? status ?? "Bekliyor";
