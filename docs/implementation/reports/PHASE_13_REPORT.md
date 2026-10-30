# Faz 13 Sonuç Raporu

- **Durum:** IN_PROGRESS — repo içindeki tüm işler tamamlandı ve test edildi; go-live kapıları staging / production ortamında kanıtlanmayı bekliyor (bkz. [release-runbook.md](../../operations/release-runbook.md)).
- **Başlangıç commit'i:** `fd45571`
- **Eklenen migration:** `supabase/migrations/20261001000500_release_hardening.sql`
- **Kullanıcı kararı:** "Repodakini yap, kalanı runbook." Ortam gerektiren adımlar runbook'a yazıldı; faz bu yüzden `COMPLETE` işaretlenmedi.

## Giriş koşulları

| Koşul | Durum |
|---|---|
| Faz 0–12 `COMPLETE` | ✓ (`PHASE_STATUS.md`) |
| Staging, production benzeri veri hacmi, ödeme sandbox testleri | ✗ Bu oturumda erişim yok. Veri hacmi `supabase/tests/perf/volume_check.sql` ile sentetik olarak ölçüldü; staging ve sandbox runbook'ta. |

## Değişen dosyalar

- Veritabanı: `20261001000500_release_hardening.sql`; testler `99r_release_hardening_test.sql`, `99z_security_audit_test.sql` (yeni), `60_account_notifications_test.sql` (hatırlatma günü); `supabase/tests/perf/volume_check.sql` (manuel hacim aracı)
- Edge: `privacy-actions/index.ts`, `_shared/storage.ts` (log redaction)
- Flutter: `lib/features/app_config/app_config.dart` (yeni), `lib/app/app.dart`, `lib/app/env.dart` (`APP_BUILD`); test `test/app_config/upgrade_gate_test.dart`
- CI: secret / service-role taraması
- Belgeler: `docs/operations/release-runbook.md`, `docs/architecture/erd.md`, `docs/api/client-rpc-contracts.md`, `docs/support/support-texts.md`, `README.md`, `PHASE_STATUS.md`

## Uygulananlar

### Legacy veri politikası

- Lifecycle her istekte hesaplandığı için backfill gerekmez; 375 günü geçmiş bebekler migration anında LOCKED olur ve `admin_legacy_rollout_report()` ile listelenir.
- 405. günden sonraya tarihli legacy içerik **silinmez**, uygulamada görünür kalır, ancak resmî snapshot'a girmez (`build_archive_snapshot_content`, yorumlar dahil).
- Super Admin gerekçeli (≥ 10 karakter), denetimli kararla dahil edebilir veya geri alabilir (`admin_set_legacy_grandfather`). Kararlar silinmez, son karar geçerlidir, `activity_logs`'a yazılır. Önceden mühürlenmiş snapshot'lar değişmez.
- Eski kitap proje / export'ları Faz 9'dan beri karantinada; rapor sayıları birleşik raporda.
- Sahipsiz `baby-media` dosyaları raporlanır, silinmez. Aile hesabı olmayan bebekler ve birden çok hesapta ebeveyn olan kullanıcılar raporlanır, otomatik birleştirilmez.

### KVKK silme düzeltmesi (bulunan açık)

- **Sorun:** Faz 7–8'den beri, ürün satın alınmış bir bebeğin silinmesi (`delete_baby_for_user`, `prepare_account_deletion`) `premium_orders` / `product_entitlements` / `archive_snapshots` / `output_projects` üzerindeki `ON DELETE RESTRICT` ve değiştirilemezlik guard'ları yüzünden **başarısız oluyordu**. Plan §3.6 ("immutable archive yasal silme hakkını engellemez") ihlal ediliyordu.
- **Çözüm (sınıflandırılmış saklama):** `babies` silinmeden önce `babies_erase_outputs` çalışır. Kişisel içerik silinir: snapshot, manifest, çıktı kayıtları ve meta verisi, o dosyaların indirme / ret kayıtları. Dosyalar `storage_cleanup_queue`'ya alınır. Mali kayıtlar (sipariş, satın alma hakkı) yasal saklama için korunur, bebek bağı `NULL` olur.
- Değiştirilemezlik guard'ları insert / update kurallarını aynen korur. Silme yalnız yasal silme işleminin transaction'ında (`bebegimin.legal_erasure`) mümkündür; test bunun transaction dışına sızmadığını da doğrular.

