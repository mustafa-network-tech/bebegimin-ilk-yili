# Faz 08 Sonuç Raporu

- **Durum:** COMPLETE (2026-10-01). Migration, Edge Function, güvenlik testleri ve operasyon belgesi hazır; tam SQL paketi PostgreSQL 16.10 üzerinde yeşil.
- **Başlangıç commit'i:** `f6a4fa9`
- **Eklenen migration:** `supabase/migrations/20260929000600_output_pipeline.sql`
- **Operasyon belgesi:** `docs/operations/output-pipeline-setup.md`

## Değişen dosyalar

- `supabase/migrations/20260929000600_output_pipeline.sql`
- `supabase/tests/98_output_pipeline_test.sql`
- `supabase/tests/run_db_tests.sh` (Faz 8 migration reapply regresyonu)
- `supabase/functions/output-download/index.ts`
- `supabase/functions/storage-cleanup/index.ts`
- `docs/operations/output-pipeline-setup.md`
- `README.md`
- `PHASE_STATUS.md`

## Uygulananlar

### Değiştirilemez arşiv snapshot'ı

- Migration, geliştirme ortamlarına uygulanmış erken Faz 8 taslaklarını veri silmeden yükseltebilmek için tablo/index oluşturma ve trigger yenileme adımlarında yeniden çalıştırılabilir yapıdadır.
- `archive_snapshots` schema version, canonical `jsonb` içerik, SHA-256 checksum, byte boyutu ve içerik sayaçlarını saklar.
- Snapshot yalnız `LOCKED` bebek, aktif aile aboneliği ve ilgili aktif ürün hakkı için oluşturulur. Kullanıcı bağlamı verilmişse aktif ebeveyn olması ayrıca zorunludur.
- Bebek profil bilgileri, uzatma günleri, aile üyelerinin canlı ad/yakınlık değerleri, kilometre taşları, anılar, mektuplar, hazır medya ve yorumlar sıralı biçimde snapshot'a kopyalanır.
- Uzatma döneminde yazılmış geçerli içerik dahildir; açılmamış zaman kapsülleri ve kullanıcıya özel favoriler dahil değildir.
- Trigger checksum, byte boyutu ve sayaçları sunucuda yeniden hesaplar; family/baby/content kimliklerini doğrular. Mühürlenen satır UPDATE/DELETE kabul etmez.

### Project, job ve worker sözleşmesi

- `output_projects`, `output_jobs` ve append-only `output_job_attempts` tabloları eklendi.
- Project başına idempotency key tektir; eşzamanlı istekler project satır kilidiyle tek snapshot/job üzerinde birleşir.
- Worker claim `FOR UPDATE SKIP LOCKED`, lease, heartbeat, 30 saniyeden başlayan üstel backoff, maksimum deneme ve `poison` durumunu uygular.
- Süresi dolmuş lease heartbeat/fail/verify/publish ile yeniden kullanılamaz.
- Claim anında entitlement, abonelik ve lifecycle yeniden kontrol edilir. İade, kapanmış abonelik veya yeniden açılmış lifecycle durumundaki queued iş render edilmeden iptal edilir.
- Worker hata metinlerindeki URL, token, imza ve bearer değerleri veritabanına yazılmadan redakte edilir.
- Project/job/snapshot/artifact üzerinde çoğaltılan family, baby ve product kimlikleri trigger ile çapraz doğrulanır; farklı bebeğin snapshot/artifact'ı bir başka project'e bağlanamaz.

### Artifact ve Storage güvenliği

- `output_artifacts`, `output_artifact_downloads` ve private `output-artifacts` bucket'ı eklendi.
- Akış staging kaydı/yüklemesi → byte boyutu + SHA-256 doğrulaması → namespaced final yol → `ready` şeklindedir.
- Yol şeması `<baby>/<product>/<snapshot>/v<version>/<file>`; staging ve final yolları veritabanında doğrulanır.
- Checksum/size uyuşmazlığı, eksik staging/final nesne veya geçersiz state transition `ready` olamaz; artifact quarantine edilir ve iş retry/poison akışına girer.
- Authenticated rolün bucket üzerinde doğrudan SELECT politikası yoktur. `output-download` Edge Function kullanıcı JWT'siyle gerçek ve `ready` artifact satırını yetkilendirir, ardından service role ile tam **60 saniyelik** URL üretir; istemci daha uzun ömür seçemez.
- Download; aktif hesap üyeliği, LOCKED lifecycle, abonelik, bebek+ürün entitlement'ı, `view_album`/admin izni ve artifact durumunu yeniden denetler. Yanıt `no-store` olur; logda URL/token/imza tutulmaz.

### Bakım ve gözlemlenebilirlik

