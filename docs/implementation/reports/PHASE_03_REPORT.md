# Faz 03 Sonuç Raporu

- Durum: COMPLETE
- Başlangıç commit'i: `c36c37e`
- Bitiş commit'i: Commit oluşturulmadı (kullanıcıdan açık commit talebi gelmedi). Önerilen mesaj: `security: enforce lifecycle across data and storage mutations`
- Eklenen migration: `supabase/migrations/20260929000100_lifecycle_mutation_lock.sql`
- Değişen dosyalar:
  - Veritabanı: yeni migration; `supabase/tests/70_lifecycle_mutation_lock_test.sql` (yeni), `supabase/tests/02_legacy_active_fixture.sql` (yeni), `supabase/tests/run_db_tests.sh`, `supabase/tests/12_lifecycle_extensions_test.sql`, `supabase/tests/40_capsules_dates_test.sql`
  - Flutter: `lib/core/errors/app_exception.dart`, `lib/features/babies/data/baby_repository.dart`, `lib/features/capsules/data/capsule_repository.dart`, `lib/features/{memories,letters,milestones,media}/data/*_repository.dart`, `lib/features/media/data/upload_queue.dart`, üç silme çağrı noktası (`memory_detail_screen.dart`, `letter_screens.dart`, `milestone_screens.dart`), `test/core/app_exception_lifecycle_test.dart` (yeni)

## Uygulanan backend kilidi

- **Ortak satır koruyucusu** `lifecycle_source_guard()`; `memories`, `milestones`, özel `milestone_types`, `letters`, `media`, `comments`, `time_capsules` ve `time_capsule_contents` tablolarında INSERT/UPDATE/DELETE öncesi çalışır. LOCKED bebekte `55000 / hint lifecycle_locked` hatası verir.
- **Son kullanıcı bağlamı** şöyle tanımlanır: `auth.uid()` doluysa veya rol `authenticated`/`anon` ise.
  - SECURITY DEFINER RPC'ler bu iki değeri korur. Bu yüzden RLS dışı definer yollar da korunur; bu, testte kontrol edildiği unutmuş bir definer fonksiyonuyla kanıtlandı.
  - Güvenilir bağlamlar kilide takılmaz: service_role, pg_cron ve GoTrue cascade'leri. Bu yollar yasal silme ve zamanlanmış işler içindir.
- **Üye olmayanlara bilgi sızmaz.** Üye olmayan kullanıcıda koruyucu karar vermez; RLS reddeder. Böylece yabancı bir bebeğin varlığı veya kilit durumu hata mesajından anlaşılmaz.
- **`babies` tablosu** (`babies_lifecycle_guard`):
  - LOCKED bebekte ad, soyad, doğum saati/yeri/ölçüleri, avatar, kapak ve hikâye değiştirilemez.
  - `birth_date` her durumda yalnızca `correct_baby_birth_date()` RPC'si ile değişir.
- **`correct_baby_birth_date(baby, date, reason, confirm_reopen)`** (plan 3.5):
  - Anne/Baba yöneticisi yalnızca şu koşulların hepsinde düzeltebilir: profil ACTIVE, henüz içerik yok.
  - Super Admin her zaman düzeltebilir, gerekçe zorunlu.
  - Kilitli bir profili yeniden açacak düzeltme `p_confirm_reopen` ister ve `lifecycle_reopened` güvenlik olayı olarak kaydedilir.
  - Her düzeltme önceki/sonraki değerleri, gerekçeyi ve rolü içeren bir `birth_date_corrected` denetim kaydı bırakır.
  - Uzatma satırına dokunmaz; ikinci uzatma hakkı doğmaz.
- **RPC denetimi:**
  - `create_time_capsule` artık açıkça `assert_baby_source_writable()` çağırıyor.
  - İçerik yazan başka bir istemci RPC'si yok (`create_baby`, davet ve üyelik RPC'leri arşiv içeriği değildir).
  - `register_book_export` bir çıktı katmanıdır (plan 3.4). Aşağıdaki "Bilinen riskler" bölümüne bakın.
