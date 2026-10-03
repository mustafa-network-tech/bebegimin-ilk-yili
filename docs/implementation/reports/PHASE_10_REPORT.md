# Faz 10 Sonuç Raporu

- **Durum:** COMPLETE (2026-10-01)
- **Başlangıç commit'i:** `11647aa`
- **Bitiş commit'i:** `feat: add ten-minute first-year film artifacts` (bu raporla aynı commit)
- **ADR:** `docs/implementation/ADR/0004-film-render-infrastructure.md` (giriş koşulu)
- **Eklenen migration:** `supabase/migrations/20261001000200_film_artifacts.sql`
- **Yeni worker:** `workers/film` (Deno + ffmpeg, Docker)
- **Operasyon belgesi:** `docs/operations/film-worker-setup.md`

> **Not (2026-10-02):** Bu rapordaki `workers/film` ve `film-worker-setup.md`, Faz 11'de `workers/output` ve `docs/operations/output-worker-setup.md` olarak genelleştirildi. Rapor tarihsel kayıt olarak değiştirilmedi.

## Kullanıcı kararları

- Film altyapısı: kendi worker konteynerimiz (Deno + ffmpeg). Medya üçüncü tarafa gönderilmez.
- Müzik: ilk sürümde yok. Video sesi normalize edilerek kullanılır; lisans riski yok.

## Değişen dosyalar

- Veritabanı: `20261001000200_film_artifacts.sql`, `supabase/tests/99f_film_artifacts_test.sql`
- Worker: `workers/film/{Dockerfile,deno.json,src/*,tests/*}`
- Flutter: `lib/features/film/**` (yeni), `lib/core/storage/artifact_download.dart` (kitap ve filmin ortak doğrulamalı indirmesi), `lib/features/book/data/book_repository.dart` (ortak indirmeyi kullanır), `lib/features/premium/presentation/premium_store_screen.dart`, `lib/app/router.dart`, `lib/core/errors/app_exception.dart`
- Testler: `test/film/film_screen_test.dart`, `test/premium/premium_store_test.dart`
- CI / belgeler: `.github/workflows/ci.yml` (`film-worker` işi), `.env.example`, ADR 0004, `docs/operations/film-worker-setup.md`, `README.md`, `PHASE_STATUS.md`

## Kabul kriterleri ve kanıtları

| Kriter | Kanıt |
|---|---|
| Film en fazla 10 dakika ve indirilebilir MP4 artifact | `film_render_manifests.total_duration_ms` ≤ 600 000 (check + seal). `film_artifact_publish` probe süresi 600 000 ms'yi aşan dosyayı yayınlamaz, quarantine eder, işi tekrar denemeden bitirir (SQL 99f). İndirme `output-download` ile, SHA-256 doğrulamalı. |
| Üretim server-authoritative job ile izlenir | Final MP4 yalnız worker'da üretilir. Kuyruk, lease, heartbeat, retry, poison ve artifact adımları Faz 8 RPC'leri. İlerleme `film_job_progress`, durum `film_state`. Uygulama render etmez. |
| Kaynak snapshot sürümü artifact'ta belli | Artifact yolu `<bebek>/first_year_film/<snapshot>/v<n>/…`. Manifest `snapshot_id` + `snapshot_checksum` taşır. `film_artifact_metadata` manifest checksum'ını saklar. |

### Plan testleri

