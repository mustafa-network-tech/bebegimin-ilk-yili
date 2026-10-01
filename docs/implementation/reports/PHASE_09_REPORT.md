# Faz 09 Sonuç Raporu

- **Durum:** COMPLETE (2026-10-01)
- **Başlangıç commit'i:** `6badb6e`
- **Bitiş commit'i:** `feat: gate and integrate official book artifacts` (bu raporla aynı commit)
- **Eklenen migration:** `supabase/migrations/20261001000100_book_artifacts.sql`
- **Yeni Edge Function:** `supabase/functions/book-artifact-finalize`
- **Operasyon belgesi:** `docs/operations/book-artifacts-setup.md`

## Değişen dosyalar

- Veritabanı: `supabase/migrations/20261001000100_book_artifacts.sql`, `supabase/tests/99_book_artifacts_test.sql` (yeni), `supabase/tests/50_storage_books_test.sql` (kitap bölümü yeni kurala göre güncellendi)
- Edge: `supabase/functions/book-artifact-finalize/index.ts`, `supabase/functions/_shared/book_artifact.ts`, `supabase/functions/tests/book_artifact.test.ts`, `supabase/config.toml`
- Flutter: `lib/features/book/domain/book_snapshot.dart` (yeni), `lib/features/book/data/book_publisher.dart` (yeni), `lib/features/book/presentation/book_gate.dart` (yeni), `book_models.dart`, `book_repository.dart`, `book_generator.dart`, `book_providers.dart`, `book_generation.dart`, `book_home_screen.dart`, `lib/app/router.dart`, `lib/core/errors/app_exception.dart`, `lib/core/storage/signed_urls.dart`, `pubspec.yaml` (`crypto` doğrudan bağımlılık oldu; kilit dosyasında sürüm değişmedi)
- Testler: `test/book/book_snapshot_test.dart`, `test/book/book_gate_test.dart`
- Belgeler: `docs/operations/book-artifacts-setup.md`, `README.md`, `PHASE_STATUS.md`

## Korunan sözleşmeler

- `BookComposer`, `BookRenderResolver`, `BookPdfBuilder` ve editör davranışı değiştirilmedi. Bölüm planı, sıralama, gizleme, özel sayfa, kapak, başlık/not/açıklama ve üç format (A4, 21×21, 30×30) aynen çalışır.
- Faz 8 snapshot / job / lease / artifact / download sözleşmesi gevşetilmedi. Kitap protokolü aynı tabloları ve aynı `output_artifact_verify` / `output_artifact_publish` adımlarını kullanır. `request_output_job` ve sunucu worker API'si değişmedi.
- Kaynak arşiv yazılmaz. Düzenleme yalnız `book_projects` / `book_pages` / `book_items` yapılandırmasına dokunur. LOCKED kilidi (Faz 3) aynen geçerlidir.
- Tarihsel migration'lar düzenlenmedi. Tüm değişiklik ileri migration ile yapıldı.

## Kabul kriterleri ve kanıtları

| Kriter | Kanıt |
|---|---|
| Mevcut kitap yeteneklerinde regresyon yok | `book_composer_test` (11) ve `book_pdf_test` (5) değişmeden geçti. `book_snapshot_test`, aynı arşivin canlı kaynaktan ve mühürlü snapshot + manifest'ten çözülen hallerinin kitap motorunda **birebir aynı** çıktı verdiğini doğrular: bölümler, "Bir Yaşındayım", yazarlar, mektup imzaları, fotoğraflar, kapak, istatistik. |
| Kitap yalnız LOCKED ve satın alınmış bebekte kullanılabilir | SQL 50: ACTIVE profilde proje okuma/oluşturma, `books` bucket'ına yükleme, `register_book_export`, `book_exports`, `book_render_start` ve sürüm listesi reddi. SQL 99: abonelik yok → `subscription_required`, entitlement yok → `entitlement_required`, kardeş bebek → kendi satın alımı gerekir, Family Member → `not_parent`, yabancı → bulunamadı. Flutter: `book_gate_test`. |
| Resmî PDF sürümlü, checksum'lı ve yeniden indirilebilir artifact | SQL 99: snapshot + manifest checksum'ları, lease, staging dışı yükleme reddi, başka ebeveynin doğrulayamaması, yayın sonrası `book_exports` satırının artifact'a bağlanması (manifest'teki format), sürüm artışı, `request_output_download` ile indirme, abonelik kapanınca dosyanın korunup indirmenin kapanması. Edge: sunucu tarafı SHA-256 ve PDF kontrolü (`book_artifact.test.ts`). |