- **Storage:**
  - `can_write_baby_object` ve `can_delete_baby_object` LOCKED bebekte `false` döner (profil/kapak, kapsül fotoğrafı, medya).
  - Medya dosyası yalnızca kendi satırı `uploading` durumundayken yazılabilir. Hazır (`ready`) bir dosyanın üzerine yazılamaz.
  - Okuma politikaları değişmedi.
- **Yükleme sırasında kilit:**
  - Satır ekleme, dosya yazma ve `uploading → ready` geçişinin her biri lifecycle'ı yeniden kontrol eder.
  - `run_baby_lifecycle_jobs()` kilitli bebeklerin yarım kalan yüklemelerini `failed` olarak karantinaya alır ve `upload_quarantined` denetim kaydı yazar; tekrar çalıştırıldığında aynı işi yinelemez.
  - Mevcut günlük iş, bayat `failed` satırları siler; silme trigger'ı dosyaları `storage_cleanup_queue`'ya ekler.
- **Silme sırası:**
  - İstemci artık önce DB satırını siler. Yetki ve lifecycle kararını veritabanı verir; reddedilirse dosya yerinde kalır.
  - Dosyalar sunucu kuyruğundan telafi amaçlı temizlenir.
  - Kapsül fotoğrafları için `time_capsules_queue_cleanup` trigger'ı eklendi.
- **Kill switch:**
  - `platform_flags.lifecycle_write_lock` bayrağı (varsayılan `true`) ile açılıp kapanır.
  - Değişiklikler yalnızca güvenilir rolle yapılabilir ve her değişiklik `platform_flag_events` tablosuna denetim kaydı olarak eklenir.
  - İstemcinin bu bayrağa erişimi yok.
  - Acil geri alma, politikaları gevşetmek yerine bu bayrakla yapılır.

## Kilide dahil edilmeyenler (bilinçli)

- Aile üyeliği, davetler, üye izinleri
- Kişisel `favorites`
- Kitap/çıktı tabloları ve `books` bucket'ı
- Yasal silme yolları: `prepare_account_deletion`, `delete_baby_for_user`, hesap silme cascade'i
- Zamanlanmış işler

Hepsi testlerle doğrulandı.

## Flutter uyarlamaları (asgari, tasarım değişikliği yok)

- `lifecycle_locked`, `birth_date_rpc_only` ve `birth_date_requires_admin` hataları kullanıcı dostu Türkçe mesajlara eşlendi (`permission` türü).
- Bebek profil güncellemesinde doğum tarihi değiştiyse önce `correct_baby_birth_date` RPC'si çağrılıyor; normal update artık `birth_date` göndermiyor.
- Yükleme kuyruğu kilit hatasını kalıcı hata sayıyor: altı kez yeniden denemek yerine öğe hemen "başarısız" oluyor.
- Anı, mektup, ilk, medya ve kapsül silme akışları "önce satır" sırasına geçirildi.

## Kabul kriterleri ve kanıtlar

- **LOCKED kaynak içeriğin tüm backend yazma yolları kapalı.**
  - `70_lifecycle_mutation_lock_test.sql` her kaynak için INSERT/UPDATE/DELETE'i ve `include_in_book` değişikliğini reddediyor. Kapsam: anı, ilk, özel ilk tipi, mektup, medya, yorum (yazarı dahil), kapsül ve bebek profili.
- **İstemci arayüzü olmadan atlatma başarısız.**
  - Doğrudan tablo yazımı (REST karşılığı) reddedildi.
  - SECURITY DEFINER fonksiyonu içinden yazma reddedildi.
  - `create_time_capsule` reddedildi.
  - Storage'da insert, update ve delete sıfır satır etkiledi; `can_write` ve `can_delete` `false` döndü.
  - Yarım kalan yüklemenin dosya yazması ve `ready` geçişi reddedildi.