| Plan maddesi | Test |
|---|---|
| 600 sn kabul, üstü reddedilir / kesilmez; kullanıcıdan düzenleme istenir | SQL: en kısa süreler 600 sn'yi aşınca `over_limit` + `excess_ms`, render `film_too_long`; önerilen seçim sığar ve render edilir; probe > 600 sn yayınlanmaz. Flutter: render düğmesi kapalı, "Önerilen seçimi uygula". |
| Az içerikte süre içerikle orantılı, dolgu yok | SQL: 5 içerik → tam olarak 42,5 sn; videolar kapatılınca 32 sn. |
| Temel süre sığmazsa sıkıştırma | SQL: 200+ fotoğraf → temel > 600 sn, sonuç 595–600 sn arası, ret yok. |
| Bozuk / desteklenmeyen video güvenli hata | SQL: `media_corrupt` → poison + sorunlu medya kimliği; uygulamada tek dokunuşla çıkarma. Worker: bozuk dosya `media_corrupt`, ses akışı yok / görüntü yok sınıflandırması. |
| Dikey / yatay medya tutarlı çıktı | Worker entegrasyon testi: dikey ve yatay fotoğraf, dikey video → 1920×1080; kareler gözle kontrol edildi (bulanık arka plan, ortalı içerik, altyazı kutusu). |
| Retry çift artifact üretmez / açık versioning | Retry aynı manifest checksum'ını kullanır (SQL). Her iş yalnız bir `ready` artifact üretir; başarısız denemeler abandon / quarantine edilir; sürüm yolda açıktır. |
| ACTIVE / entitlement yok / member render reddi | SQL: `premium_requires_locked`, `subscription_required`, `entitlement_required`, `not_parent`, yabancı → bulunamadı. Flutter: gate testleri. |
| Final checksum ve duration probe doğrulanır | Worker staging nesnesini yeniden indirip hash'ler → `output_artifact_verify`. Probe süresi / çözünürlük / codec → `film_artifact_publish` (`duration_exceeded`, `duration_mismatch`, `profile_mismatch`). |

## Uygulananlar

### Sahne planı ve süre bütçesi (SQL, tek algoritma)

