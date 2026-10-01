# Faz 11 Sonuç Raporu

- **Durum:** COMPLETE (2026-10-01)
- **Başlangıç commit'i:** `0e5017a`
- **Bitiş commit'i:** Faz 11 + Faz 12 ortak commit'i (kullanıcı isteğiyle birlikte commit edildi)
- **ADR:** `docs/implementation/ADR/0005-offline-html-archive.md` (giriş koşulu: tarayıcı / işletim sistemi matrisi)
- **Eklenen migration:** `supabase/migrations/20261001000300_html_archive.sql`
- **Worker:** `workers/film` → `workers/output` (film + offline arşiv, `WORKER_PRODUCTS`)
- **Operasyon belgesi:** `docs/operations/output-worker-setup.md` (önceki `film-worker-setup.md`)

## Kararlar

Bu fazda kullanıcıya sorulacak bir altyapı kararı yoktu; ADR 0005'te kayıtlı:

- Arşiv, Faz 10'un Deno + ffmpeg worker'ında üretilir; ek barındırma gerekmez.
- Sayfalar sunucuda statik HTML olarak üretilir. `file://` altında `fetch` ve service worker'a güvenilmez. JS yalnız isteğe bağlı görsel büyütmedir.
- Masaüstü Chrome / Edge / Firefox / Safari tam destek, iOS / Android en iyi çaba.

## Değişen dosyalar

- Veritabanı: `20261001000300_html_archive.sql`, `supabase/tests/99h_html_archive_test.sql`
- Worker: `workers/output/src/html/{zip,paths,site,build}.ts` (yeni), `src/worker.ts` (ürüne göre dağıtım, ortak artifact protokolü), `src/main.ts` (`WORKER_PRODUCTS`), `Dockerfile` (Lora fontu), `deno.json` (`puppeteer-core`, test izinleri), `tests/html_unit.test.ts`, `tests/html_archive.integration.test.ts`, `tests/fixtures.ts`
- Flutter: `lib/features/archive/**` (yeni), `lib/app/router.dart`, `lib/core/errors/app_exception.dart`, `lib/features/premium/presentation/premium_store_screen.dart` ("Arşivi aç"; artık kullanılmayan "Hazırlanıyor" dalı kaldırıldı)
- Testler: `test/archive/archive_screen_test.dart`
- CI / belgeler: `.github/workflows/ci.yml` (`output-worker` işi, `CHROME_PATH`), `.env.example`, ADR 0005, `docs/operations/output-worker-setup.md`, `README.md`, `PHASE_STATUS.md`

## Kabul kriterleri ve kanıtları

| Kriter | Kanıt |
|---|---|
| Paket gerçekten offline çalışır | Worker entegrasyon testi gerçek bir arşivi diske çıkarır ve headless Chrome'da `setOfflineMode(true)` ile açar. İçindekiler, bölüm, büyütme, video ve mektup sayfaları çalışır; görseller yüklenir, video oynar, konsol hatası yoktur. Ekran görüntüleri gözle kontrol edildi. |
| Artifact yeniden indirilebilir ZIP | Faz 8 artifact protokolü (staging → hash → doğrulama → taşıma → yayın). `request_output_download` her seferinde aynı SHA-256'yı döndürür (SQL 99h). Aynı snapshot için ikinci istek hazır arşivi döndürür; yeniden üretilmez. |
| Harici ağ ve süresi dolan URL bağımlılığı yok | Tarayıcı testinde `file:` dışında istek sıfır. Statik testte HTML / CSS / JS içinde uzak referans yok. Sayfalarda CSP ve `no-referrer`. Medya pakete kopyalanır; signed URL gömülmez. |

### Plan testleri

| Plan maddesi | Test |
|---|---|
| Ağ kapalıyken açılır; metin, görsel, video çalışır | `html_archive.integration.test.ts` (Chrome, offline) |
| Signed URL süresinin dolması paketi etkilemez | Paket yalnız göreli `media/…` yolları içerir; statik tarama + çevrimdışı açılış |
| Türkçe karakter, uzun dosya adı, Unicode | Türkçe ad / metin / tarih sayfalarda (ekran görüntüsü). Kök klasör `slug` ile ASCII (`cagla-ilk-yil-arsivi`). Dosya adları kullanıcıdan gelmez; ZIP adları UTF-8 bayraklı. |
| XSS / path traversal | `<script>` ve `<img onerror>` düz metin gösterilir, tarayıcıda diyalog açılmaz, sayfada tek script `app.js`'tir. `..`, mutlak yol, ters bölü, büyük harf, `.exe` / `.sh` / `.svg` reddedilir; ZIP yazıcısı da güvensiz yolu reddeder. |
| ZIP checksum ve giriş listesi manifestle eşleşir | `verifyArchive` (worker her yayında çalıştırır) + test: ZIP girişleri = manifest + `manifest.json`, her giriş SHA-256 eşleşir; aynı girdi aynı ZIP baytlarını üretir. |
| Paket içinden içerik eklenemez / değiştirilemez; re-download aynı sha256 | Sayfalarda form / input / textarea / iframe / button yok, sunucu çağrısı yok. Artifact değiştirilemez; aynı snapshot yeniden üretilmez; indirme SHA-256'sı sabit (SQL 99h). |
| ACTIVE / entitlement yok / member create reddi | SQL 99h: `premium_requires_locked`, `subscription_required`, `entitlement_required`, `not_parent`, yabancı → bulunamadı. Flutter: kapı testleri. |

