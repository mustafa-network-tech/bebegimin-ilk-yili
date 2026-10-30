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

export const eventLabel = (type: string) =>
  ({
    user_registered: "Kayıt oldu",
    email_verified: "E-posta doğrulandı",
    first_sign_in: "İlk giriş yapıldı",
    family_created: "Aile hesabı oluşturuldu",
    baby_added: "Bebek profili eklendi",
    plans_viewed: "Abonelik paketleri görüntülendi",
    plan_selected: "Abonelik paketi seçildi",
    checkout_intent_created: "Paket seçimi hazırlandı (ödeme niyeti açıldı)",
    payment_started: "Ödeme başlatıldı",
    payment_canceled_by_user: "Ödeme ekranından vazgeçildi",
    payment_failed: "Mağaza ödeme hatası verdi",
    payment_pending: "Ödeme mağazada beklemede",
    payment_verified: "Ödeme mağaza tarafından onaylandı",
    store_verification_failed: "Mağaza doğrulaması yapılamadı (ödeme durumu bilinmiyor)",
    activation_granted: "Erişim açıldı",
    activation_failed: "Etkinleştirme başarısız",
    subscription_activated: "Abonelik etkinleştirildi",
    subscription_canceled: "Abonelik iptal edildi",
    subscription_expired: "Abonelik süresi doldu",
  })[type] ?? type;

export const errorCodeLabel = (code: string | null) =>
  code
    ? ({
        not_configured: "Google Play bağlantısı yapılandırılmamış",
        google_401: "Google kimlik doğrulama hatası (401)",
        google_403: "Google yetki hatası (403)",
        google_404: "Google satın alma kaydı bulunamadı (404)",
        product_not_found: "Ürün kataloğda yok",
        base_plan_unavailable: "Temel plan kataloğda yok",
        verification_failed: "Doğrulama başarısız",
        purchase_rejected: "Satın alma reddedildi",
        temporary_error: "Geçici hata",
        purchase_not_yours: "Satın alma başka bir aileye ait",
        purchase_inactive: "Satın alma artık geçerli değil",
        user_canceled: "Kullanıcı vazgeçti",
        store_error: "Mağaza hatası",
        billing_unavailable: "Mağaza kullanılamıyor",
      })[code] ?? code
    : null;

export const platformLabel = (platform: string) =>
  ({ android: "Android", ios: "iOS", web: "Web" })[platform] ?? "—";

export const paymentProblemLabel = (problem: string) =>
  problem === "paid_not_activated"
    ? "Ödeme mağazada onaylandı, abonelik etkinleşmedi"
    : "Mağaza doğrulaması başarısız — ödeme alınıp alınmadığı bilinmiyor";