- `film_candidates`: snapshot'tan anı, ilk, fotoğraf, video ve mektup sahneleri. Kitaptaki "kitaba ekle" işareti seçim bayrağı olarak kullanılır; kullanıcı ayarlarındaki türler ve hariç tutulan kimlikler uygulanır.
- `film_scene_rows`: başlık → bölüm kartları (Seni beklerken, Doğduğun gün, 1.–12. Ay, Bir yaşında, Ailemden sana) → zaman sırasına göre sahneler → kapanış.
- `film_compose`: temel / en kısa süreler. Temel toplam ≤ 600 sn ise temel; değilse orantılı sıkıştırma (`floor` ile toplam asla 600 sn'yi aşmaz); en kısa toplam > 600 sn ise `over_limit`. Video klibi kaynaktan en çok 8 sn alınır.
- `film_suggest_settings`: bölüm başına en önemli k fotoğrafı (ve k/4 videoyu) tutan, sığan en büyük k'yi ikili aramayla bulur. Gerekirse metin sahnelerini, sonra mektupları, sonra videoları kapatır. Kaydetmez; kullanıcı uygular.

### Render isteği ve worker sözleşmesi

- `film_request_render`: kapı + `film_renderer` bayrağı → snapshot → manifest → `film_empty` / `film_too_long` preflight → aynı manifest bekleyen veya çalışan bir işte varsa ona katılır; eski ayarlı bekleyen iş `superseded`; çalışan farklı iş varsa `film_render_in_progress`.
- Worker RPC'leri (yalnız service role): `film_job_manifest`, `film_job_progress_update`, `film_job_media_error`, `film_artifact_publish`.

### Worker (`workers/film`)

- Manifest checksum ve yapı doğrulaması, toplam ≤ 600 sn.
- Kümülatif frame planı: film tam olarak `round(toplam × fps)` frame'dir. Her sahne frame sayısı sabit bir H.264 parçası ve örnek sayısı tam bir PCM WAV olur. Concat (stream copy) ve tek AAC kodlaması, sahne sayısından bağımsız olarak süre kaymasını önler.
- Fotoğraf / video: bulanık arka plan üzerinde ortalı; kısa klipler son karede durur, döngüye girmez. Video sesi `loudnorm`; fotoğraf ve metin kartları sessiz.
- Metin: emoji ve kontrol karakterleri temizlenir, satırlar sarılır ve sınırlanır; drawtext metni dosyadan okur (`expansion=none`, kaçış sorunu yok).
- Metaveri temizliği (`-map_metadata -1`, bitexact) ve `+faststart`.
- Hata sınıfları ADR 0004'teki gibi. Loglarda yalnız kimlik, sonuç ve süre bulunur.

### Flutter

- `/film` ekranı: sunucu tahmini (süre, içerik sayıları), 10 dakika aşımında uyarı + önerilen seçim, tür anahtarları, hariç tutulanları sıfırlama, "Filmi hazırla", sıra / ilerleme (5 sn'de bir yoklama), hata + "bu medyayı çıkar", hazır film kartı (süre, çözünürlük, boyut), doğrulamalı indirme ve oynatıcı / paylaşım.
- Family Member yalnız hazır filmi görür; üretim ve düzenleme arayüzü yok.
- Mağaza: satın alınmış kitap ve film için "Kitabı aç" / "Filmi aç" eklendi. Bu, Faz 9'da eksik kalan kitap giriş noktasını da kapatır.

## Çalıştırılan testler ve sonuçları

- `supabase/tests/run_db_tests.sh` (PostgreSQL 16.10): **✓ all database tests passed**. Toplam 855 doğrulama; `99f_film_artifacts_test.sql` içinde 71.
- `flutter analyze`: No issues found. `flutter test`: 144/144 (9 yeni film testi; mağaza testleri güncellendi).
- Worker (`workers/film`): `deno fmt --check`, `deno lint`, `deno check` temiz. `deno task test` 7/7 (ffmpeg 9.0.2 ile gerçek render dahil: 1920×1080, H.264/AAC, 30 fps, süre planla ≤ 100 ms içinde).
- `dart format --set-exit-if-changed lib test`: değişiklik yok.

## Çalıştırılamayan testler / neden

- Worker'ın gerçek Supabase'e bağlı uçtan uca akışı (indirme / yükleme / taşıma) çalıştırılmadı; yerelde Supabase yok. RPC sözleşmesi SQL testinde, render entegrasyon testinde doğrulandı.
- Docker imajı bu makinede derlenmedi (Docker yok). CI'daki `film-worker` işi aynı kodu Ubuntu ffmpeg ile test eder.
- Cihazda video oynatıcı ve indirme manuel denenmedi.

## Güvenlik ve veri notları

- Service role anahtarı yalnız worker ortamında. Uygulama render etmez, manifest göremez; yalnız ayar, tahmin, istek ve durum RPC'lerine erişir.
- Manifest, ilerleme ve metaveri tabloları istemciye kapalı. Manifest ve metaveri değiştirilemez.
- Fotoğraf EXIF yönü: uygulama fotoğrafları yüklemeden önce döndürüp sıkıştırdığı için ek işlem yapılmaz. Video yönü ffmpeg'in otomatik döndürmesiyle uygulanır.

## Rollback adımları

- `film_renderer` → yeni istek yok; `output_worker` → tüketim yok; worker konteynerini durdurmak güvenli (lease dolunca iş kuyruğa döner). Satış için `premium_storefront`.
- Geri dönüş ileri migration ile yapılır. Manifest, iş, artifact ve metaveri denetim izidir.

## Bilinen riskler

- Film worker'ı canlıya alınmadan film işleri `queued` bekler. Barındırma ve izleme kurulumu gerekir (bkz. operasyon belgesi).
- Seçim için ayrı bir medya seçici yok; kullanıcı tür anahtarları, önerilen seçim ve "bu medyayı çıkar" ile düzenler. Tek tek fotoğraf seçimi istenirse sonraki bir iterasyonda eklenebilir.
- Faz 9'dan kalan 365. gün bildirim metni sorunu sürüyor (bkz. Faz 9 raporu).

## Faz 11 giriş koşulları

- Faz 10 `COMPLETE`. Ortak snapshot / job / artifact sözleşmesi, ürün kapısı kalıbı ve doğrulamalı indirme (`downloadVerifiedArtifact`) hazır.
