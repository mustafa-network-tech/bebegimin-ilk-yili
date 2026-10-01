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
| `baby_lifecycle_summary(baby_id)` | bebek | durum, kapanış tarihleri, kalan gün, uzatma durumu | — |
| `request_baby_extension(baby_id, days)` | 1–30 gün | talep | `lifecycle_locked`, tek talep |
| `create_baby(…)`, `accept_invitation(code)`, `preview_invitation(code)`, `revoke_invitation(id)`, `add_member_from_sibling(…)` | | | `invitation_*`, `family_capacity_full`, `parent_seats_full` |

## Abonelik ve satın alma

| RPC | Açıklama | Hint'ler |
|---|---|---|
| `subscription_plan_catalog()`, `subscription_store_products(provider)` | Plan kataloğu ve mağaza ürün kimlikleri | — |
| `request_subscription_checkout(account, plan, period, provider)` | Satın alma niyeti (ebeveyn) | `not_parent` |
| `family_account_overview(account)` | Hesap, abonelik, kapasite | — |
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
| `artifact_download_permission_list(baby_id)` | Ebeveyn: üye × ürün paylaşım durumu |
| `set_artifact_download_permission(baby_id, member, product, allowed)` | Ebeveyn: paylaş / kaldır (`member_not_found`, `not_parent`) |

İndirme ret nedenleri: `not_found`, `membership_inactive`, `premium_requires_locked`, `subscription_required`, `entitlement_required`, `member_downloads_disabled`, `capacity_exceeded`, `permission_denied`, `artifact_not_ready`, `rate_limited`.

## Super Admin (konsol kapısından geçer: rol + `admin_console` bayrağı + hız sınırı)

`admin_session`, `admin_extension_queue`, `admin_decide_extension`, `admin_baby_lookup`, `admin_preview_birth_date_correction`, `admin_correct_birth_date`, `admin_audit_log`, `admin_output_metrics`, `admin_download_audit`, `admin_legacy_book_report`, `admin_legacy_rollout_report`, `admin_release_health`, `admin_set_legacy_grandfather`.

## Sözleşme kuralları

- Yeni istemci-çağrılabilir fonksiyon eklemek `99z_security_audit_test.sql` beyaz listelerinin bilinçli güncellenmesini gerektirir.
- Hint adları API'nin parçasıdır; değiştirilirse uygulama metinleri ve bu belge birlikte güncellenir.