## Uygulananlar

### Kitap kapısı

- `book_access_block(baby, user)`: önce üyelik, sonra lifecycle (`premium_requires_locked`), ardından Faz 8 `output_request_block` (ebeveyn, abonelik, `first_year_book` entitlement). Tek kural kaynağıdır.
- Kitap tablolarının RLS'i bu kurala bağlandı (`book_config_access`). Eski `create_book` / `view_album` politikaları kaldırıldı.
- Proje silme kullanıcılardan alındı. `book_exports` istemciye tamamen kapalı. `books` bucket'ının okuma / yükleme / silme politikaları kaldırıldı.
- Insert guard, istemcinin `current_version` / `legacy_status` sahteciliğini engeller (eski şemada insert sırasında sürüm sahtelenebiliyordu).

### Resmî PDF protokolü (doğrulanmış istemci render'ı)

Plan, istemci motoru korunacaksa "doğrulanmış artifact upload protokolü" seçeneğine izin veriyor. Bu seçenek uygulandı:

1. `book_render_start`: snapshot mühürlenir, yapılandırma `book_render_manifests` içine dondurulur (sunucuda hesaplanan checksum, değiştirilemez), job `book-client:<user>` adına 15 dakikalık lease ile başlatılır. Idempotent anahtar, aynı ebeveynin eski denemesinin `superseded` iptali ve başka ebeveynin canlı lease'inde `book_render_in_progress` reddi vardır.
2. Uygulama `book_render_payload` ile snapshot + manifest metnini alır, iki checksum'ı doğrular ve **yalnız bunlardan** baskı kalitesinde render eder (`BookRenderInputs.fromPayload`). Yazar adı/yakınlığı snapshot'tan gelir. Resmî render'da inmeyen tek bir fotoğraf render'ı durdurur.
3. `book_artifact_begin`: artifact satırı yüklemeden önce oluşur. Storage INSERT politikası yalnız lease sahibinin o staging yoluna izin verir.
4. `book-artifact-finalize`: lease ve kitap kapısını kullanıcının JWT'siyle yeniden denetler. Dosyayı sunucuda indirip `%PDF-` / `%%EOF` kontrolü yapar, SHA-256'yı kendisi hesaplar. Ardından `output_artifact_verify` → taşıma → `book_artifact_publish`. Bu son adım artifact'ı `ready` yapar, sürümü artırır ve `book_exports` satırını aynı transaction'da yazar.
5. Hata durumunda `book_render_fail` çalışır (retry, aynı snapshot ve manifest ile). Uyuşmayan hash veya eksik nesne artifact'ı quarantine eder.

`register_book_export` imzası korunarak her çağrıda `book_export_requires_artifact` ile reddeder. `book_exports` guard'ı artifact'sız, publish adımı dışında veya artifact ile uyuşmayan satırı kabul etmez. Export satırları değiştirilemez.

### Legacy veri

