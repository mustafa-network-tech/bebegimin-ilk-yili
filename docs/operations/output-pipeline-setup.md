# Output pipeline operasyon kurulumu

Bu belge Faz 8'de eklenen Book (PDF), Offline HTML (ZIP) ve Film (MP4) ortak üretim omurgasının operasyon sözleşmesidir. Ürüne özel renderer'lar Faz 9–11 kapsamındadır.

## Güvenlik sınırı

- Worker yalnız sunucu ortamındaki `service_role` ile çalışır; anahtar mobil uygulamaya girmez.
- İstemci iş durumu için `request_output_job` ve `baby_output_status` RPC'lerini çağırır. İndirme için `output-download` Edge Function'ını kullanır; `request_output_download` bu fonksiyonun kullanıcı JWT'siyle çağırdığı yetkilendirme/audit RPC'sidir.
- Snapshot/job isteği için bebeğin `LOCKED`, çağıranın aktif ebeveyn, aile aboneliğinin erişim verir ve ilgili bebek/ürün hakkının aktif olması gerekir.
- İndirme her istekte aktif aile üyeliği, `LOCKED` lifecycle, abonelik, ürün hakkı ve `ready` artifact satırını yeniden denetler. Faz 12'den itibaren Family Member için ayrıca plan kapasitesi ve ebeveynin ürün bazlı paylaşımı gerekir (`view_album` kullanılmaz); bkz. [artifact-download-policy.md](artifact-download-policy.md).
- Storage klasör adı tek başına yetki vermez. `output_artifacts` satırı olmayan, staging'de kalan veya quarantine edilen nesne okunamaz. Authenticated rolün bucket üzerinde doğrudan SELECT politikası yoktur; böylece istemci imzalı URL ömrünü kendisi seçemez.

Edge Function'ı JWT doğrulaması açık biçimde deploy edin:

```bash
supabase functions deploy output-download
```

İstek gövdesi `{"artifact_id":"<uuid>"}` biçimindedir. Başarılı yanıt URL, `expires_in: 60`, dosya adı, MIME, boyut ve SHA-256 değerini döndürür; yanıt `Cache-Control: no-store` taşır.

## Worker akışı

1. Desteklenen ürünlerle `output_claim_jobs(worker_id, products, limit, lease_seconds)` çağrılır.
2. Dönen `snapshot_id`, `output_snapshot_payload` ile okunur; içerik SHA-256 değeri satırdaki checksum ile karşılaştırılır.
3. Uzun render sırasında lease süresi dolmadan `output_job_heartbeat` çağrılır. Süresi dolmuş lease yeniden canlandırılamaz.
4. Dosyanın SHA-256 ve byte boyutu hesaplanır; `output_artifact_begin` ile staging/final yolları alınır.
5. Dosya yalnız dönen `staging_path` yoluna yüklenir. Worker staging nesnesini yeniden okuyup hash'ler ve `output_artifact_verify` çağırır.
6. Doğrulanmış nesne Storage içinde dönen final yola taşınır; ardından `output_artifact_publish` çağrılır. Ancak bu adım işi `succeeded`, artifact'ı `ready` yapar.
7. Hata halinde yalnız lease sahibi `output_job_fail` çağırır. Retry edilebilir hata üstel backoff ile kuyruğa döner; `max_attempts` sonrasında iş `poison` olur.

Worker kimliği `^[A-Za-z0-9._:-]{1,80}$`, lease 30–900 saniye ve tek claim limiti 1–10 aralığında olmalıdır. Hata metnine URL, bearer token, imza veya secret koyulmamalıdır; veritabanı ayrıca bilinen kalıpları redakte eder.

## Kill switch ve geri alma

Yeni iş tüketimini durdurmak için:

```sql
update public.platform_flags
set enabled = false,
    note = 'Operasyonel durdurma: <gerekçe>'
where key = 'output_worker';
```

Bu işlem queued işleri, mühürlü snapshot'ları ve artifact kayıtlarını silmez. Yeniden açmak için `enabled = true` yapılır.

## Periyodik bakım

Migration, `pg_cron` varsa aşağıdaki saatlik işi otomatik kurar:

```sql
select cron.schedule(
  'bebegimin-output-pipeline-maintenance',
  '7 * * * *',
  'select public.output_pipeline_maintenance()'
);
```

`pg_cron` yoksa aynı RPC güvenilir bir scheduler tarafından saatte bir çağrılmalıdır. Fonksiyon fiziksel dosya silmez; silinecek staging, quarantine ve orphan yollarını `storage_cleanup_queue` tablosuna ekler. README'deki `storage-cleanup` Edge Function zamanlaması ayrıca aktif olmalıdır.

Varsayılan eşikler:

- staging TTL: 2 saat
- quarantine saklama: 7 gün
- retry: 30 saniyeden başlayan üstel backoff, en fazla 1 saat
- iş başına varsayılan maksimum deneme: 5

## Gözlemleme

Super Admin, son 1–90 gün için `admin_output_metrics(days)` çağırabilir. Çıktı ürün bazında şunları içerir:

- iş durum adetleri
- retry sayısı
- ortalama ve p95 başarılı deneme süresi
- failure code adetleri
- hazır artifact adedi ile ortalama/maksimum byte boyutu

Ham servis metriği `output_pipeline_metrics(since)` yalnız `service_role` içindir. İndirme logunda yalnız kullanıcı, artifact ve zaman tutulur; URL, token veya imza tutulmaz.

## Alarm önerileri

- `poison > 0`
- son bir saatte `lease_expired` artışı
- p95 sürenin ürünün worker zaman aşımına yaklaşması
- `storage_cleanup_queue` kuyruğunun sürekli büyümesi
- son iki bakım aralığında `output_maintenance_runs` kaydı oluşmaması