- `output_pipeline_maintenance` süresi dolmuş lease'leri geri alır, bayat staging kayıtlarını terk edilmiş yapar, quarantine retention uygular ve orphan Storage nesnelerini `storage_cleanup_queue`'ya ekler.
- `pg_cron` mevcutsa bakım saatin 7. dakikasında otomatik kurulur; fiziksel silme mevcut `storage-cleanup` Edge Function'ına bırakılır.
- `storage-cleanup`, silmeden hemen önce `output_artifacts` final/staging yollarını da yeniden kontrol eder; aktif bir artifact yanlışlıkla kuyruğa girse bile dosyası silinmez.
- `output_pipeline_metrics` ve Super Admin kontrollü `admin_output_metrics`; durum, retry, failure code, başarılı deneme ortalama/p95 süresi ve artifact boyut metriklerini verir.
- `output_worker` platform bayrağı tüketimi durdurur; queued işler ve snapshot'lar korunur.

## Test kapsamı

`98_output_pipeline_test.sql` toplam **124 doğrulama** içerir (87 sonuç doğrulaması + 37 beklenen ret):

- ACTIVE, aboneliksiz, entitlement'sız ve ebeveyn olmayan istekler
- aynı idempotency key ve aynı snapshot için tek job
- canonical checksum, uzatma içeriği, canlı ad/yakınlık kopyası ve snapshot immutability
- worker kill switch, lease sahipliği, süresi dolan lease, retry/backoff ve poison
- staging/checksum/size/final-path kontrolleri ve geçersiz state transition'lar
- kardeş bebek/ürün/path izolasyonu ve DB kaydı olmayan Storage nesnesinin reddi
- üyelik, izin, lifecycle, abonelik, entitlement ve artifact download kontrolleri
- abonelik kapanınca artifact'ın korunması fakat queued işin ve download'ın reddi
- iade edilmiş entitlement için job iptali
- stale staging, quarantine ve orphan cleanup
- duration, retry, failure code ve artifact size metrikleri

## Çalıştırılan kontroller

- Önceki çalışma logunda migration PostgreSQL'e başarıyla uygulanmış, ancak `98_output_pipeline_test.sql` ilk fixture'daki geçersiz davet kodunda durmuştu. Kodlar şemanın `^[A-HJ-NP-Z2-9]{10}$` kuralına uygun hale getirildi.
- Doğrudan Dart SDK ile analiz: **No issues found**. Komut analizden sonra workspace dışındaki kullanıcı telemetry logunu silemediği için process exit code `1` verdi; analiz sonucu temizdir.
- `npx --yes deno fmt --check` ve `deno check` (`output-download`, `storage-cleanup`): başarılı.
- `npx --yes deno test supabase/functions/tests/store_status.test.ts`: başarılı, 9/9 test.
- `git diff --check`: izlenen belge değişikliklerinde whitespace hatası yok.
- SQL dosyasında 32 fonksiyon, 7 tablo, 8 trigger ve dengeli 66 `$$` delimiter statik olarak doğrulandı.

## Tamamlama doğrulaması (2026-10-01)

PostgreSQL 16.10 (taşınabilir Windows binary'leri, geçici veritabanı) üzerinde:

- `supabase/tests/run_db_tests.sh`: **✓ all database tests passed**. Toplam 693 `ok` doğrulaması; `98_output_pipeline_test.sql` içinde **124/124**.
- Faz 8 migration'ının mevcut şemaya yeniden uygulanması hatasız.
- Gerçek iki oturumlu yarış testleri (uzatma talebi, admin kararı, aile kapasitesi) ve film entitlement yarışı geçti.
- `flutter analyze`: No issues found. `flutter test`: 121/121.

Test paketinde düzeltilen fixture hataları (migration'da değişiklik gerekmedi):

- Snapshot yazar adı doğrulamalarında alt sorguyu `from`'dan önce kapatan parantez hatası.
- `close_before` referansı 20 günlük uzatma onayından önce okunuyordu; artık uzatmadan sonra okunuyor, böylece "pipeline lifecycle'ı değiştirmez" doğrulaması doğru tabanı karşılaştırıyor.

## Rollback / kill switch

```sql
update public.platform_flags
set enabled = false,
    note = 'Faz 8 worker tüketimi operasyonel olarak durduruldu'
where key = 'output_worker';
```

Bu işlem veri kaybettirmez. Migration'ı fiziksel olarak geri almak yerine düzeltici ileri migration kullanılmalıdır; sealed snapshot, job geçmişi, download audit'i ve artifact kayıtları kalıcı denetim izidir.

## Faz 9 giriş koşulları

- Book entitlement ve ortak artifact pipeline uygulanmıştır.
- Faz 9'a başlamadan önce tam SQL paketi PostgreSQL 16/Supabase uyumlu ortamda yeşil olmalıdır.
- Faz 9 yalnız kitap renderer/export entegrasyonunu eklemeli; bu fazdaki ortak snapshot, job, lease, artifact ve download sözleşmesini gevşetmemelidir.