- **İki bebek senaryosu (Defne LOCKED, Ege ACTIVE):**
  - Defne okunabilir, yazılamaz.
  - Ege'de yetkili yazma, yükleme, sonlandırma, profil düzenleme ve silme çalışıyor.
  - Ege'ye yapılan yazma Defne listesine düşmüyor.
  - `baby_id`'yi Defne'ye taşıma lifecycle, başka bir aktif bebeğe taşıma `immutable` hatasıyla reddediliyor.
  - Başka bebeğin anısına bağlanan yorum/medya foreign key hatasıyla reddediliyor.
- **ACTIVE ama yetkisiz kullanıcı** (yalnız görüntüleme izni olan üye ve yabancı) RLS ile reddediliyor. Yabancıya lifecycle ipucu verilmiyor.
- **Sınır ve uzatma:**
  - +374. gün yazılabilir, +375. gün kilitli.
  - Kapanıştan sonra yükleme sonlandırma reddediliyor.
  - 30 günlük onaylı uzatmayla +404. gün yazılabilir, +405. gün kilitli.
- **Yasal silme ve üyelik yönetimi bozulmadı:**
  - KVKK içerik silme, kilitli bebeği silme ve hesap silmede yazar anonimleştirme çalışıyor.
  - Kilitli bebekte favori ekleme/kaldırma, üye izni düzenleme ve davet oluşturma çalışıyor.
- **Doğum tarihi:** doğrudan güncelleme reddediliyor. Test edilen durumlar:
  - Ebeveyn içerik yokken düzeltebiliyor; içerik varken veya profil kilitliyken reddediliyor.
  - Ebeveyn olmayan üye ve üye olmayan kullanıcı reddediliyor.
  - Super Admin gerekçe zorunluluğu ve denetim kaydındaki önceki değer doğrulandı.
  - Yeniden açma onay olmadan reddediliyor; onayla güvenlik olayı kaydediliyor.
  - Uzatma hakkı değişmiyor.
- **Kill switch:** istemci değiştiremiyor, değişiklik denetim kaydına düşüyor, kapatıldığında kilit kalkıyor.

## Çalıştırılan testler ve sonuçları

- Temiz PostgreSQL 16.4 veritabanında dokuz migration, seed ve `supabase/tests/run_db_tests.sh`: **başarılı**.
  - 315 SQL doğrulaması (Faz 2'de 214; Faz 3'te 101 yeni) ve iki oturumlu gerçek uzatma yarışı.
  - Ortam: yerel taşınabilir PostgreSQL ve repo'daki Supabase shim'i.
