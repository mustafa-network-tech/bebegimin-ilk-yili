# Çıktı worker'ı kurulumu (Film ve Offline HTML)

Bu belge `workers/output` konteynerinin operasyon sözleşmesidir. Aynı worker iki ürünü üretir:

- Faz 10 İlk Yıl Filmi (MP4): bkz. [ADR 0004](../implementation/ADR/0004-film-render-infrastructure.md).
- Faz 11 Offline HTML arşivi (ZIP): bkz. [ADR 0005](../implementation/ADR/0005-offline-html-archive.md).

Ortak job / artifact hattı için bkz. [output-pipeline-setup.md](output-pipeline-setup.md).

## Film akışı

1. Ebeveyn uygulamada film ayarlarını düzenler (`film_update_settings`) ve sunucunun süre tahminini görür (`film_plan`).
2. `film_request_render` snapshot'ı mühürler ve sahne manifest'ini hesaplayıp `film_render_manifests` içine dondurur. Manifest 600 saniyeyi aşıyorsa istek `film_too_long`, içerik yoksa `film_empty` ile reddedilir. İş kuyruğa girer.
3. Film worker `output_claim_jobs(worker, ['first_year_film'])` ile işi alır, `film_job_manifest` ile manifest'i okur ve checksum'ı doğrular.
4. Worker kaynak medyayı `baby-media` bucket'ından indirir ve `ffprobe` ile sınıflandırır. Bozuk / eksik / desteklenmeyen medya `film_job_media_error` ile işi tekrar denenmeden bitirir; uygulama "bu medyayı çıkar" seçeneği gösterir.
5. Her sahne için frame sayısı sabit bir video parçası ve örnek sayısı tam bir WAV üretilir. Parçalar birleştirilir ve tek AAC kodlamasıyla MP4 yapılır. İlerleme `film_job_progress_update` ile raporlanır.
6. Final dosya `ffprobe` ile ölçülür. `output_artifact_begin` → staging yükleme → yeniden okuyup hash → `output_artifact_verify` → final yola taşıma → `film_artifact_publish` sırası izlenir. Son adım süreyi (≤ 600 000 ms ve manifest'ten en çok 2 sn sapma), çözünürlüğü ve codec'leri doğrular, metaveriyi kaydeder ve artifact'ı `ready` yapar.
7. İndirme Faz 8'deki `output-download` ile yapılır. Uygulama baytları artifact SHA-256'sıyla doğrular.

## Offline HTML arşivi akışı

1. Ebeveyn `html_request_render` ile ister. Snapshot mühürlenir. Aynı snapshot için hazır arşiv varsa o döner (arşiv değişmez, ikinci kez üretilmez); bekleyen / çalışan aynı iş varsa ona katılınır.
2. Worker `output_claim_jobs(worker, ['first_year_html'])` ile işi alır, `html_job_payload` ile mühürlü snapshot metnini okur ve checksum'ı doğrular.
3. Medya `baby-media`'dan indirilip yeniden kodlanır: fotoğraf 2048 px + 480 px küçük resim, video H.264/AAC ≤ 1280 px + poster. Tüm metaveri (EXIF / GPS) silinir. Bulunamayan veya dönüştürülemeyen medya paketi bozmaz; sayfada not gösterilir ve `manifest.json` içinde `skipped` olarak listelenir.
4. Statik sayfalar (CSP'li, tüm kullanıcı metni escape edilmiş), CSS / JS / font ve `benioku.txt`, `surum.txt` hazırlanır. `manifest.json` her dosyanın boyutunu, MIME'ını ve SHA-256'sını listeler.
5. Deterministik ZIP (STORE, sabit tarih, tek kök klasör) yazılır. Worker ZIP'i yeniden okuyup giriş listesini ve her dosyanın SHA-256'sını manifest'le karşılaştırır.
6. Artifact protokolü filmle aynıdır. Son adım `html_artifact_publish` dosya sayısını, içerik boyutunu, atlanan medya sayısını ve manifest checksum'ını kaydeder. 2 GB'ı aşan arşiv `bundle_too_large` ile tekrar denenmeden biter.

## Konteyner

```bash
# Repo kökünden (uygulama fontları imaja kopyalanır)
docker build -f workers/output/Dockerfile -t bebegimin-output-worker .
docker run --rm \
  -e SUPABASE_URL=https://<project>.supabase.co \
  -e SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
  -e WORKER_ID=output-1 \
  bebegimin-output-worker
```

| Değişken | Varsayılan | Not |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | — | Zorunlu. Anahtar yalnız worker ortamındadır. |
| `WORKER_PRODUCTS` | `first_year_film,first_year_html` | Bu konteynerin alacağı ürünler (ör. yalnız film için ayrı, güçlü bir makine). |
| `WORKER_ID` | `output-<rastgele>` | `^[A-Za-z0-9._:-]{1,80}$`; loglarda ve lease'te görünür. |
| `POLL_INTERVAL_MS` | `15000` | Kuyruk boşken bekleme süresi. |
| `FFMPEG_PATH`, `FFPROBE_PATH` | `ffmpeg`, `ffprobe` | |
| `FONT_DIR` | `/app/fonts` | `Nunito-Regular.ttf`, `Nunito-Bold.ttf`, `Lora-Regular.ttf` |
| `WORK_DIR` | `/tmp/film` | İş başına geçici klasör; iş bitince silinir. |

Önerilen kaynak: 2 vCPU, 4 GB RAM, 10 GB geçici disk, worker başına tek iş. Daha fazla kapasite için aynı imajdan birden çok konteyner çalıştırın; işleri lease ile güvenle paylaşırlar. SIGTERM / SIGINT sonrası worker mevcut işi bitirip durur.

Loglarda yalnız job kimliği, deneme numarası, sonuç ve süre bulunur; URL, dosya yolu veya kullanıcı içeriği yazılmaz.

## Yerel test

```bash
cd workers/output
FFMPEG_PATH=ffmpeg FFPROBE_PATH=ffprobe CHROME_PATH=/path/to/chrome deno task test
```

- Film entegrasyon testi gerçek bir film üretir (dikey/yatay fotoğraf, sesli dikey video, kaynaktan kısa sessiz klip, uzun metin kartı). Ardından süre, çözünürlük ve codec'leri doğrular.
- Arşiv entegrasyon testi gerçek medyayla (bozuk ve eksik dosyalar dahil) bir ZIP üretir ve manifest'le birebir doğrular. `CHROME_PATH` verilmişse paketi açıp headless Chrome'da **ağ kapalıyken** sayfaları gezer: `file:` dışındaki her istek, konsol hatası, yüklenmeyen görsel, oynamayan video veya çalışan bir script enjeksiyonu test hatasıdır. `ARCHIVE_SCREENSHOT_DIR` verilirse sayfaların ekran görüntüleri kaydedilir.
- CI'daki `output-worker` işi aynı testleri Ubuntu ffmpeg ve Google Chrome ile çalıştırır.

## Kill switch ve geri alma

```sql
-- Yeni film isteklerini durdur (kuyruktaki işler ve hazır filmler korunur)
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'film_renderer';
-- Yeni arşiv isteklerini durdur
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'html_renderer';
-- Tüm çıktı tüketimini durdur (kitap / film / HTML)
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'output_worker';
```

Worker konteynerini durdurmak da güvenlidir: yarım kalan işin lease'i dolunca iş backoff ile kuyruğa döner. Satışı kapatmak için Faz 7'deki `premium_storefront` kullanılır.

## Gözlemleme ve alarm önerileri

- `admin_output_metrics()` → `first_year_film`: iş durumları, retry, başarılı deneme süresi ortalaması / p95, hata kodları, artifact boyutu.
- Film hata kodları: `media_corrupt`, `media_missing`, `media_unsupported` (tekrar denenmez); `transcode_failed`, `upload_failed`, `render_failed`, `probe_failed` (backoff ile tekrar); `duration_exceeded`, `duration_mismatch`, `profile_mismatch`, `manifest_missing`, `manifest_invalid` (tekrar denenmez; yazılım hatası işaretidir).
- Alarm: `duration_*` / `profile_mismatch` görülmesi, `queued` iş yaşının 30 dakikayı aşması (worker kapalı olabilir), `poison` oranının yükselmesi.
- Arşiv hata kodları: `bundle_too_large` (tekrar denenmez), `archive_mismatch`, `transcode_failed`, `upload_failed`, `render_failed` (backoff ile tekrar), `snapshot_invalid` (tekrar denenmez). Atlanan medya hata değildir; `html_artifact_metadata.skipped_media` ile izlenir.