### Gözlemlenebilirlik

`admin_release_health()`: `lifecycle_mismatch`, `output_queue_age_minutes`, `output_jobs_poison_24h`, `artifact_checksum_failures_24h`, `download_denials_1h`, `payment_webhook_rejections_24h`, `payment_webhook_silence_hours`, `storage_cleanup_backlog`, `subscriptions_over_capacity` — her biri ok / warn / critical. Eşikler ve ilk müdahaleler runbook §4'te. Reddedilen yazmalar transaction geri alındığı için veritabanında sayılamaz; API logundaki `lifecycle_locked` hint'iyle izlenir (runbook'ta belgeli).

### Güvenlik denetimi

- `99z_security_audit_test.sql` (kalıcı, CI'da): her tabloda RLS; anon'un tablo yetkisi yok; anon yalnız `app_config` çalıştırabilir; tüm SECURITY DEFINER fonksiyonlarında sabit `search_path`; istemci yazma yetkileri gözden geçirilmiş listeyle birebir; çıktı / ödeme / denetim / platform tabloları yalnız servis; public bucket yok; çıktı ve legacy kitap bucket'larında okuma politikası yok; view'lar `security_invoker`; istemciden çağrılabilir her `admin_*` RPC konsol kapısından geçiyor; iç yardımcılar istemciye kapalı.
- Bulgular ve düzeltmeler:
  - Trigger ve yardımcı fonksiyonlar Postgres varsayılanıyla anon'a açıktı (trigger'lar doğrudan çağrılamaz, pratik açık değildi); yetkiler daraltıldı.
  - Bu fazın iki yardımcısı istemciye açıktı (`legacy_content_included` bir bebek için karar bilgisini sızdırabilirdi); kapatıldı.
  - `privacy-actions` hata nesnesinin tamamını, `storage.ts` Storage hata mesajını logluyordu; yalnız hata türü loglanıyor.
- Secret taraması: uygulama kodunda service-role izi, repoda JWT / özel anahtar / canlı anahtar yok; `env/dev.json` git dışında. CI adımı bunu kalıcı denetler.
- Bağımlılıklar: Flutter paketleri `pubspec.lock` ile, Deno paketleri `deno.lock` ile sabit. Bilinen güvenlik bildirimi taraması (ör. OSV) ortamda çalıştırılmadı (runbook kapısı).

### Performans (sentetik hacim: 2 000 aile, ~400 bin medya, ~100 bin anı)

| Sorgu | Süre |
|---|---|
| Zaman tüneli sayfası (RLS, imzalı kullanıcı) | 13 ms (indeks taraması) |
| Bir bebeğin snapshot içeriği | 24 ms |
| 200 medyalı film planı | 31 ms |
| 2 000 bebeğin lifecycle özeti | 26 ms |
| Tüm bebekler için günlük iş | 133 ms |

Yeni indeks gerekmedi. Gerçek veri hacminde tekrar ölçüm runbook kapısıdır.

### Kota ve maliyet

Bebek + ürün başına 24 saatte çıktı işi (Kitap 30 / Film 12 / HTML 6; `platform_settings`), `quota_exceeded`. İndirme hız sınırları Faz 12'den.

### Eski istemciler

Sunucu her kuralı kendisi uygular; eski sürümler politikayı aşamaz, anlaşılır hata alır. `APP_BUILD` + `client_min_build` ile zorunlu güncelleme; çevrimdışıyken uygulama kilitlenmez.

### Bildirim düzeltmesi

"Kitap hazır" hatırlatması 365. günde (arşiv hâlâ ACTIVE ve kitap kapalıyken) gidiyordu. Artık arşivin kilitlendiği gün (375 + onaylı uzatma) "İlk Yıl arşivi tamamlandı" olarak gidiyor; tekilleştirme korunuyor.

## Tam kabul test paketi

| Plan maddesi | Testler |
|---|---|
| Lifecycle sınırları ve timezone | `12_lifecycle_extensions_test.sql`, `test/babies/baby_lifecycle_test.dart` |
| Uzatma tekliği / yarış / Super Admin | `12_*`, `80_super_admin_console_test.sql`, `run_db_tests.sh` yarış testleri |
| İki bebek aynı aile / farklı aile IDOR | `10_isolation_test.sql`, `15_same_family_context_test.sql`, `99m` |
| İçerik / RPC / Storage mutation bypass | `70_lifecycle_mutation_lock_test.sql`, `50_storage_books_test.sql`, `99z` |
| Tek aile aboneliği, kapasite, upgrade / downgrade, ayrı üye aboneliği yok | `90_family_accounts_subscriptions_test.sql`, `95_store_billing_access_gate_test.sql`, kapasite yarışı, `99m` |
| Üç ayrı entitlement ve doğru fiyat | `97_premium_entitlements_test.sql` |
| Snapshot / job / artifact idempotency ve checksum | `98_output_pipeline_test.sql` |
| Kitap regresyonu | `test/book/*` (snapshot ↔ canlı birebir), `99_book_artifacts_test.sql` |
| Film ≤ 600 sn | `99f_film_artifacts_test.sql`, worker film entegrasyonu |
| HTML tam offline | Worker arşiv entegrasyonu (Chrome, ağ kapalı) |
| Family Member izinli indirme | `99m_member_downloads_test.sql` |
| Re-download, cancel / reactivate, refund / chargeback | `99m`, `97` |
| KVKK silme ve mühürlü zaman kapsülü | `60_account_notifications_test.sql`, `40_capsules_dates_test.sql`, `99r` (satın alınmış bebek silme), `98` (kapsül snapshot'a girmez) |
| Bildirim tekilleştirme | `60_account_notifications_test.sql` |

## Çalıştırılan testler ve sonuçları

- `supabase/tests/run_db_tests.sh` (PostgreSQL 16.10): **✓ all database tests passed** — 1 015 doğrulama (`99r`: 42, `99z`: 12).
- `flutter analyze`: No issues found. `flutter test`: 158/158. `dart format --set-exit-if-changed`: değişiklik yok.
- Edge: `deno check` (output-download, book-artifact-finalize, privacy-actions, storage-cleanup) temiz; `deno test` 15/15.
- Worker: `deno task test` 13/13 (ffmpeg 9.0.2 gerçek film / arşiv, Chrome ağ kapalı açılış).
- Hacim ölçümü: `supabase/tests/perf/volume_check.sql`.

## Çalıştırılamayan / ortam gerektiren işler (go-live kapıları)

| Kapı | Neden yapılamadı | Nerede |
|---|---|---|
| Staging'e migration ve shadow / internal / cohort / kademeli rollout | Ortam erişimi yok | runbook §1–3 |
| Gerçek veri mutabakatı (%100 veya onaylı istisna) | Gerçek veri yok | runbook §2 |
| Ödeme webhook / makbuz idempotency'sinin sandbox'ta kanıtı | Mağaza sandbox erişimi yok (SQL idempotency testleri mevcut) | runbook §10 |
| Kill switch tatbikatı | Ortamda yapılmalı (SQL'de her bayrak test edildi) | runbook §5 |
| Yedek / geri yükleme ve felaket kurtarma tatbikatı | Ortam gerekli | runbook §6 |
| Bağımsız saldırı testi | Bağımsız ekip gerekli (repo içi denetim `99z` hazır) | runbook §10 |
| Bağımlılık güvenlik bildirimi taraması (OSV vb.) | Ortamda çalıştırılmadı | runbook §10 |
| `first-year-lifecycle-v1` etiketi | Kapılar kapanınca atılır | — |

## Bilinen riskler

- **Saklama süreleri hukuki onay gerektirir:** Silinen bebeğin sipariş / satın alma hakkı kayıtları bebek bağı olmadan saklanıyor; kesin süre ve anonimleştirme düzeyi (ör. aile hesabı bağı) hukuk ekibince onaylanmalı.
- Çıktı dosyalarının fiziksel silinmesi `storage-cleanup` zamanlamasına bağlıdır (kuyruğa alınıyor; sağlık kontrolü birikimi izliyor).
- İmzalı indirme bağlantısının 60 sn'lik taşıyıcı penceresi (Faz 12).
- Reddedilen yazma metriği veritabanında değil API loglarında.

## Rollback

Yeni davranışlar ileri migration ve ayarlarla geri alınabilir: kota (`output_daily_quota`), istemci sürümü (`client_min_build`), grandfather kararı (yeni karar), ürün bayrakları. Legacy veri ve mali kayıtlar silinmez.

## Checkpoint

- Önerilen commit: `release: complete first-year lifecycle and premium outputs` (go-live kapıları kanıtlandığında). Bu çalışma için ara commit: `feat(phase-13): legacy policy, release health, erasure fix and hardening`.
- Release tag önerisi (kapılar kapanınca): `first-year-lifecycle-v1`.

## İnceleme sonrası düzeltmeler (2026-10-02)

`CLAUDE-REPORT.MD` incelemesi ve ürün sahibinin P-1…P-13 kararları (GELISTIRME.MD "Karar kaydı") doğrultusunda yapıldı. Her biri ayrı bir commit'tir.

| Migration / değişiklik | Konu |
|---|---|
| `20261002000100_parent_only_extension_requests.sql` | Uzatma talebini yalnız ebeveyn açar (P-6) |
| `20261002000200_parent_authority.sql` | Yönetici yalnız anne/baba; ebeveyn korunur; tek ebeveyn önce bebekleri siler (P-3/P-5/P-8/P-9/P-10) |
| `20261002000300_output_cutoff.sql` | Resmî çıktı efektif kapanışta kesilir; kitap aynı sınırı kullanır (P-1) |
| `20261002000400_subscription_read_only.sql` | Abonelik bitince arşiv salt okunur (P-2) |
| `book-artifact-finalize` + istemci tekrar denemesi | Kitap yayını tekrar çağrılabilir |
| `20261002000500_media_date_guard.sql` | Medya çekim tarihi kuralı + rapor |
| Rotalar `/babies/:babyId/...` | Kitap/Film/Arşiv/üye bebek kapsamlı; formlar bebeği sabitler |
| `20261002000600_parent_only_downloads.sql` | Çıktıları yalnız Anne/Baba indirir (P-12/P-13) |
| `20261002000700_output_person_names.sql` | "Esra Teyzesi" biçimi üç üründe (P-11) |
| CI / Dockerfile | Edge job; Deno 2.9.7 sabit; worker imajı `deno.lock` ile |
| `20261002000800_release_health_demo_accounts.sql` | Demo hesap sağlık kontrolü |

- **Doğrulama (yerel, geçici PostgreSQL 16.10 / Deno 2.9.7):** `run_db_tests.sh` 1078 doğrulama, `flutter test` 175, `flutter analyze` ve `dart format` temiz, Edge `deno check` 7/7 ve `deno test` 16/16, worker birim testleri 12/12.
- **Doğrulanmayan:** Worker entegrasyon testleri (ffmpeg / Chrome), Docker imaj derlemesi, gerçek Storage kesintisiyle kitap yayını, mağaza sandbox. Bunlar CI veya ortamda doğrulanacak.
