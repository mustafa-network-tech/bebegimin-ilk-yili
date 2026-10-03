# Faz 04 Sonuç Raporu

- Durum: COMPLETE
- Başlangıç commit'i: `cb5f678`
- Bitiş commit'i: Faz 4 + Faz 5 ortak commit'i (kullanıcı talebi; hash için `git log`)
- Eklenen migration: Yok. Bu faz yalnız istemci tarafıdır; Faz 3 backend kilidi aynen korunur.

## Değişen dosyalar

- **Yeni dosyalar:**
  - `lib/core/content/lifecycle_revision.dart`
  - `lib/features/babies/presentation/lifecycle_widgets.dart`
  - `lib/features/babies/presentation/lifecycle_screen.dart`
  - `test/babies/lifecycle_experience_test.dart`
- **Lifecycle katmanı:**
  - `baby_lifecycle.dart`: önbellek için JSON'a çevirme, İstanbul iş günü hesabı, güvenli sıkılaştırma kuralı.
  - `baby_lifecycle_repository.dart`: kullanıcı ve bebek bazında çevrimdışı önbellek.
  - `baby_lifecycle_providers.dart`: gece yarısı yenileme, test için enjekte edilebilir saat, `babyArchiveLockedProvider`.
- **Yetki modeli:**
  - `permission.dart`: `MemberAccess.archiveLocked`, `writesArchive`, `canDeleteComment`, `canDeleteCapsule`.
  - `family_providers.dart`: `accessProvider` artık lifecycle bilgisini de içeriyor.
- **Ekranlar:**
  - `router.dart`, `shell.dart`
  - `home_screen.dart`, `baby_form_screen.dart`, `calendar_screen.dart`
  - Kapsül, yorum, mektup ve zaman tüneli ekranları
  - `form_fields.dart`: salt okunur tarih ve saat alanı
  - `feedback.dart`, `upload_queue.dart`
  - `baby.dart`: yaklaşan günler başlığı
- **Yapılandırma:** `env.dart` (`PREMIUM_PREVIEW`), `env/example.json`, `env/demo.example.json`, `.env.example`

## Uygulananlar

- **Tek karar noktası:**
  - `accessProvider(babyId)`, üyelik izinlerini sunucu lifecycle'ı ile birleştirir.
  - KİLİTLİ ya da henüz doğrulanmamış arşivde içerik yazan tüm izinler kapanır: anı, medya, yorum, ilk, mektup, içerik yönetimi, profil yönetimi.
  - Böylece büyük `+`, ekleme, düzenleme ve silme aksiyonları tüm ekranlarda kendiliğinden kaybolur.
  - Üyelik yönetimi, davet ve favoriler açık kalır.
  - Durum bilinmiyorsa (yükleniyor, önbellek yok) arşiv kilitli sayılır; kullanıcıya sunucunun reddedeceği bir aksiyon gösterilmez.
- **Sunucu kaynaklı durum:**
  - Lifecycle özeti her zaman bebek kimliğiyle alınır ve kullanıcı+bebek anahtarıyla çevrimdışı önbelleğe yazılır.
  - Şu durumlarda yenilenir:
    - uygulama ön plana döndüğünde
    - sunucu `lifecycle_locked` ile bir yazmayı reddettiğinde (`showError` ve yükleme kuyruğu)
    - İstanbul gece yarısında
  - **Cihaz saati bir profili hiçbir zaman açamaz.** Yalnızca "kapanış tarihi geçti" kararını sıkılaştırabilir. Böylece eski bir AKTİF önbellek, gece yarısını geçince KİLİTLİ görünür.
- **Ana sayfa:**
  - AKTİF: sunucudan gelen kalan gün sayacı ve kapanış tarihi; onaylı uzatma dahildir (3+30 örneği 33 gün gösterir).
  - KİLİTLİ: "İlk Yılı tamamlandı" ve kilit açıklaması.
  - Eski kitap kartı ve "Kitabım" kısayolu kaldırıldı; yerine "İlk Yıl" (lifecycle ekranı) kısayolu geldi.