## Uygulananlar

### Veritabanı

- `html_access_block` / `html_access_state`, `html_request_render` (idempotent; aynı snapshot → hazır arşiv veya bekleyen iş; farklı snapshot için bekleyen iş `superseded`; çalışan iş `html_render_in_progress`).
- `html_state`: son iş, ilerleme, hazır arşiv, dosya sayısı, atlanan medya, indirme durumu.
- Worker RPC'leri (yalnız service role): `html_job_payload`, `output_job_progress_update` (genel), `html_artifact_publish` (+ `html_artifact_metadata`, değiştirilemez).
- Kill switch: `html_renderer`.

### Worker

- `zip.ts`: deterministik STORE ZIP yazıcı / okuyucu (CRC-32, sabit tarih, UTF-8, akışlı).
- `paths.ts`: yol / uzantı izin listesi, MIME, Türkçe `slug`.
- `site.ts`: statik sayfalar (filmle aynı bölümler), escape, CSP, CSS, büyütme JS'i, `benioku.txt`.
- `build.ts`: snapshot checksum → medya dönüştürme (metaveri silinir, hatalı medya atlanır) → sayfalar → manifest → ZIP → manifest'e karşı doğrulama; 2 GB sınırı.
- `worker.ts`: ürüne göre dağıtım; film ve arşiv aynı artifact yükleme protokolünü paylaşır.

### Flutter

- `/archive` ekranı: arşivi hazırla / güncel kopyayı kontrol et, ilerleme (yoklama), hata, hazır arşiv (boyut, dosya sayısı, atlanan medya notu), doğrulamalı indirme + paylaş / kaydet, açılış yönergesi. Family Member yalnız hazır arşivi görür.
- Mağaza: "Arşivi aç".

## Çalıştırılan testler ve sonuçları

- `supabase/tests/run_db_tests.sh` (PostgreSQL 16.10): **✓ all database tests passed**. Toplam 893 doğrulama; `99h_html_archive_test.sql` içinde 38.
- `flutter analyze`: No issues found. `flutter test`: 151/151 (7 yeni arşiv testi).
- Worker: `deno fmt --check`, `deno lint`, `deno check` temiz. `deno task test` 13/13: ffmpeg 9.0.2 ile gerçek film ve gerçek arşiv, Chrome ile çevrimdışı açılış testi dahil.
- Önceki push'un CI'ı (Faz 10) yeşildi; `film-worker` işi Ubuntu ffmpeg ile geçti.

## Çalıştırılamayan testler / neden

- Worker'ın gerçek Supabase'e bağlı uçtan uca akışı ve Docker imajı yerelde çalıştırılmadı (Supabase / Docker yok). RPC sözleşmesi SQL testinde, paket üretimi ve açılışı entegrasyon testinde doğrulandı.
- iOS / Android'de dosyadan açılış manuel test edilmedi (ADR 0005'te "en iyi çaba" olarak sınıflandı).
- Firefox ve Safari'de otomatik test yok; otomatik doğrulama Chromium tabanlı.

## Güvenlik ve veri notları

- Pakete yalnız mühürlü snapshot içeriği girer (mühürlü zaman kapsülleri ve kişisel favoriler hariç). Fotoğraf ve videoların EXIF / GPS metaverisi silinir.
- Service role anahtarı yalnız worker'da. Uygulama yalnız istek, durum ve indirme RPC'lerini görür.

## Rollback adımları

- `html_renderer` (yeni istek yok), `output_worker` (tüm tüketim), `premium_storefront` (satış). Worker'ı yalnız filmle sınırlamak için `WORKER_PRODUCTS=first_year_film`.
- Geri dönüş ileri migration ile yapılır; artifact ve metaveri denetim izidir.

## Bilinen riskler

- Çok büyük arşivler (ör. çok sayıda uzun video) 2 GB sınırını aşabilir ve `bundle_too_large` ile biter. Video bitrate'i düşürme veya parçalı paket gerekirse sonraki bir iterasyonda ele alınmalı.
- Worker dosyaları hash'lemek için belleğe okur (bucket sınırıyla sınırlı); 4 GB RAM önerisi bu yüzdendir.
- Faz 9'dan kalan 365. gün bildirim metni sorunu sürüyor.

## Faz 12 giriş koşulları

- Faz 11 `COMPLETE`. Üç ürün de ortak artifact ve indirme sözleşmesini kullanıyor. Faz 12, Family Member indirmesini ürün bazlı ebeveyn iznine (`download_final_artifact`) bağlayacak; bugün indirme `view_album` iznine dayanıyor.
