# İstemci RPC sözleşmeleri

Uygulamanın çağırdığı sunucu fonksiyonları. Hepsi `authenticated` rolüyle (yalnız `app_config` ve davet önizlemesi oturumsuz) ve SECURITY DEFINER olarak çalışır; yetki kararını sunucu verir. Hatalar PostgREST hatası olarak döner: `code` (SQLSTATE) ve kararın nedeni olan `hint`. Uygulama metinleri `lib/core/errors/app_exception.dart` içinde hint'e göre eşlenir.

Ortak hata kodları:

| `code` | Anlam |
|---|---|
| `P0002` | Kayıt yok veya kullanıcı göremez (varlık sızdırılmaz) |
| `42501` | Rol yetersiz (ör. `not_parent`) |
| `55000` | İş kuralı reddi (`hint` nedeni söyler) |
| `22023` | Geçersiz girdi |

## Genel

| RPC | Girdi | Çıktı | Önemli hint'ler |
|---|---|---|---|
| `app_config()` | — | `min_supported_build`, `latest_build` | — (oturumsuz okunabilir) |
| `baby_lifecycle_summary(baby_id)` | bebek | durum, kapanış tarihleri, kalan gün, uzatma durumu; `can_request_extension` yalnız Anne/Baba için `true` olabilir | — |
| `request_baby_extension(baby_id, days)` | 1–30 gün | talep (yalnız Anne/Baba; karar P-6) | `not_parent` (hak tüketilmez), `lifecycle_locked`, tek talep |
| `create_baby(…)`, `accept_invitation(code)`, `preview_invitation(code)`, `revoke_invitation(id)`, `add_member_from_sibling(…)` | | | `invitation_*`, `family_capacity_full`, `parent_seats_full`, `admin_requires_parent`, `not_parent` |
| `account_deletion_blockers()` | — | Hesap silmeyi engelleyen bebekler (`baby_id`, `first_name`): kullanıcının tek üyesi olduğu ya da yanında başka Anne/Baba olmadan tek yöneticisi olduğu bebekler (karar P-10) | — |

Ebeveyn yetkileri (kararlar P-3, P-5, P-8, P-9, P-10; `20261002000200_parent_authority.sql`):

- Yönetici yalnız `anne` / `baba` olabilir. Ebeveyn olmayanı yönetici yapan her yazma (üye güncelleme, davet, kardeşten ekleme, `create_baby`) `admin_requires_parent` ile reddedilir.
- `anne` / `baba` daveti oluşturmak, bir üyeyi `anne` / `baba` yapmak ya da yönetici yapmak yalnız o bebeğin ebeveynine açıktır (`not_parent`).
- Bir ebeveynin üyeliği başka biri tarafından silinemez; yöneticiliği ve ilişkisi başka biri tarafından değiştirilemez (`parent_protected`). Ebeveyn kendi isteğiyle ayrılabilir; son yöneticiyse `last_admin` reddi geçerlidir.
- Bebeği yalnız ebeveyn silebilir (`privacy-actions` → `delete_baby`, 403 "Bebeği yalnızca Anne veya Baba silebilir.").
- Hesap silme (`privacy-actions` → `delete_account`) tek ebeveyni olunan bebek varken 409 `reason: delete_babies_first` döner. Bebekler hiçbir zaman örtük olarak silinmez. Diğer ebeveyn varsa o tek yönetici olarak kalır.

## Abonelik ve satın alma

| RPC | Açıklama | Hint'ler |
|---|---|---|
| `subscription_plan_catalog()`, `subscription_store_products(provider)` | Plan kataloğu ve mağaza ürün kimlikleri | — |
| `request_subscription_checkout(account, plan, period, provider)` | Satın alma niyeti (ebeveyn) | `not_parent` |
| `family_account_overview(account)` | Hesap, abonelik, kapasite | — |
| `baby_access_state(baby_id)` | `allowed` = aile yazabilir; `false` ise arşiv salt okunurdur (karar P-2): okuma açık, yazma / premium kapalı. `reason`: `ok`, `enforcement_off`, `no_subscription`, `payment_issue`, `subscription_ended`, `account_unmapped`; `is_parent` | — |
| `premium_storefront(baby_id)` | Ürünler + fiyat (sunucu kataloğu) + satın alma engeli | `not_parent`, `premium_requires_locked` |
| `request_premium_purchase(baby_id, product, provider)` | Sipariş açar; fiyat sabitlenir | `already_owned`, `subscription_required`, `storefront_closed` |
| `baby_entitlements(baby_id)` | Sahip olunan ürünler | — |