- **Form rotaları:**
  - `LifecycleWriteGuard` şu rotaları sarar: yeni ve düzenleme anı/ilk/mektup formları, yeni kapsül.
  - Derin bağlantıyla gelinse bile form yalnızca sunucu AKTİF dediğinde oluşturulur.
  - KİLİTLİ ise "Arşiv kilitli" ekranı gösterilir.
- **Bebek profil formu:**
  - KİLİTLİ durumda (ya da `manage_baby` yetkisi yoksa) salt okunur: bilgilendirme şeridi var, alanlar düzenlenemez, Kaydet düğmesi gizli.
  - Bebeği silme (yasal silme) yöneticide açık kalır.
  - Doğum tarihi yalnızca şu koşulların hepsinde düzenlenebilir: Anne/Baba yöneticisi, profil AKTİF, henüz içerik yok. Diğer durumlarda gerekçe alanın altında gösterilir.
- **Premium alan:**
  - `/book` rotaları `PremiumRouteGate` ile sarıldı.
  - AKTİF profilde kitap ekranları hiç açılmaz; kapanış tarihi gösterilir.
  - KİLİTLİ profilde "Yakında" yer tutucusu ve ana sayfada yer tutucu kart var. Satın alma veya üretim yok.
  - Mevcut kitap motoru silinmedi. Yalnız dahili test için `PREMIUM_PREVIEW=true` ile KİLİTLİ profilde açılabilir (varsayılan `false`).
  - AKTİF profilde kitabı tanıtan "İlk Yılım kitabı hazır olacak" metni "İlk yıl tamamlanıyor" olarak değiştirildi.
- **Uzatma ekranı** (`/babies/:babyId/lifecycle`):
  - Durum, standart ve etkin kapanış tarihleri, onaylı uzatma, İstanbul 00:00 kuralı.
  - Talep formu yalnızca şu koşullarda görünür: talep hakkı var, kullanıcı Anne/Baba yöneticisi.
  - 1–30 gün kaydırıcı, "tek hak" uyarısı, onay diyaloğu. Çift gönderim engelli.
  - Bekleyen, onaylı, reddedilen ve süresi dolan talepler için ayrı metin var; ikinci form açılmaz.
  - Sunucu retleri Türkçe mesaja çevrilir ve ardından sunucu durumu yenilenir (idempotent).
- **Boş durumlar:** Kilitli arşivde "+ düğmesine dokunun" gibi ekleme çağrıları gösterilmez (ana sayfa, zaman tüneli, mektup, kapsül). Takvimdeki "Bu güne anı ekle" ve ana sayfadaki "ilk" kısayolları da izne bağlandı.
- **Erişilebilirlik:** Kartlarda anlamlı ekran okuyucu etiketleri, kaydırıcı değer okuması (`gün`), salt okunur şeritte `liveRegion`. Tüm metinler Türkçe; tarih biçimi `tr_TR`.

## Kabul kriterleri ve kanıtlar

`test/babies/lifecycle_experience_test.dart` dosyasındaki 19 yeni test:

- **İstanbul tarihi:** 20:59:59Z / 21:00Z sınırı ve bir sonraki iş gününe kalan süre doğru hesaplanıyor.
- **Önbellek güvenliği:**
  - Eski AKTİF özet, cihaz kapanışı geçince KİLİTLİ oluyor.
  - Geri alınmış cihaz saati KİLİTLİ profili açamıyor ve gün eklemiyor.
  - Özet çevrimdışı önbelleğe yazılıp geri okunduğunda değişmiyor.
- **Gece yarısı:** Gece sınırı geçildikten sonra yapılan yenileme, sunucu hâlâ eski AKTİF cevabı dönse bile profili KİLİTLİ yapıyor. Sunucu iki kez sorgulanıyor.
- **İzinler:**
  - KİLİTLİ durumda içerik yazan tüm izinler kapalı; görüntüleme, davet ve üye yönetimi açık.
  - Kendi mektubu, yorumu, kapsülü ve medyası üzerinde de düzenleme/silme yok.
