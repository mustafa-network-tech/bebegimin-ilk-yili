# Bebeğimin İlk Yılı

Bir bebeğin doğumundan itibaren anılarını, fotoğraflarını, videolarını, ilklerini ve ailesinin ona bıraktığı mesajları **özel ve güvenli bir aile alanında** saklayan; ilk 365 günün sonunda baskıya hazır **"İlk Yılım" fotoğraf kitabını** üreten Flutter (Android + iOS) uygulaması. Arşiv 1 yaşında kapanmaz: 1–2 yaş, 2–3 yaş … dönemleriyle büyümeye devam eder.

> Bu depo; Flutter uygulamasını, Supabase veritabanı şemasını (migration), RLS güvenlik politikalarını, Storage politikalarını, Edge Function'ları, demo verisini ve testleri içerir.

---

## İçindekiler

1. [Özellikler](#özellikler)
2. [Mimari](#mimari)
3. [Kullanılan teknolojiler](#kullanılan-teknolojiler)
4. [Supabase şeması ve güvenlik](#supabase-şeması-ve-güvenlik)
5. [İlk Yılım kitabı / PDF](#i̇lk-yılım-kitabı--pdf)
6. [Kurulum](#kurulum)
   - [Flutter](#1-flutter)
   - [Supabase projesi](#2-supabase-projesi)
   - [Migration'lar](#3-migrationları-çalıştırma)
   - [Storage](#4-storage)
   - [Auth ayarları](#5-auth-ayarları)
   - [Edge Function'lar](#6-edge-functionlar)
   - [Zamanlanmış işler (pg_cron)](#7-zamanlanmış-işler)
   - [Push bildirimleri (isteğe bağlı)](#8-push-bildirimleri-isteğe-bağlı)
   - [Ortam değişkenleri](#9-ortam-değişkenleri)
7. [Çalıştırma (Android / iOS)](#çalıştırma)
8. [Demo verisi](#demo-verisi)
9. [Testler](#testler)
10. [Build ve release hazırlığı](#build-ve-release-hazırlığı)
11. [Bilinen sınırlar](#bilinen-sınırlar)

---

## Özellikler

| Alan | Neler var |
|---|---|
| **Hesap** | E-posta + şifre ile kayıt/giriş, e-posta doğrulama (deep link), şifremi unuttum / sıfırlama, şifre değiştirme, profil (ad + fotoğraf), hesap silme (Edge Function) |
| **Bebek profili** | Ad, soyad, doğum tarihi/saati/yeri, kilo, boy, profil ve kapak fotoğrafı, kısa hikâye; otomatik yaş ("18 günlük", "3 aylık 12 günlük", "1 yaş 4 aylık") |
| **Birden fazla çocuk** | Üst bardan aktif çocuk değiştirme; her çocuğun timeline'ı, albümü, aile ilişkileri, ilkleri ve kitabı ayrıdır. Kardeşin ailesindeki kişileri doğrudan ekleme |
| **Aile** | Bebek başına aile çemberi; Anne, Baba, Abla, Abi, Teyze, Hala, Dayı, Amca, Anneanne, Babaanne, Dede, Diğer (özel etiket) |
| **Davet** | 10 karakterlik benzersiz kod + paylaşılabilir bağlantı (`bebegimin://invite/KOD`), süre (1/7/30 gün), isteğe bağlı e-postaya bağlama, iptal, durum takibi |
| **Yetkiler** | 14 granüler yetki (görüntüleme, anı/fotoğraf/video ekleme, yorum, kilometre taşı, mektup, kitap, davet, üye yönetimi …); yönetici ataması; **hepsi RLS ile sunucuda uygulanır** |
| **Ana sayfa** | "Defne bugün 184 günlük ❤️", ilk yıl ilerlemesi, hızlı erişim, bir yıl önce bugün, son anılar, yaklaşan önemli günler, ilkler, istatistikler |
| **Zaman tüneli** | Kronolojik, yaş dönemi + ay başlıkları, filtreler (anı / ilk / mektup / İlk Yılım), sonsuz kaydırma, geçmiş tarihli anı ekleme |
| **Fotoğraf / video** | Kamera veya galeriden tekli/çoklu fotoğraf ve video; cihazda sıkıştırma + EXIF (konum) temizleme; **kalıcı, kaldığı yerden devam eden yükleme kuyruğu**; açıklama, tarih, etiket, favori, "kitaba dahil et"; tam ekran görüntüleyici + video oynatıcı |
| **İlklerim** | 17 hazır kilometre taşı + özel ilkler; tarih, açıklama, fotoğraf/video, aile notları |
| **Aile mesajları** | Bebeğe mektuplar (yazar, akrabalık, tarih, metin, isteğe bağlı fotoğraf) |
| **Zaman kapsülü** | 5./10./18. yaş veya özel tarih; içerik açılış gününe kadar **veritabanından hiç kimseye dönmez** |
| **Takvim** | Ay görünümü, içerik türüne göre renkli işaretler, güne dokununca o günün anı/ilk/mektup/fotoğrafları |
| **Arama** | Metin, yıl, ay, tarih aralığı, içerik türü (anı/ilk/mektup/fotoğraf/video), aile üyesi, favoriler, İlk Yılım |
| **İlk Yılım kitabı** | Otomatik bölümler, düzenleyici, önizleme, A4 / 21×21 / 30×30 cm baskıya hazır PDF, sürümleme ("Kitabı güncelle") |
| **Bildirimler** | Uygulama içi bildirim kutusu (realtime rozet), ay dönümü/doğum günü, "bir yıl önce bugün", "Teyzesi yeni bir anı ekledi", "İlk Yılım kitabın hazır"; isteğe bağlı FCM push |
| **Çevrimdışı** | Son görülen veriler önbellekte, görülen fotoğraflar disk önbelleğinde, çevrimdışı bandı, retry durumları, yarıda kalan yüklemeler otomatik devam eder |
| **Tasarım** | Kayısı/adaçayı/krem pastel palet (cinsiyet kalıbı yok), Nunito + Lora, yuvarlak kartlar, büyük fotoğraflar, **dark mode** |

---

## Mimari

```
lib/
├── main.dart                 # bootstrap: intl, SharedPreferences, Supabase.initialize
├── app/                      # uygulama kabuğu
│   ├── app.dart              # MaterialApp.router, tema, TR yerelleştirme, davet deep link'leri
│   ├── router.dart           # go_router + oturum/onboarding yönlendirmeleri
│   ├── shell.dart            # alt navigasyon (Ana Sayfa · Anılar · + · Takvim · Aile) ve "+" menüsü
│   ├── session.dart          # şifre kurtarma / bekleyen davet durumu
│   ├── env.dart              # --dart-define değerleri
│   └── theme.dart            # açık / koyu tema
├── core/                     # özellikten bağımsız altyapı
│   ├── errors/               # AppException: Supabase/ağ hatalarını Türkçe mesaja çevirir
│   ├── cache/                # LocalCache (network-first, çevrimdışı yedek)
│   ├── storage/              # SignedUrlCache (private bucket → imzalı URL)
│   ├── network/              # bağlantı durumu
│   ├── content/              # contentRevision: değişiklik sonrası listeleri yeniler
│   ├── utils/                # BabyAge, FirstYearPeriod, Dates, Turkish, Validators (saf Dart)
│   └── widgets/              # durum widget'ları, StorageImage, avatar, form alanları
└── features/<özellik>/
    ├── domain/               # modeller ve saf iş kuralları (test edilebilir)
    ├── data/                 # Supabase repository'leri
    ├── application/          # Riverpod provider/notifier'ları
    └── presentation/         # ekranlar ve widget'lar
```

Özellikler: `auth`, `profile`, `babies`, `family`, `memories` (zaman tüneli), `media` (albüm, yükleme kuyruğu), `milestones`, `letters`, `capsules`, `calendar`, `search`, `home`, `book`, `notifications`, `settings`.

**Kararlar**

- **State management: Riverpod 3** (kod üretimi olmadan). `FutureProvider`/`AsyncNotifier` + aile (family) provider'ları; UI iş mantığı içermez.
- **Navigasyon: go_router** – `StatefulShellRoute` ile sekmeler durumunu korur; yönlendirme (redirect) oturum → profil → bebek/davet → ana sayfa zincirini uygular.
- **Saf domain katmanı:** yaş hesabı, ilk 365 gün, kitap içerik seçimi (`BookComposer`), PDF dizgisi (`BookPdfBuilder`) Flutter'a bağlı değildir; birim testlerle doğrulanır ve arka plan isolate'inde çalışır.
- **Güvenlik sunucuda:** Uygulamadaki yetki kontrolleri yalnızca UX içindir; asıl karar PostgreSQL RLS ve `SECURITY DEFINER` fonksiyonlardadır.

---

## Kullanılan teknolojiler

| Katman | Paket / Teknoloji |
|---|---|
| UI | Flutter 3.47, Material 3, `flutter_localizations` (tr_TR) |
| State | `flutter_riverpod` 3 |
| Yönlendirme | `go_router` 18, `app_links` |
| Backend | Supabase (Auth, PostgreSQL 15+, Storage, Realtime, Edge Functions) – `supabase_flutter` |
| Medya | `image_picker`, `flutter_image_compress` (native, EXIF temizleme), `video_player`, `cached_network_image` |
| Kitap | `pdf` (dizgi), `printing` (önizleme/yazdırma/paylaşma), `share_plus` |
| Diğer | `table_calendar`, `connectivity_plus`, `shared_preferences`, `intl`, `uuid` |
| Push (isteğe bağlı) | `firebase_core`, `firebase_messaging` + `send-push` Edge Function (FCM HTTP v1) |
| Fontlar | Nunito, Lora (OFL, `assets/fonts`, Türkçe karakter kapsamı doğrulandı) |

---

## Supabase şeması ve güvenlik

Migration'lar: `supabase/migrations/`

| Dosya | İçerik |
|---|---|
| `…0100_foundation.sql` | `pg_trgm`, `set_updated_at`, `profiles` + yeni kullanıcı tetikleyicisi |
| `…0200_babies_family.sql` | `permissions` kataloğu, `babies`, `family_members`, `family_invitations`, yetki yardımcıları, `create_baby`, `preview/accept/revoke_invitation`, `add_member_from_sibling` |
| `…0300_content.sql` | `milestone_types`, `milestones`, `memories`, `letters`, `media`, `comments`, `favorites`, `time_capsules` + `time_capsule_contents`, `storage_cleanup_queue`, `create_time_capsule` |
| `…0400_books.sql` | `book_projects`, `book_pages`, `book_items`, `book_exports`, `register_book_export` |
| `…0500_notifications_activity.sql` | `notifications`, `device_tokens`, `activity_logs`, içerik tetikleyicileri, `run_daily_jobs` (+ pg_cron zamanlaması) |
| `…0600_views_rpc.sql` | `timeline_entries` görünümü (`security_invoker`), `baby_stats`, gizlilik RPC'leri (yalnızca service role) |
| `…0700_storage.sql` | Private bucket'lar ve `storage.objects` politikaları |

**İlişki modeli (özet)**

```
auth.users ─1:1─ profiles
babies ─< family_members >─ profiles        (yakınlık + is_admin + permissions[] bebek başına)
babies ─< family_invitations
babies ─< memories ─< media (memory_id | milestone_id | letter_id)
babies ─< milestones >─ milestone_types (sistem + bebeğe özel)
babies ─< letters, comments, favorites(kullanıcı başına), time_capsules ─1:1─ time_capsule_contents
babies ─< book_projects ─< book_pages ─< book_items ; book_projects ─< book_exports
notifications, device_tokens (kullanıcı başına) ; activity_logs (bebek başına)
```

**RLS nasıl çalışır?**

- Tüm tablolarda RLS açık; `anon` rolüne hiçbir tablo yetkisi verilmez, `authenticated` rolü yalnızca politikaların gerektirdiği komutları alır (GRANT + RLS + policy birlikte).
- `is_baby_member`, `is_baby_admin`, `has_baby_permission(baby, 'perm')` fonksiyonları `SECURITY DEFINER` + sabit `search_path` ile özyinelemesiz kontrol yapar. Yöneticiler tüm yetkilere sahip sayılır.
- Örnek: `memories` SELECT → `view_memories`; INSERT → `add_memory`; UPDATE/DELETE → (yazar ve `edit_own_memory`) veya `manage_content`.
- **IDOR koruması:** her alt tablo `(parent_id, baby_id)` bileşik yabancı anahtarıyla ebeveynine bağlanır; başka bebeğin anısına fotoğraf/yorum/kitap öğesi eklemek şema seviyesinde imkânsızdır. Yazar/uploader alanları tetikleyicilerle zorlanır (sahte `author_id` yazılamaz).
- **Yetki yükseltme koruması:** yönetici olmayan üyeler yönetici atayamaz, kendi yetkisini değiştiremez, yönetim yetkisi veremez; ailenin son yöneticisi silinemez/düşürülemez.
- **Davetler:** kodlar `gen_random_uuid()` baytlarından üretilir (32 karakterlik alfabe, ~10¹⁵ kombinasyon), kabul işlemi satırı kilitler, süre/durum/e-posta kontrolü yapar, tek kullanımlıktır.
- **Zaman kapsülü:** içerik ayrı tabloda; SELECT politikası `open_on <= current_date` olmadan satır döndürmez (yazar dahil). INSERT/UPDATE yetkisi yoktur, yalnızca `create_time_capsule` RPC'si yazar.

**Storage güvenliği**

- Bucket'lar **private**: `baby-media`, `books`, `avatars`. Public URL kullanılmaz; uygulama 1 saatlik imzalı URL alır (imzalama da SELECT politikasına tabidir).
- Yol şeması veritabanına bağlıdır: `baby-media/<baby_id>/<media_id>/<dosya>`. Okuma için `media` satırının o bebeğe ait, `ready` durumda ve kullanıcının `view_album` yetkisi olması gerekir. Yazma için önce `media` satırı (`uploading`) oluşturulur; o satırın sahibi dışında kimse o yola yükleyemez.
- Profil/kapak: `<baby_id>/profile/…` (`manage_baby`), kapsül fotoğrafı: `<baby_id>/capsules/<id>/photo.jpg` (açılış tarihine kadar okunamaz), kitaplar: `<baby_id>/<project_id>/*.pdf`, avatarlar: `<user_id>/…`.
- Satırlar silindiğinde (cascade) dosyalar `storage_cleanup_queue`'ya düşer; `storage-cleanup` Edge Function'ı temizler.
- **Service role key mobil uygulamada yoktur**; yalnızca Edge Function'lar (Supabase tarafından enjekte edilir) kullanır.

---

## İlk Yılım kitabı / PDF

1. **Dönem:** `FirstYearPeriod` – doğum günü 1. gün, 365. gün = doğum + 364 gün. Hamilelik anıları (doğumdan ≤310 gün önce) "Hoş geldin", ilk doğum günü "Bir Yaşındayım" bölümüne gider. Artık yılda 1. yaş gününe kadar olan gün kaybolmaz.
2. **Varsayılan plan (`BookComposer`):** Kapak → Hoş geldin → Doğum bilgilerim → 1.–12. Ayım → İlklerim → Ailemden Bana → Bir Yaşındayım → Arka kapak. İçerik, **anının tarihine göre** (eklenme tarihine göre değil) bölümlere dağıtılır; bu yüzden çocuk 2 yaşındayken eklenen ilk-yıl anısı da kitaba girer. `include_in_book=false` içerikler, tamamlanmamış yüklemeler ve küçük resmi olmayan videolar dışarıda kalır. Kalabalık aylarda en iyi 12 fotoğraf (favoriler, anıya bağlı olanlar önce) görünür, diğerleri **gizli** eklenir.
3. **Editör:** kitap başlığı/alt başlığı, ölçü, kapak fotoğrafı, arka kapak yazısı; bölüm sırasını sürükle-bırak, bölümü gizle, bölüm notu (aylık özet), içerik ekle/çıkar/sırala, fotoğraf açıklaması, özel sayfa.
4. **Kitabı güncelle:** `sync` yalnızca projede hiç bulunmamış yeni ilk-yıl içeriklerini ekler; kullanıcının gizleme/sıralama kararları korunur. Her PDF `register_book_export` ile yeni sürüm olarak kaydedilir (sürüm numarası sunucuda atomik artar).
5. **PDF (`BookPdfBuilder`):** sayfa = kesim ölçüsü + her kenarda 3 mm taşma payı (bleed), `/TrimBox` ve `/BleedBox` tanımlı; güvenli kenar boşluğu; Nunito + Lora gömülü (Türkçe karakterler); iç sayfalarda sayfa numarası; çift sayfa sayısı (gerekirse "Notlar" sayfası); emoji PDF'te kutu yerine temizlenir.
6. **Performans:** fotoğraflar tek tek indirilip native tarafta küçültülür (baskı: kısa kenar 2000 px, önizleme: 1000 px) ve disk önbelleğine yazılır; PDF dizgisi `Isolate.run` ile arka planda yapılır; ilerleme çubuğu gösterilir.
7. **Çıktı:** uygulama içi önizleme (`printing` / `PdfPreview`), yazdırma, sistem paylaşım menüsü ("Dosyalara kaydet" dahil); yayınlanan sürümler aile tarafından (`view_album`) indirilebilir.

---

## Kurulum

### 1. Flutter

- Flutter **3.47+** (Dart 3.13+) – `flutter --version`
- Android: Android Studio + SDK (API 35), JDK 17
- iOS: macOS, Xcode 16+, CocoaPods

```bash
flutter pub get
```

### 2. Supabase projesi

- [supabase.com](https://supabase.com) üzerinde bir proje oluşturun (bölge olarak kullanıcılarınıza yakın, ör. Frankfurt).
- **Project Settings → API**: `Project URL` ve `anon`/`publishable` key uygulamaya girer. `service_role` key **asla** uygulamaya konmaz.
- Yerel geliştirme için: [Supabase CLI](https://supabase.com/docs/guides/cli) + Docker → `supabase start`.

### 3. Migration'ları çalıştırma

```bash
# Yerel (Docker): migration'lar + seed.sql (demo verisi)
supabase start
supabase db reset

# Uzak proje (seed ÇALIŞMAZ):
supabase link --project-ref <PROJECT_REF>
supabase db push
```

Migration'lar boş bir Supabase projesinde sırayla çalışacak şekilde yazılmıştır. CLI kullanmıyorsanız `supabase/migrations/*.sql` dosyalarını sırayla SQL Editor'de çalıştırabilirsiniz.

### 4. Storage

`…0700_storage.sql` bucket'ları (**private**) ve politikaları oluşturur – dashboard'da ek işlem gerekmez. Kontrol: *Storage → Buckets* altında `baby-media`, `books`, `avatars` "Public" olmamalı.

- Ücretsiz planda dosya başı üst sınır 50 MB'tır; video limiti için planınızı veya *Storage → Settings → Upload file size limit* değerini ve uygulamadaki `MAX_VIDEO_MB` değerini birlikte ayarlayın.

### 5. Auth ayarları

*Authentication → URL Configuration*

- **Site URL:** `bebegimin://login-callback`
- **Redirect URLs:** `bebegimin://login-callback` (ve kullanacaksanız https adresiniz)

*Authentication → Providers → Email*: "Confirm email" açık, minimum şifre 8 karakter.
*Authentication → Emails*: şablonları Türkçeleştirebilir, üretimde kendi SMTP sağlayıcınızı tanımlayın (Supabase'in varsayılan SMTP'si saatlik düşük limitlidir).

### 6. Edge Function'lar

| Fonksiyon | Görev | JWT |
|---|---|---|
| `privacy-actions` | Hesap silme, bebeği tüm dosyalarıyla silme | Kullanıcı JWT'si |
| `send-push` | `notifications` INSERT → FCM push | `x-webhook-secret` |
| `storage-cleanup` | Kuyruktaki sahipsiz dosyaları silme | `x-cleanup-secret` |

```bash
supabase functions deploy privacy-actions
supabase functions deploy send-push --no-verify-jwt
supabase functions deploy storage-cleanup --no-verify-jwt

# Sunucu tarafı gizli değerler (.env.example'daki "Edge Function secrets" bölümü)
supabase secrets set PUSH_WEBHOOK_SECRET=... STORAGE_CLEANUP_SECRET=...
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"   # push kullanılacaksa
```

### 7. Zamanlanmış işler

`run_daily_jobs()` her gün: ay dönümü / doğum günü bildirimleri, "bir yıl önce bugün", ilk yıl tamamlanınca "kitabın hazır", açılan zaman kapsülleri, süresi dolan davetler, yarım kalmış yükleme kayıtlarının temizliği.

- *Database → Extensions* altında **pg_cron**'u açın. Migration, pg_cron mevcutsa işi otomatik zamanlar (`06:00 UTC`). Sonradan açtıysanız:

```sql
select cron.schedule('bebegimin-daily-jobs', '0 6 * * *', 'select public.run_daily_jobs()');
```

- Dosya temizliği için (**pg_net** eklentisi açık olmalı):

```sql
select cron.schedule('bebegimin-storage-cleanup', '17 * * * *', $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/storage-cleanup',
    headers := jsonb_build_object('x-cleanup-secret', '<STORAGE_CLEANUP_SECRET>')
  );
$$);
```

### 8. Push bildirimleri (isteğe bağlı)

Push olmadan da bildirimler uygulama içinde (realtime rozetle) çalışır.

1. Firebase projesi oluşturun, Android (`app.bebegimin.bebegimin_ilk_yili`) ve iOS uygulamalarını ekleyin.
2. `FIREBASE_*` değerlerini `env/<ortam>.json` dosyasına yazın (google-services.json / GoogleService-Info.plist **gerekmez**; seçenekler `--dart-define` ile verilir).
3. iOS: Apple Developer'da APNs anahtarı oluşturup Firebase'e yükleyin; Xcode'da *Push Notifications* ve *Background Modes → Remote notifications* yeteneklerini açın.
4. Firebase'de "Firebase Cloud Messaging API" rolüne sahip bir service account oluşturup JSON'unu `FCM_SERVICE_ACCOUNT` secret'ı olarak kaydedin.
5. *Database → Webhooks*: tablo `public.notifications`, olay `INSERT`, tür *Supabase Edge Function* → `send-push`, HTTP header `x-webhook-secret: <PUSH_WEBHOOK_SECRET>`.

Push içeriğinde yalnızca başlık ve uygulama içi rota gider; fotoğraf veya anı metni Google sunucularına gönderilmez.

### 9. Ortam değişkenleri

`.env.example` tüm değişkenleri açıklar. Flutter build-time değerleri JSON'dan okur:

```bash
cp env/example.json env/dev.json     # env/*.json git'e girmez (örnekler hariç)
# SUPABASE_URL ve SUPABASE_ANON_KEY'i doldurun
```

---

## Çalıştırma

```bash
# Android emülatörü / cihaz
flutter run --dart-define-from-file=env/dev.json

# iOS simülatörü / cihaz (ilk seferde)
cd ios && pod install && cd ..
flutter run --dart-define-from-file=env/dev.json
```

- Yerel Supabase'e Android emülatöründen bağlanırken `SUPABASE_URL=http://10.0.2.2:54321`, iOS simülatöründen `http://127.0.0.1:54321` kullanın (`env/demo.example.json`).
- Doğrulama e-postaları yerelde Inbucket'e düşer: http://127.0.0.1:54324

## Demo verisi

`supabase/seed.sql` yalnızca **yerel** `supabase db reset` ile çalışır (uzak `db push` çalıştırmaz; ayrıca `app.environment=production` ayarında kendini durdurur). İçerik: Defne (13 aylık, ilk yılı tamamlanmış), kardeşi Ege, başka bir ailenin bebeği Can; anne/baba/teyze hesapları, 14 anı (1 yaşından sonra eklenmiş geçmiş tarihli anı dahil), 9 ilk, 3 mektup, 2 zaman kapsülü (biri mühürlü), fotoğraf metadata'sı, yorumlar, bekleyen bir davet (`DEDE2-DAVET`).

| Hesap | Şifre | Rol |
|---|---|---|
| anne@example.com | Demo1234! | Defne & Ege – yönetici |
| baba@example.com | Demo1234! | Defne & Ege – yönetici |
| teyze@example.com | Demo1234! | Defne – sınırlı yetki |
| baska@example.com | Demo1234! | Başka aile (izolasyon denemesi) |

Uygulamayı `DEMO_MODE=true` ile çalıştırırsanız giriş ekranında bu hesaplar için kısayollar görünür. Fotoğraflar yalnızca metadata olduğu için yer tutucu ile gösterilir.

## Testler

```bash
flutter analyze
flutter test                     # birim + widget testleri

# Veritabanı: migration'lar + seed + 160+ RLS/iş kuralı doğrulaması
# (Docker gerekmez; düz PostgreSQL 15/16 ve Supabase uyumluluk katmanı)
PGHOST=localhost PGUSER=postgres ./supabase/tests/run_db_tests.sh
```

| Test | Kapsam |
|---|---|
| `test/core/baby_age_test.dart` | Yaş etiketleri, ay sonu/artık yıl, DST, yaş dönemleri |
| `test/core/first_year_test.dart` | 365 gün, artık yıl, ay bölümleri, geçmiş tarihli anı, ilerleme |
| `test/family/*` | Granüler yetkiler (RLS ile aynı kurallar), rol ön ayarları, davet kodu/bağlantı/durum |
| `test/book/book_composer_test.dart` | Kitap içerik seçimi, tarih aralığı, 1 yaş sonrası eklenen ilk-yıl anısı, fotoğraf sınırı, kapak, güncelleme (sync) |
| `test/book/book_pdf_test.dart` | 3 formatta gerçek PDF üretimi, çift sayfa, TrimBox/BleedBox, gömülü fontlar |
| `test/widget/*` | Uygulama açılışı, zaman tüneli kartı, yetki editörü, durum ekranları |
| `supabase/tests/10_isolation_test.sql` | Farklı ailelerin veri/Storage izolasyonu, IDOR denemeleri, anon erişimi |
| `supabase/tests/20_permissions_test.sql` | Yetkiler, yazar sahteciliği, yetki yükseltme, son yönetici |
| `supabase/tests/30_invitations_test.sql` | Davet önizleme/kabul/iptal/süre/e-posta, kardeş ailesinden ekleme |
| `supabase/tests/40_capsules_dates_test.sql` | Mühürlü kapsül, tarih kuralları, 1 yaş sonrası geçmiş tarihli anı ve yükleme |
| `supabase/tests/50_storage_books_test.sql` | Storage yol politikaları, kitap sürümleme |
| `supabase/tests/60_account_notifications_test.sql` | Bildirimler, tercih, günlük iş, hesap/bebek silme |

Bir PDF örneği üretmek için: `SAMPLE_DIR=/tmp/ornek flutter test test/book/render_sample.dart` (klasörde `img0.jpg … img5.jpg` bulunmalı).

GitHub Actions (`.github/workflows/ci.yml`): analyze + testler, PostgreSQL üzerinde veritabanı testleri, Android APK build, PR'larda iOS (codesign'sız) build.

## Build ve release hazırlığı

```bash
# Android
flutter build appbundle --release --dart-define-from-file=env/prod.json
# iOS
flutter build ipa --release --dart-define-from-file=env/prod.json
```

Kontrol listesi:

- [ ] `applicationId` / iOS Bundle ID'yi kendi alan adınıza göre değiştirin (`android/app/build.gradle.kts`, Xcode).
- [ ] Android imzalama: `android/key.properties` + keystore (git'e girmez; `build.gradle.kts` otomatik kullanır).
- [ ] iOS: Signing & Capabilities (Team), push kullanılacaksa Push Notifications + Background Modes.
- [ ] Uygulama ikonu ve açılış ekranı (ör. `flutter_launcher_icons`, `flutter_native_splash`).
- [ ] Üretim Supabase: özel SMTP, e-posta şablonları, rate limit'ler, pg_cron/pg_net, Edge Function secret'ları, günlük yedekleme (PITR).
- [ ] App Store / Google Play gizlilik beyanları: çocuk fotoğrafları özel aile verisidir, reklam/izleme yoktur; KVKK aydınlatma metni ve gizlilik politikası URL'si.
- [ ] https davet bağlantıları istenirse Android App Links (`assetlinks.json`) ve iOS Universal Links (`apple-app-site-association`) yayınlayıp `INVITE_LINK_BASE`'i güncelleyin.

## Bilinen sınırlar

- Video küçük resmi üretilmez; videolar ızgarada simgeyle gösterilir ve kitaba yalnızca küçük resmi olanlar girebilir.
- Büyük videolar tek parça yüklenir (resumable/TUS yok); kesintide yükleme baştan tekrar denenir.
- Yerel önbellek şifrelenmemiş `SharedPreferences` + görüntü disk önbelleğidir (cihaz kilidine güvenir).
- Zaman kapsülü "mühürü" veritabanı politikası ile sağlanır; veritabanı yöneticileri (service role) teknik olarak içeriği okuyabilir.
- Push bildirimleri için Firebase ve APNs yapılandırması manuel yapılmalıdır.

## Lisans

Uygulama kodu: proje sahibinin tercihine bırakılmıştır. Fontlar: SIL Open Font License 1.1 (`assets/fonts/OFL-*.txt`).
