# ADR 0004 — İlk Yıl Filmi render altyapısı ve kaynak limitleri

- Durum: Kabul edildi (Faz 10)
- Tarih: 2026-10-01

## Bağlam

Master plan §2.10 ve Faz 10:

- `first_year_film` en fazla **600 saniyelik** resmî MP4 artifact'tır. 600 saniye hedef değil üst sınırdır; içerik azsa film uzatılmaz.
- Final film sunucuda, LOCKED arşivin immutable snapshot'ından, Faz 8 job / artifact hattıyla üretilir. Flutter cihazında render edilmez.
- Supabase Edge Function'ları CPU süresi ve bellek sınırları nedeniyle dakikalarca süren video kodlamaya uygun değildir.

## Kararlar

### 1. Ayrı worker konteyneri (Deno + ffmpeg)

- Film, `workers/output` altındaki Deno uygulamasıyla üretilir. Docker imajı `ffmpeg` / `ffprobe` ve uygulamanın kitap fontlarını (Nunito) içerir.
  - Worker Faz 10'da `workers/film` olarak eklendi, Faz 11'de film ve offline HTML'i birlikte üreten `workers/output` olarak genelleştirildi (ADR 0005).
  - Kurulum: `docs/operations/output-worker-setup.md`.
  - İmaj CI ile aynı Deno sürümünü kullanır ve `deno.lock` ile derlenir (2026-10-02).
- Worker herhangi bir konteyner platformunda (Fly.io, Cloud Run, Railway, VPS) çalışabilir. Supabase'e `service_role` anahtarıyla bağlanır; anahtar yalnız worker ortamındadır.
- İş alma, lease, heartbeat, retry / poison, artifact staging → doğrulama → taşıma → yayın adımları Faz 8 RPC'leridir (`output_claim_jobs` … `output_artifact_publish`). Film'e özgü adımlar `film_job_manifest`, `film_job_progress_update`, `film_job_media_error` ve `film_artifact_publish` RPC'leridir.
- Fotoğraflar ve videolar üçüncü taraf bir servise gönderilmez.

### 2. Sahne manifest'i sunucuda, tek algoritma

- Film içeriği ve sahne süreleri SQL'de (`build_film_manifest`) snapshot + proje ayarlarından **deterministik** olarak hesaplanır. Uygulama süre tahminini aynı fonksiyondan (`film_plan`) okur; istemcide ikinci bir algoritma yoktur.
- Render isteğinde manifest `film_render_manifests` içine dondurulur (sunucu checksum'ı, değiştirilemez). Retry aynı manifest ile yapılır.
- Süre bütçesi:
  - Her sahne türünün temel ve en kısa süresi vardır (fotoğraf 3,5 / 2 sn, video klibi en çok 8 sn / en az 3 sn, bölüm kartı 2,5 / 1,5 sn …).
  - Temel toplam ≤ 600 sn ise temel süreler kullanılır; az içerik kısa film demektir.
  - Temel toplam > 600 sn ama en kısa toplam ≤ 600 sn ise süreler orantılı kısaltılır.
  - En kısa toplam > 600 sn ise render **reddedilir** (`film_too_long`); film kırpılmaz. Uygulama aşan süreyi gösterir ve seçimi düzenlemeyi ya da sunucunun önerdiği seçimi (`film_suggest_settings`) uygulamayı ister.
- Render sonrası `ffprobe` süresi 600 000 ms'yi aşarsa artifact yayınlanmaz (`duration_exceeded`, tekrar denenmez). Manifest süresinden 2 saniyeden fazla sapma da reddedilir (`duration_mismatch`).

### 3. Çıktı profili

- MP4 (H.264 High, `yuv420p`, 1920×1080, 30 fps, CRF 23, `veryfast`, en çok 8 Mbit/s) + AAC 48 kHz stereo 128 kbit/s, `+faststart`.
- Dikey ve yatay medya bulanık arka planla 16:9 kareye ortalanır. Video yönü ffmpeg'in otomatik döndürmesiyle uygulanır.
- `-map_metadata -1` ve bitexact bayrakları kullanılır; dosyada cihaz veya konum metaverisi kalmaz.

### 4. Ses

- İlk sürümde müzik ve seslendirme **yoktur**; lisans riski oluşmaz.
- Video klipleri kendi sesiyle, `loudnorm` (I = −16 LUFS, TP = −1,5 dB) ile normalize edilir. Fotoğraf ve metin sahneleri sessizdir.
- Müzik eklenirse yeni bir ADR gerekir: parça lisansları, kullanıcı onayı ve video sesinin müzik altında kısılması (ducking).

### 5. Kaynak limitleri

| Limit | Değer |
|---|---|
| Worker başına eşzamanlı iş | 1 |
| Önerilen kaynak | 2 vCPU, 4 GB RAM, 10 GB geçici disk |
| Lease / heartbeat | 300 sn lease, 60 sn'de bir heartbeat |
| Kaynak medya | Bucket sınırı (2 GB); videodan en çok 8 sn alınır |
| Sahne başına ffmpeg zaman aşımı | 180 sn |
| Final dosya | Output bucket sınırı 2 GB; profil 10 dakikada ≈ 600 MB üst sınır |

### 6. Hata sınıfları

- Bozuk, eksik veya desteklenmeyen medya `media_corrupt` / `media_missing` / `media_unsupported` ile **tekrar denenmeden** biter. Sorunlu medya kimliği kaydedilir; uygulama "bu medyayı çıkar ve yeniden dene" seçeneği sunar.
- Geçici hatalar (`transcode_failed`, `upload_failed`, `render_failed`) Faz 8 backoff'u ile yeniden denenir.

## Sonuçlar

- Film üretimi için ayrı bir konteyner barındırma maliyeti oluşur; kitap ve HTML bundan etkilenmez.
- Kill switch: `film_renderer` (yeni istek), `output_worker` (tüm tüketim), `premium_storefront` (satış).