- **İki bebek:** Defne KİLİTLİ, Ege AKTİF; izinler ve lifecycle birbirine karışmıyor. Durum bilinmiyorsa oluşturma kapalı.
- **Ana sayfa kartı:** AKTİF'te "33 gün kaldı (onaylı uzatma dahil)", KİLİTLİ'de "İlk Yılı tamamlandı".
- **Form koruyucusu:** Derin bağlantı KİLİTLİ arşivde formu açmıyor, AKTİF'te açıyor.
- **Premium:** AKTİF'te kitap ekranı açılmıyor; KİLİTLİ'de "Yakında" yer tutucusu gösteriliyor.
- **Uzatma:** Ebeveyn tek hakla 1–30 gün isteyebiliyor; mevcut talep ikinci formu açmıyor; ebeveyn olmayan üye talep edemiyor.

## Çalıştırılan testler ve sonuçları

- `flutter analyze --no-pub`: başarılı, sorun yok.
- `flutter test --no-pub`: başarılı, 89 test (19'u yeni).
- `dart format --output=none --set-exit-if-changed lib test`: başarılı.
- `supabase/tests/run_db_tests.sh` (yerel PostgreSQL 16.4): başarılı, 315 SQL doğrulaması ve yarış testi. Regresyon yok.

## Çalıştırılamayan testler / neden

- Gerçek cihaz veya emülatörde uçtan uca test yapılmadı. Doğrulanmayanlar:
  - uygulama ön plana döndüğünde yenileme
  - gerçek derin bağlantı
  - arka planda gece yarısı zamanlayıcısı
- Bu davranışlar sağlayıcı ve widget testleriyle doğrulandı. Hedef ortamda manuel kontrol önerilir.

## Güvenlik notları

- UI gizleme bir güvenlik kontrolü değildir; tüm yazmalar Faz 3 backend kilidiyle korunmaya devam ediyor.
- `PREMIUM_PREVIEW` yalnızca KİLİTLİ profilde ve derleme zamanında açılabilir; AKTİF profilde hiçbir koşulda kitap açılmaz. Üretim derlemelerinde `false` kalmalı.
- **Bilinen boşluk (Faz 9):** Sunucu tarafında kitap tabloları, RPC'ler ve `books` bucket'ı AKTİF profilde hâlâ açık. UI kapatıldı, backend kapısı Faz 9'da kapanacak.

## Rollback adımları

- İstemci değişikliğini geri almak Faz 3 backend güvenliğini etkilemez.
- Tek karar noktası `accessProvider` olduğu için lifecycle davranışı gerekirse orada devre dışı bırakılabilir.

## Bilinen riskler

- İlk açılışta lifecycle yüklenene kadar `+` düğmesi kısa bir süre görünmez (bilinçli, temkinli varsayılan).
- Çevrimdışı ve önbelleksiz durumda içerik ekleme kapalıdır. Çevrimdışı yükleme kuyruğu, daha önce görülmüş AKTİF bebekler için önbellek sayesinde çalışır.
- "Kitaba dahil et" seçimi ve "İlk Yılım kitabında" etiketi, kaynak içerik alanı (`include_in_book`) olarak AKTİF profilde görünmeye devam ediyor. Bunlar satın alma, önizleme veya üretim girişi değil.
- Uzatma talebi hatalarının eşlemesi sunucu mesaj metnine dayanıyor (`already requested`, `before base close`). İleride bu hatalara `hint` eklenmesi önerilir.

## Faz 5'in giriş koşulları

- Faz 4 tamamlandı: AKTİF/KİLİTLİ deneyimi ayrı; tüm mutasyon ekranları backend gerçeğiyle uyumlu.
- Faz 5 (Super Admin operasyon paneli), `decide_baby_extension` ve `correct_baby_birth_date` RPC'lerini kullanacak. `BabyLifecycleRepository.decideExtension` hazır.
