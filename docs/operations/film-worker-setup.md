# İlk Yıl Filmi worker kurulumu

Bu belge Faz 10'da eklenen film üretiminin operasyon sözleşmesidir. Altyapı kararı için bkz. [ADR 0004](../implementation/ADR/0004-film-render-infrastructure.md). Ortak job / artifact hattı için bkz. [output-pipeline-setup.md](output-pipeline-setup.md).

## Akış

1. Ebeveyn uygulamada film ayarlarını düzenler (`film_update_settings`) ve sunucunun süre tahminini görür (`film_plan`).
2. `film_request_render` snapshot'ı mühürler ve sahne manifest'ini hesaplayıp `film_render_manifests` içine dondurur. Manifest 600 saniyeyi aşıyorsa istek `film_too_long`, içerik yoksa `film_empty` ile reddedilir. İş kuyruğa girer.
3. Film worker `output_claim_jobs(worker, ['first_year_film'])` ile işi alır, `film_job_manifest` ile manifest'i okur ve checksum'ı doğrular.
4. Worker kaynak medyayı `baby-media` bucket'ından indirir ve `ffprobe` ile sınıflandırır. Bozuk / eksik / desteklenmeyen medya `film_job_media_error` ile işi tekrar denenmeden bitirir; uygulama "bu medyayı çıkar" seçeneği gösterir.
5. Her sahne için frame sayısı sabit bir video parçası ve örnek sayısı tam bir WAV üretilir. Parçalar birleştirilir ve tek AAC kodlamasıyla MP4 yapılır. İlerleme `film_job_progress_update` ile raporlanır.
6. Final dosya `ffprobe` ile ölçülür. `output_artifact_begin` → staging yükleme → yeniden okuyup hash → `output_artifact_verify` → final yola taşıma → `film_artifact_publish` sırası izlenir. Son adım süreyi (≤ 600 000 ms ve manifest'ten en çok 2 sn sapma), çözünürlüğü ve codec'leri doğrular, metaveriyi kaydeder ve artifact'ı `ready` yapar.
7. İndirme Faz 8'deki `output-download` ile yapılır. Uygulama baytları artifact SHA-256'sıyla doğrular.

## Konteyner

```bash
# Repo kökünden (uygulama fontları imaja kopyalanır)
docker build -f workers/film/Dockerfile -t bebegimin-film-worker .
docker run --rm \
  -e SUPABASE_URL=https://<project>.supabase.co \
  -e SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
  -e WORKER_ID=film-1 \
  bebegimin-film-worker
```

| Değişken | Varsayılan | Not |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | — | Zorunlu. Anahtar yalnız worker ortamındadır. |
| `WORKER_ID` | `film-<rastgele>` | `^[A-Za-z0-9._:-]{1,80}$`; loglarda ve lease'te görünür. |
| `POLL_INTERVAL_MS` | `15000` | Kuyruk boşken bekleme süresi. |
| `FFMPEG_PATH`, `FFPROBE_PATH` | `ffmpeg`, `ffprobe` | |
| `FONT_DIR` | `/app/fonts` | `Nunito-Regular.ttf`, `Nunito-Bold.ttf` |
| `WORK_DIR` | `/tmp/film` | İş başına geçici klasör; iş bitince silinir. |

Önerilen kaynak: 2 vCPU, 4 GB RAM, 10 GB geçici disk, worker başına tek iş. Daha fazla kapasite için aynı imajdan birden çok konteyner çalıştırın; işleri lease ile güvenle paylaşırlar. SIGTERM / SIGINT sonrası worker mevcut işi bitirip durur.

Loglarda yalnız job kimliği, deneme numarası, sonuç ve süre bulunur; URL, dosya yolu veya kullanıcı içeriği yazılmaz.

## Yerel test

```bash
cd workers/film
FFMPEG_PATH=ffmpeg FFPROBE_PATH=ffprobe deno task test
```

Entegrasyon testi gerçek bir film üretir (dikey/yatay fotoğraf, sesli dikey video, kaynaktan kısa sessiz klip, uzun metin kartı). Ardından süre, çözünürlük ve codec'leri doğrular. CI'da `film-worker` işi aynı testi Ubuntu ffmpeg ile çalıştırır.

## Kill switch ve geri alma

```sql
-- Yeni film isteklerini durdur (kuyruktaki işler ve hazır filmler korunur)
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'film_renderer';
-- Tüm çıktı tüketimini durdur (kitap / film / HTML)
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'output_worker';
```

Worker konteynerini durdurmak da güvenlidir: yarım kalan işin lease'i dolunca iş backoff ile kuyruğa döner. Satışı kapatmak için Faz 7'deki `premium_storefront` kullanılır.

## Gözlemleme ve alarm önerileri

- `admin_output_metrics()` → `first_year_film`: iş durumları, retry, başarılı deneme süresi ortalaması / p95, hata kodları, artifact boyutu.
- Film hata kodları: `media_corrupt`, `media_missing`, `media_unsupported` (tekrar denenmez); `transcode_failed`, `upload_failed`, `render_failed`, `probe_failed` (backoff ile tekrar); `duration_exceeded`, `duration_mismatch`, `profile_mismatch`, `manifest_missing`, `manifest_invalid` (tekrar denenmez; yazılım hatası işaretidir).
- Alarm: `duration_*` / `profile_mismatch` görülmesi, `queued` iş yaşının 30 dakikayı aşması (worker kapalı olabilir), `poison` oranının yükselmesi.