- `flutter analyze --no-pub`: başarılı, sorun yok.
- `flutter test --no-pub`: başarılı, 70 test (3'ü yeni).
- `dart format --output=none --set-exit-if-changed lib test`: başarılı.
- `git diff --check`: başarılı.

## Test uyarlamaları

- **`02_legacy_active_fixture.sql`:** Seed'de Defne 400 günlüktür, yani artık LOCKED. İzin, izolasyon ve Storage testleri (10–60) yazılabilir bir arşivi test ettiği için bu fixture Defne'yi 370. güne alır (ilk doğum günü geçmiş, 375 günlük pencere içinde). Test 70 onu yeniden kilitler.
- **`12_lifecycle_extensions_test.sql`:** Fixture yazımlarından önce `tests.logout()` eklendi. Artık kullanıcı kimliği taşıyan her oturum son kullanıcı bağlamı sayılıyor.
- **`40_capsules_dates_test.sql`:** "İlk yıl bittikten sonra da yazılabilir" varsayımı, yeni ürün kuralı gereği "375 günlük pencere içinde yazılabilir" olarak güncellendi.

## Çalıştırılamayan testler / neden

- Gerçek Supabase Storage API ve PostgREST üzerinden uçtan uca test yapılmadı. Politikalar ve `storage.objects` repo shim'inde doğrudan test edildi.
- "Son kullanıcı bağlamı" tespiti Supabase'in `role` ve `request.jwt.claims` davranışına dayanır. Hedef ortamda bir curl/REST dumanı testi önerilir.

## Güvenlik ve veri migration notları

- Yeni tablolar (`platform_flags`, `platform_flag_events`) için RLS açıldı, istemci grant'leri kaldırıldı.
- İç yardımcılar (`baby_lifecycle_active_internal`, `baby_source_writable`, `assert_baby_source_writable`, `lifecycle_enforced_context`, `lifecycle_write_lock_enabled`) istemci rollerine kapalı. Böylece lifecycle kahini (oracle) oluşmaz.
- Bütün SECURITY DEFINER fonksiyonlarda `search_path` sabit.
- Tarihsel migration'lar değiştirilmedi. `create_time_capsule`, `can_write_baby_object`, `can_delete_baby_object` ve `run_baby_lifecycle_jobs` ileri migration'da `create or replace` ile güncellendi.
- **Veri etkisi:** Migration uygulandığı anda 375. günü (ve varsa onaylı uzatmayı) geçmiş tüm bebekler salt okunur olur. Bu bebeklerin `uploading` durumundaki medyası ilk lifecycle işinde karantinaya alınır.
- Migration tek transaction içinde. Yeniden çalıştırılabilir değil (Faz 2 ile aynı yaklaşım); Supabase migration geçmişi tekrar uygulamayı engeller.

## Rollback adımları

- Acil durumda güvenilir rolle: `update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'lifecycle_write_lock';`. İşlem `platform_flag_events`'e düşer. Politikaları gevşetmeyin.
- Kalıcı geri alma gerekirse, trigger'ları düşüren yeni bir ileri migration yazılmalı. Veri kaybı yoktur.

## Bilinen riskler

- **Kitap katmanı hâlâ açık:** `register_book_export`, `book_*` tabloları ve `books` bucket'ı ACTIVE profilde hâlâ açık. Plan 2.2'deki "ACTIVE'de kitap tamamen kapalı" kuralı Faz 9 kapsamındadır (plan 3.4, Faz 3'te çıktı katmanını lifecycle dışında tutar).
- **İstemci henüz lifecycle'ı göstermiyor:** Flutter kilitli durumda "+" ve düzenleme aksiyonlarını hâlâ gösteriyor; backend reddedip Türkçe mesaj veriyor. Kullanıcıya aksiyon verip sonra hata göstermek kabul edilmez (plan 2.3); bu Faz 4'ün işi.
- **Demo verisi:** Seed'de Defne kilitli; demo hesaplarla Defne'ye içerik eklenemez. Ürün kuralına uygun (plan 6.2'deki "Defne LOCKED, Ece ACTIVE" senaryosu).
- **Zamanlanmış işler kurulmalı:** Dosya temizliği `storage-cleanup` Edge Function'ının (README'deki saatlik pg_cron) ve `run_daily_jobs` işinin kurulmasına bağlı. `pg_cron` yoksa `run_baby_lifecycle_jobs()` da dış bir zamanlayıcıyla günlük çalıştırılmalı (Faz 2 notu geçerli).
- **Yeniden açılıp tekrar kilitlenen profil:** `activity_logs` üzerindeki tekil `profile_locked` index'i nedeniyle ikinci bir `profile_locked` kaydı üretilmez. Güvenlik olayı `lifecycle_reopened` ile izlenir.
- **Kapsam dışı değişiklik:** Çalışma ağacında Faz 3'e ait olmayan bir `GELISTIRME.MD` değişikliği (fiyat metinleri) var. Oturum sırasında dışarıdan yapıldı; bu faza dahil edilmedi, commit'e eklenmemeli.

## Faz 4'ün giriş koşulları

- Faz 3 backend kilidi istemciden bağımsız çalışıyor: **sağlandı**.
- Faz 4'te yapılacaklar:
  - `BabyLifecycle` provider'ını ekranlara bağlamak
  - LOCKED durumda `+`, ekleme, düzenleme ve silme aksiyonlarını kaldırmak
  - Doğum tarihi alanını kilitli profilde salt okunur yapmak
  - `birth_date_requires_admin` durumunda kullanıcıyı destek yoluna yönlendirmek
  - Uzatma talep ekranını eklemek
- Hedef ortamda migration uygulanınca curl ile REST/Storage bypass dumanı testi yapılmalı.