- Migration anındaki tüm proje ve export'lar `legacy_quarantined` olarak işaretlendi. Gizlendiler, silinmezler, otomatik entitlement verilmez.
- LOCKED + satın alma sonrası legacy yapılandırma yeniden kullanılabilir. Resmî PDF yalnız yeni snapshot'tan üretilir; sürüm numarası legacy sürümlerin üzerinden devam eder.
- `admin_legacy_book_report()` (Super Admin, rate-limit'li) proje, legacy export ve resmî export sayılarını raporlar.
- Yasal silme listesi (`baby_storage_objects`) yalnız legacy dosyaları listeler. Artifact dosyaları output pipeline'a aittir.

### Flutter

- `/book` rotaları `BookRouteGate` ile sunucu durumuna bağlandı (`book_access_state`). ACTIVE, satın alınmamış, abonelik yok ve Family Member durumları ayrı ekranlarla karşılanıyor. Editör rotaları yalnız ebeveyn içindir.
- Ana ekran resmî sürümleri `book_versions` üzerinden listeler. İndirme `output-download` ile yapılır ve baytlar artifact SHA-256'sıyla doğrulanır. Sürüm silme kaldırıldı.
- "Önizle" canlı (salt okunur) arşivden taslak üretir; resmî artifact sayılmaz.

## Çalıştırılan testler ve sonuçları

- `supabase/tests/run_db_tests.sh` (PostgreSQL 16.10): **✓ all database tests passed**. Toplam 784 doğrulama; `99_book_artifacts_test.sql` içinde 94, güncellenen `50_storage_books_test.sql` kitap bölümünde 12. Faz 8 migration reapply ve dört yarış testi dahil.
- `flutter analyze`: No issues found.
- `flutter test`: 135/135 (14 yeni: snapshot 7, gate 7).
- `deno check` (`book-artifact-finalize`, `output-download`, `storage-cleanup`): başarılı.
- `deno test supabase/functions/tests/`: 14/14 (5 yeni).
- `deno fmt`: yeni Edge dosyaları formatlı. Dizindeki diğer, Faz 9 öncesi dosyalar değiştirilmedi.

## Çalıştırılamayan testler / neden

- `book-artifact-finalize` uçtan uca (gerçek Supabase Storage + Edge runtime) çalıştırılmadı; yerelde Supabase/Docker yok. SQL tarafı servis rolü adımları (verify → taşıma → publish) testte birebir simüle edildi. Saf yardımcılar birim testli, fonksiyon tip kontrolünden geçti.
- Cihazda gerçek fotoğraflarla uçtan uca kitap üretimi (iOS/Android) bu ortamda yapılmadı.

## Güvenlik ve veri migration notları

- Uygulamanın checksum beyanına tek başına güvenilmez; hash sunucuda yeniden hesaplanır.
- Sunucu, PDF içeriğinin snapshot'tan üretildiğini kriptografik olarak kanıtlayamaz (render istemcidedir). Lisanslı ebeveyn kendi satın aldığı kitabı üretir. Girdi bütünlüğü checksum'la, yükleme yolu politika ile, sonuç SHA-256 ile korunur. Sunucu tarafı render istenirse aynı manifest + snapshot ile `request_output_job` / worker yolu kullanılabilir.
- Mevcut veriler silinmedi. Backfill yalnız `legacy_status` işaretlemesidir.

## Rollback adımları

- `book_renderer` bayrağını kapatın: yeni render durur, veri ve indirme korunur. `output_worker` kapatılırsa render da durur. Satış için `premium_storefront`.
- Geri dönüş ileri migration ile yapılır. Manifest, job, artifact ve export kayıtları denetim izidir.

## Bilinen riskler

- `run_daily_jobs` 365. günde (profil hâlâ ACTIVE iken) "kitap oluşturulmaya hazır" bildirimi gönderiyor. Bildirim `/book`'a götürür ve kapı "İlk yıl devam ediyor" gösterir; veri sızıntısı yok ama metin yanıltıcı. Bildirim metni / zamanlaması Faz 13'te veya ayrı bir düzeltmede LOCKED + satın alma anına taşınmalı.
- Snapshot kullanıcıya özel favorileri içermez. Kapak seçilmemişse otomatik kapak önerisi canlı önizlemeden farklı olabilir; editörde seçilen kapak her zaman korunur.
- `PremiumRouteGate` (Film/HTML yer tutucusu) koddan kaldırılmadı; Faz 10–11 kendi kapılarını eklerken yeniden değerlendirilmeli.
- Eski uygulama sürümleri kitap yayınında `book_export_requires_artifact` hatası alır (bilinçli).

## Faz 10 giriş koşulları

- Faz 9 `COMPLETE`. Ortak snapshot / job / artifact sözleşmesi ve `book_access_block` kalıbı hazır.
- Film, sunucu tarafı worker ile üretilecek; istemci render protokolü Film için kullanılmamalıdır.
