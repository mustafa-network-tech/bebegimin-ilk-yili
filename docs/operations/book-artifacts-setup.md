# Dijital kitap (resmî PDF) operasyon kurulumu

Bu belge Faz 9'da eklenen kitap kapısının ve resmî PDF üretim protokolünün operasyon sözleşmesidir. Ortak snapshot / job / artifact omurgası için bkz. [output-pipeline-setup.md](output-pipeline-setup.md).

## Kim, ne zaman kullanabilir?

Kitap yapılandırması (`book_projects`, `book_pages`, `book_items`) ve resmî render yalnız şu koşulların hepsinde açılır:

1. Bebek `LOCKED` (375 gün + varsa onaylı uzatma bitti).
2. Bebeğin aile hesabında aktif / erişim veren abonelik var.
3. Aynı aile hesabı + bebek için aktif `first_year_book` entitlement var.
4. Çağıran o aile hesabında aktif **ebeveyn** (Anne / Baba).

Kural tek yerde, `book_access_block(baby, user)` içinde uygulanır. Tablo RLS'i, tüm kitap RPC'leri ve Storage yükleme politikası aynı fonksiyonu kullanır. Family Member resmî sürümleri listeleyebilir ve `view_album` izni varsa indirebilir. Yapılandırmayı göremez, render başlatamaz.

ACTIVE profilde eski (legacy) projeler dahil hiçbir kitap verisi görünmez.

## Resmî PDF protokolü

PDF motoru (`BookComposer` → `BookRenderResolver` → `BookPdfBuilder`) uygulamada kalır. Cihazda üretilen bir dosya, sunucu doğrulamadan lisanslı artifact sayılmaz.

| Adım | Çağıran | Ne olur |
|---|---|---|
| `book_render_start(baby, idempotency_key)` | Ebeveyn (JWT) | Snapshot mühürlenir (`output_create_snapshot`), anlık kitap yapılandırması `book_render_manifests` içine dondurulur (checksum'lı, değiştirilemez), job `book-client:<user_id>` adına 15 dakikalık lease ile başlatılır. Aynı anahtar aynı işi döndürür. Aynı ebeveynin eski denemesi `superseded` olarak iptal edilir. Başka ebeveynin canlı lease'i `book_render_in_progress` ile reddedilir. |
| `book_render_payload(job)` | Lease sahibi | Snapshot ve manifest metni + checksum'ları. Uygulama ikisini de SHA-256 ile doğrular, sonra yalnız bunlardan render eder. |
| `book_render_heartbeat(job)` | Lease sahibi | Lease'i 15 dakika uzatır (uygulama 4 dakikada bir çağırır). |
| `book_artifact_begin(job, sha256, size)` | Lease sahibi | Artifact satırı yüklemeden **önce** oluşur; dönen `staging_path` tek yazılabilir yoldur. |
| Storage upload | Lease sahibi | `output-artifacts` bucket'ına yalnız INSERT ve yalnız o `staging_path`. Okuma, üzerine yazma ve başka yol yoktur. |
| `book-artifact-finalize` Edge Function | Ebeveyn (JWT) → service role | Kullanıcının lease ve kitap kapısı JWT ile yeniden denetlenir. Staging nesnesi **sunucuda** indirilir, `%PDF-` / `%%EOF` kontrolü yapılır, SHA-256 hesaplanır. `output_artifact_verify` → final yola taşıma → `book_artifact_publish`. |
| `book_artifact_publish(artifact, worker, pages)` | Service role | Artifact `ready`, job `succeeded`, kitap sürümü atomik artar ve `book_exports` satırı artifact'a bağlanır. Hepsi tek transaction'dır. |
| `book_render_fail(job, code)` | Lease sahibi | Render, fotoğraf veya yükleme hatası. Deneme aynı snapshot + manifest ile backoff sonrası tekrar edilebilir. |

Uyuşmayan hash, eksik nesne veya boyut farkı artifact'ı `quarantined` yapar ve denemeyi başarısız sayar. Geçersiz PDF `invalid_pdf` koduyla başarısız olur. Resmî render'da indirilemeyen tek bir fotoğraf bile render'ı durdurur (`image_failed`); ücretli üründe boş çerçeve bırakılmaz.

İndirme Faz 8'deki `output-download` fonksiyonuyla yapılır. Uygulama indirilen baytları `book_versions` içindeki SHA-256 ile karşılaştırır.

## Deploy

```bash
supabase functions deploy book-artifact-finalize
supabase functions deploy output-download
```

`supabase/config.toml` içinde ikisi de `verify_jwt = true`. Ek secret gerekmez (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` platform tarafından enjekte edilir).

## Legacy kitap verisi

Migration öncesi tüm `book_projects` ve `book_exports` satırları `legacy_status = 'legacy_quarantined'` olarak işaretlenir:

- Ailelere gösterilmez. `books` bucket'ında istemci okuma / yazma / silme politikası kalmaz.
- Silinmez. Proje silme yetkisi kullanıcılardan alınmıştır, export'lar değiştirilemez. Yasal bebek silme akışı legacy dosyaları `baby_storage_objects` üzerinden temizlemeye devam eder.
- Otomatik entitlement verilmez. Bebek LOCKED olduktan ve kitap satın alındıktan sonra legacy proje yapılandırması yeniden kullanılabilir. Resmî PDF ancak yeni bir snapshot'tan üretilir.
- `register_book_export` artık her çağrıda `book_export_requires_artifact` ile reddeder (eski uygulama sürümleri anlaşılır hata alır).

Rapor (Super Admin):

```sql
select * from public.admin_legacy_book_report();
```

## Kill switch ve geri alma

```sql
update public.platform_flags
set enabled = false, note = 'Kitap render durduruldu: <gerekçe>'
where key = 'book_renderer';
```

Yeni render başlatılamaz (`book_renderer_disabled`). Yapılandırma, snapshot, job geçmişi ve hazır PDF'ler korunur, indirme sürer. `output_worker` bayrağı kapatılırsa kitap render'ı da durur. Satışı kapatmak için Faz 7'deki `premium_storefront` bayrağı kullanılır.

Fiziksel geri alma yerine ileri migration kullanılmalıdır. Manifest, job, artifact ve export kayıtları kalıcı denetim izidir.

## Gözlemleme

- Kitap işleri `output_pipeline_metrics()` / `admin_output_metrics()` içinde `first_year_book` altında görünür.
- Faz 9'a özgü hata kodları: `render_failed`, `image_failed`, `upload_failed`, `client_aborted`, `invalid_pdf`, `move_failed`, `superseded`.
- `image_failed` oranının yükselmesi medya erişimi veya imzalı URL sorunlarına işaret eder. `checksum_mismatch` artışı yükleme bozulmasını veya istemci hatasını gösterir.
