# Veri modeli (ERD)

Özet ilişki diyagramı. Tüm tablolarda RLS açıktır. "servis" ile işaretli tablolar yalnız `service_role` ve SECURITY DEFINER RPC'ler üzerinden erişilir (bkz. `supabase/tests/99z_security_audit_test.sql`).

```mermaid
erDiagram
  AUTH_USERS ||--|| PROFILES : "1:1"
  FAMILY_ACCOUNTS ||--o{ FAMILY_ACCOUNT_MEMBERS : "parent / family_member"
  FAMILY_ACCOUNTS ||--o{ FAMILY_ACCOUNT_BABIES : ""
  FAMILY_ACCOUNT_BABIES ||--|| BABIES : "bir bebek tek hesapta"
  FAMILY_ACCOUNTS ||--o{ SUBSCRIPTIONS : "tek canlı abonelik"
  SUBSCRIPTION_PLANS ||--o{ SUBSCRIPTIONS : "Small / Normal / Large"
  BABIES ||--o{ FAMILY_MEMBERS : "bebek bazlı yetkiler"
  BABIES ||--o| BABY_EXTENSION_REQUESTS : "tek uzatma (1-30 gün)"
  BABIES ||--o{ MEMORIES : ""
  BABIES ||--o{ MILESTONES : ""
  BABIES ||--o{ LETTERS : ""
  BABIES ||--o{ MEDIA : ""
  BABIES ||--o{ COMMENTS : ""
  BABIES ||--o{ TIME_CAPSULES : ""
  BABIES ||--o{ BOOK_PROJECTS : "kitap ayarı"
  BOOK_PROJECTS ||--o{ BOOK_PAGES : ""
  BOOK_PAGES ||--o{ BOOK_ITEMS : ""
  BOOK_PROJECTS ||--o{ BOOK_EXPORTS : "sürümler (artifact'a bağlı)"
  PREMIUM_PRODUCTS ||--o{ PREMIUM_ORDERS : "fiyat sabitlenir"
  PREMIUM_ORDERS ||--o| PRODUCT_ENTITLEMENTS : "hesap + bebek + ürün"
  BABIES ||--o{ ARCHIVE_SNAPSHOTS : "mühürlü, değişmez (servis)"
  OUTPUT_PROJECTS ||--o{ OUTPUT_JOBS : "lease / retry / poison (servis)"
  ARCHIVE_SNAPSHOTS ||--o{ OUTPUT_JOBS : ""
  OUTPUT_JOBS ||--o{ OUTPUT_ARTIFACTS : "staging → verified → ready (servis)"
  OUTPUT_JOBS ||--o| BOOK_RENDER_MANIFESTS : "kitap ayarı dondurulur"
  OUTPUT_JOBS ||--o| FILM_RENDER_MANIFESTS : "sahne planı ≤ 600 sn"
  OUTPUT_ARTIFACTS ||--o| FILM_ARTIFACT_METADATA : "probe"
  OUTPUT_ARTIFACTS ||--o| HTML_ARTIFACT_METADATA : "manifest"
  OUTPUT_ARTIFACTS ||--o{ OUTPUT_ARTIFACT_DOWNLOADS : "denetim"
  FAMILY_ACCOUNTS ||--o{ ARTIFACT_DOWNLOAD_PERMISSIONS : "tarihsel paylaşım kaydı (P-12 ile yeni paylaşım yok)"
  BABIES ||--o{ LEGACY_GRANDFATHER_DECISIONS : "Super Admin kararı (servis)"
```

## Yetki eksenleri

Her hassas işlem dört ekseni ayrı ayrı denetler:

| Eksen | Kaynak |
|---|---|
| Üyelik | `family_members` (bebek), `family_account_members` (hesap; `parent` / `family_member`) |
| Yaşam döngüsü | `baby_lifecycle_active_internal` (375 gün + onaylı uzatma, Europe/Istanbul) |
| Abonelik | `subscriptions` + `subscription_grants_access`, plan kapasitesi |
| Satın alma hakkı | `product_entitlements` (hesap + bebek + ürün) |

Kaynak arşiv tabloları (anı, ilk, mektup, medya, yorum, kapsül) LOCKED bebekte tetikleyici ve RLS ile salt okunurdur.