Ödeme doğrulaması `billing-verify-purchase` ve `billing-webhook` Edge Function'larıyla sunucuda yapılır.

## Ürünler (ortak kural: LOCKED + ebeveyn + abonelik + satın alma)

| Ürün | Durum | İstek / düzenleme | Hint'ler |
|---|---|---|---|
| Kitap | `book_access_state`, `book_versions` | Tablolar (`book_projects/pages/items`, RLS) · `book_render_start` → `book_render_payload` → `book_artifact_begin` → staging yükleme → `book-artifact-finalize` · `book_render_heartbeat`, `book_render_fail` | `book_render_in_progress`, `book_renderer_disabled`, `lease_lost`, `book_project_missing` |
| Film | `film_access_state`, `film_state`, `film_plan`, `film_settings` | `film_update_settings`, `film_suggest_settings`, `film_request_render` | `film_too_long`, `film_empty`, `film_render_in_progress`, `film_renderer_disabled` |
| Arşiv | `html_access_state`, `html_state` | `html_request_render` | `html_render_in_progress`, `html_renderer_disabled` |

Ortak hint'ler: `premium_requires_locked`, `subscription_required`, `entitlement_required`, `not_parent`, `quota_exceeded`.

## İndirme ve paylaşım

| Uç | Açıklama |
|---|---|
| `output-download` (Edge, `{"artifact_id"}`) | `authorize_artifact_download` ile tüm koşulları denetler. 200: `url` (60 sn), `file_name`, `mime_type`, `size_bytes`, `sha256`. Ret: 403 / 404 / 409 / 429 ve `reason` |
| `authorize_artifact_download(artifact_id)` | `allowed`, `reason` (ret de denetlenir), izinliyse dosya bilgisi |
| `artifact_download_permission_list(baby_id)` | Tarihsel: üye × ürün paylaşım kayıtları (karar P-12 sonrası yeni paylaşım yok) |
| `set_artifact_download_permission(baby_id, member, product, allowed)` | `allowed = true` → `member_downloads_disabled` (karar P-12); `false` yalnız iptal eder |

İndirme ret nedenleri: `not_found`, `not_parent` (karar P-12: yalnız Anne/Baba indirir), `membership_inactive`, `premium_requires_locked`, `subscription_required`, `entitlement_required`, `member_downloads_disabled`, `capacity_exceeded`, `permission_denied`, `artifact_not_ready`, `rate_limited`.

## Super Admin (konsol kapısından geçer: rol + `admin_console` bayrağı + hız sınırı)

`admin_session`, `admin_extension_queue`, `admin_decide_extension`, `admin_baby_lookup`, `admin_preview_birth_date_correction`, `admin_correct_birth_date`, `admin_audit_log`, `admin_output_metrics`, `admin_download_audit`, `admin_legacy_book_report`, `admin_legacy_rollout_report`, `admin_release_health`, `admin_set_legacy_grandfather`, `admin_parent_authority_report` (yöneticisi ebeveyn olmayan eski kayıtlar, yöneticisiz Anne/Baba, ebeveyn yöneticisi olmayan bebekler), `admin_media_date_report` (çekim tarihi doğum − 310 günden önce veya gelecekte olan eski medya).

Medya çekim tarihi (`media.taken_on`) anı, ilk ve mektuplarla aynı kurala uyar: doğum − 310 gün ile bugün + 1 gün arası. Aksi halde `date_before_birth` / `date_in_future` döner (`20261002000500_media_date_guard.sql`).

## Sözleşme kuralları

- Yeni istemci-çağrılabilir fonksiyon eklemek `99z_security_audit_test.sql` beyaz listelerinin bilinçli güncellenmesini gerektirir.
- Hint adları API'nin parçasıdır; değiştirilirse uygulama metinleri ve bu belge birlikte güncellenir.
