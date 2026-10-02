# Faz 06 Sonuç Raporu

- **Durum:** COMPLETE. Ödeme sağlayıcısı App Store / Google Play uygulama içi abonelik olarak seçildi ve entegre edildi. Mağaza konsol kurulumu ve canlıya alma adımları `docs/operations/store-billing-setup.md` dokümanında.
- **Başlangıç commit'i:** `3b20837`
- **Bitiş commit'i:** Faz 7 ile ortak commit (kullanıcı talebi; hash için `git log`)
- **Eklenen migration'lar:**
  - `supabase/migrations/20260929000300_family_accounts_subscriptions.sql`
  - `supabase/migrations/20260929000400_store_billing_access_gate.sql` (ürün kararları sonrası ek)
- **ADR:** `docs/implementation/ADR/0002-family-accounts-and-subscriptions.md`

## Değişen dosyalar

- **Veritabanı:**
  - Yeni migration
  - `supabase/tests/90_family_accounts_subscriptions_test.sql` (yeni)
  - `supabase/tests/run_db_tests.sh`: kapasite yarış testi eklendi
- **Edge Function:**
  - `supabase/functions/_shared/billing.ts`: sağlayıcı adaptör arayüzü ve mock adaptör
  - `supabase/functions/billing-webhook/index.ts`
  - `supabase/config.toml`
  - `.env.example`: `BILLING_MOCK_SECRET`
- **Flutter:**
  - Yeni `lib/features/subscription/` modülü: models, repository, providers, `family_plan_screen.dart`
  - Aile ekranına "Aile paketi" girişi
  - `/family/plan` rotası
  - Kapasite ve koltuk hata mesajları (`app_exception.dart`)
- **Testler:** `test/subscription/family_plan_test.dart`

## Uygulananlar

### Veri modeli

Tabloların hepsi yalnızca sunucu tarafından yazılır. İstemciler bu tablolara doğrudan erişemez; yalnızca RPC'ler üzerinden okur.

- **Aile hesabı:**
  - `family_accounts`
  - `family_account_members`: rol `parent` veya `family_member`; durum `invited`, `active`, `suspended` veya `removed`
  - `family_account_babies`: her bebek tek bir hesaba bağlı
- **Katalog:**
  - `subscription_plans`: sürümlü, değiştirilemez satırlar
  - `subscription_plan_provider_products`: sağlayıcı ürün eşlemesi
- **Abonelik ve ödeme:**
  - `subscriptions`: hesap başına en fazla bir canlı abonelik
  - `subscription_checkout_intents`
  - `billing_events`: append-only, sağlayıcı olay kimliğine göre benzersiz
- **Eski veri aktarımı:** `family_account_migration_report`

### Katalog

- Small, Normal ve Large paketleri: kapasite 3 / 6 / 12, her pakette 2 ebeveyn koltuğu.
- Aylık fiyatlar `29900 / 36900 / 46900`, yıllık fiyatlar `322920 / 398520 / 506520` TRY kuruş.
- Yıllık fiyat = aylık × 12 × 0,90 kuralı ve aylık/yıllık kapasite eşitliği trigger ile zorunlu. Fiyat değişikliği yeni bir katalog sürümüdür.
- Flutter fiyatları, kapasiteleri ve yıllık tasarrufu yalnızca katalogdan okur.

### Uyumluluk katmanı

- Bebek bazlı `family_members` (yakınlık ve izinler) aynen korunur. Hesap üyeliği bunun üzerine eklenir.
- Kişi, hesabın ilk bebeğine katıldığında hesapta etkinleşir; son bebeğinden ayrıldığında `removed` olur.
- Ebeveyn = ilgili bebekte `anne`/`baba` yakınlığı ve yönetici yetkisi. Kardeşe eklenen mevcut üye ikinci bir koltuk kullanmaz.

### Koltuk ve kapasite kontrolü

Aktivasyon anında yapılır: davet kabulü, kardeşten üye ekleme ve bebek oluşturma. Hesap satırı kilitlenerek eşzamanlı aktivasyonlar sıraya girer.

- Üçüncü ebeveyn reddedilir: `parent_seats_full`.
- Canlı paket varsa kapasite her zaman uygulanır: `family_capacity_full`.
- Abonelik zorunluluğu bayrağı açıksa pakete sahip olmayan hesap yeni aile üyesi ekleyemez: `subscription_required`. Bayrak varsayılan olarak kapalıdır.

### Bebek oluşturma

`create_baby`, bebeği oluşturan kişinin hesabına atomik olarak bağlar (yeni opsiyonel parametre: `p_family_account_id`):

- Kişi tek bir hesapta ebeveynse bebek o hesaba eklenir.
- Hiçbir hesapta değilse yeni hesap oluşturulur.
- Birden fazla hesapta ebeveynse seçim ister (`family_account_ambiguous`).

İkinci ebeveynin davet kabulü, koltuk kontrolüyle aynı transaction'da işlenir.

### Plan yükseltme ve düşürme

- Yükseltme, sağlayıcı olayı gelince yeni kapasiteyi hemen açar.
- Kapasitenin altına düşürme uygulanır ama abonelik `over_capacity` olarak işaretlenir. Hiçbir üye, veri veya izin silinmez.
- Aktif üye sayısı kapasiteye inene kadar yeni aile üyesi etkinleşmez; sayı indiğinde bayrak kendiliğinden temizlenir.

### Ödeme olayları

- İstemci yalnızca bir checkout intent açabilir; bunu da yalnızca ebeveyn yapabilir. Aboneliği etkinleştiremez.
- `billing-webhook` Edge Function'ı sağlayıcı adaptörüyle isteği doğrular (mock: HMAC-SHA256 imza). Ardından `billing_apply_event` çalışır:
  - Aynı olay kimliği ikinci kez gelirse `duplicate` döner.
  - Yeni abonelik yalnızca ebeveynin açık intent'i ve eşleşen ürünle oluşur.
  - Başka bir aile hesabının intent'i ya da hesap kimliği içeren olay reddedilir (IDOR).
  - Bilinmeyen durum veya ürün reddedilir.
  - Reddedilen olaylar da hata nedeniyle birlikte saklanır.
- Sağlayıcı durumları iç durumlara çevrilir: `trialing`, `active`, `grace`, `past_due`, `canceled`, `expired`.

### Eski verinin aktarımı

- Yalnızca kesin eşleşmeler otomatik eşlenir: aynı ebeveyn kümesine sahip bebekler tek hesapta toplanır.
- Bir kullanıcı iki farklı ebeveyn kümesinde görünüyorsa o bebekler birleştirilmez; `ambiguous_parent_sets` olarak rapora yazılır. Bağlı bileşen (graph) ile hane birleştirme yapılmaz.
- Ebeveyni olmayan bebek raporda `no_parent` olarak yer alır.
- Eşleme hiçbir üyeliği silmez ve tekrar çalıştırılabilir.
- Raporlanan bebekler için manuel çözüm: `resolve_family_account_mapping`.
- Aktarım migration sırasında bir kez çalışır.

### Flutter: "Aile paketi" ekranı

- Hesap adı; mevcut plan, dönem, durum ve yenileme tarihi.
- Kapsanan tüm bebekler.
- Aile üyesi kapasitesi (kullanılan / toplam) ve ebeveyn koltukları (kapasiteye dahil değil).
- Kişi bazında rol ve durum.
- Aylık/yıllık seçimi; yıllık tasarruf katalogdan hesaplanır.
- Yalnızca ebeveynler "Seç / Yükselt" görür. Kapasitenin altına düşürmede uyarı gösterilir; kapasite aşımı ve dolu kapasite açıkça belirtilir.
- Aile üyelerine "ayrı abonelik gerekmez" bilgisi gösterilir.
- Henüz eşlenmemiş bebek için açıklama gösterilir.
- Aile ekranında kapasite özetiyle kısayol var.

### Lifecycle ve arşiv

- Abonelik lifecycle'ı hiçbir koşulda etkilemez; test ediliyor.
- Abonelik yokken arşiv erişimi değiştirilmedi (ADR'deki ürün kararı).

## Kabul kriterleri ve kanıtlar

Kanıtlar `90_family_accounts_subscriptions_test.sql` (73 doğrulama) ve çalıştırıcıdaki kapasite yarış testinden geliyor.

- **İki ebeveyn tek aboneliği paylaşıyor:**
  - Her ikisi de aynı `parent` rolüne sahip.
  - Aile üyesi kapasitesine sayılmıyorlar.
  - Üçüncü ebeveyn reddediliyor.
- **İkinci bebek fiyatı artırmıyor:** İki bebek tek hesapta, tek abonelikle kapsanıyor.
- **Kapasite:**
  - Small pakette 4. aile üyesi reddediliyor ve davet bekler durumda kalıyor.
  - Normal'e yükseltme 4. üyeyi mümkün kılıyor.
  - Kapasitenin altına düşürme kimseyi silmiyor, izinleri değiştirmiyor, `over_capacity` bayrağını set ediyor ve yeni aktivasyonu reddediyor.
  - Bir üye ayrılınca bayrak temizleniyor.
- **Eşzamanlılık:** Kapasitede tek yer kalmışken iki kişi aynı anda kabul ediyor; yalnızca biri başarılı oluyor ve aktif üye sayısı 3'te kalıyor (gerçek iki oturumlu yarış testi).
- **Aile üyesine ayrı abonelik yok:** Checkout'u yalnızca ebeveyn açabiliyor. Aile üyesi abonelik oluşturamıyor ve istemci `subscriptions` / `billing_events` tablolarına yazamıyor.
- **Katalog:**
  - Fiyatlar ve kapasiteler doğru.
  - Yıllık = aylık × 12 × 0,90.
  - Hatalı yıllık fiyat ve katalog satırı güncellemesi reddediliyor.
- **Ödeme olayları:**
  - Aynı olay tekrar gönderilince (replay) ikinci abonelik oluşmuyor.
  - Başka ailenin intent'i veya hesap kimliğiyle gelen olay reddediliyor; abonelik ailesinde kalıyor.
  - Olaylar append-only.
- **Lifecycle:** İptal dahil hiçbir abonelik değişikliği lifecycle durumunu veya kapanış tarihini değiştirmiyor.
- **Eski veri aktarımı:**
  - Kesin eşleşmeler tek hesapta toplanıyor; tek ebeveynli hane de eşleniyor.
  - Belirsiz ve ebeveynsiz bebekler raporlanıyor.
  - Tekrar çalıştırılabiliyor; hiçbir üyelik silinmiyor; manuel çözüm raporu kapatıyor.
- **Flutter** (7 yeni test): katalog tasarrufu, kapasitenin yalnızca canlı pakette hesaplanması, ebeveyn ve aile üyesi görünümleri, yıllık tasarruf, düşürme uyarısı, eşlenmemiş bebek.

## Çalıştırılan testler ve sonuçları

- `flutter analyze --no-pub`: başarılı, sorun yok.
- `flutter test --no-pub`: başarılı, 107 test.
- `dart format --output=none --set-exit-if-changed lib test`: başarılı.
- `supabase/tests/run_db_tests.sh` (yerel PostgreSQL 16.4): başarılı. On bir migration, 455 SQL doğrulaması ve üç gerçek yarış testi (uzatma talebi, yönetici kararı, aile kapasitesi).

## Çalıştırılamayan testler / neden

- **Edge Function kontrol edilmedi:** `billing-webhook` ve `_shared/billing.ts` Deno ile tip kontrolünden geçirilmedi ve çalıştırılmadı; bu ortamda Deno kurulu değil. Veritabanı tarafı (`billing_apply_event`) tamamen test edildi.
- **Gerçek sağlayıcı yok:** App Store, Google Play veya iyzico ile uçtan uca ödeme, satın alımı geri yükleme (restore purchase) ve makbuz (receipt) doğrulaması yapılmadı; sağlayıcı seçilmedi.

## Güvenlik ve veri migration notları

- Tüm yeni tablolarda RLS açık ve istemci grant'i yok. İstemci yalnızca şu RPC'leri çağırabilir: katalog, hesap özeti, bebeğin hesap kimliği, checkout intent.
- `billing_apply_event`, `backfill_family_accounts` ve `resolve_family_account_mapping` yalnızca service role'e açık.
- Webhook, doğrulama hatasının nedenini açıklamaz.
- Migration uygulanınca mevcut hanelerin eşlemesi hemen çalışır. Belirsiz kayıtlar `family_account_migration_report` tablosunda operasyon ekibini bekler.

## Rollback adımları

- `subscription_enforcement` bayrağı kapalı tutularak eski davet akışı korunur.
- Hesap ve abonelik tabloları ile ödeme olayları silinmez.
- Arayüzdeki "Aile paketi" girişi kaldırılsa bile bebek bazlı üyelik çalışmaya devam eder.

## Bilinen riskler

- **Ödeme sağlayıcısı seçimi:** Bu madde aşağıdaki ekle çözüldü. İlk yazıldığı haliyle seçilince yapılacaklar:
  - Adaptör yazmak
  - Ürün eşlemesini eklemek
  - `billing_active_provider()` değerini değiştirmek
  - Satın alımı geri yükleme (restore purchase) ve hesap eşleme akışını eklemek
  - Checkout'u uygulamada gerçek ödeme adımına bağlamak

  Şu an checkout yalnızca talebi kaydediyor.
- **Birden fazla aile hesabı:** Birden fazla hesapta ebeveyn olan kullanıcı için arayüzde hesap seçimi yok; bebek oluştururken hata mesajı gösteriliyor.
- **Ebeveyn koltuğu yalnızca aktivasyonda belirleniyor:** Daha sonra bebek bazında yönetici veya yakınlık değiştirilirse hesap rolü otomatik güncellenmiyor.
- **Arşiv erişimi abonelikten bağımsız:** Abonelik yokken arşive erişim kısıtlanmadı. Plan 2.5.2'deki "Family Member erişimi aktif abonelik ister" kuralı, `subscription_enforcement` açılınca yalnızca aktivasyon için uygulanıyor. Mevcut üyelerin görüntüleme erişimini abonelikle sınırlamak ayrı bir ürün kararı olarak bekliyor.

## Ürün kararları sonrası ek (2026-09-29)

> **Not (2026-10-02):** Bu raporun üst bölümleri ilk halidir ve tarihsel kayıt olarak değiştirilmedi. Şu ifadeler geçersizdir:
> - "Gerçek sağlayıcı yok / sağlayıcı seçilmedi": bu ekle App Store / Google Play seçildi.
> - "Arşiv erişimi abonelikten bağımsız": bu ekle ödeme sayfasına yönlendirme getirildi, ardından 2026-10-02 karar P-2 ile **salt okunur arşiv** oldu (`20261002000400_subscription_read_only.sql`).
> - Aşağıdaki 2. madde ("uygulamayı kullanamaz ve ödeme sayfasına yönlendirilir") de P-2 ile geçersizdir.

Kullanıcı iki karar verdi:

1. Ödeme sağlayıcısı: App Store / Google Play uygulama içi abonelik.
2. Abonelik bitince mevcut üyeler uygulamayı kullanamaz ve ödeme sayfasına yönlendirilir.

### Sunucu (`20260929000400_store_billing_access_gate.sql`)

- **Mağaza ürün eşlemeleri:**
  - App Store: `bebegimin.<plan>.<dönem>`
  - Google Play: `<plan>:<base plan>`
  - `subscription_store_products` RPC'si mağaza ürün kimliklerini döndürür.
- **Checkout:** `request_subscription_checkout` fonksiyonuna `p_provider` parametresi eklendi.
- **`billing_apply_event` genişletildi:**
  - Satın almayı mağazanın bağladığı intent kimliğiyle (`bound_intent_id`) aileye bağlar; intent uyuşmazlığı reddedilir.
  - Google'ın plan değişikliğinde verdiği yeni token (`linkedPurchaseToken`) aynı abonelik satırını günceller.
  - Sıra dışı gelen eski olay yeni durumu ezmez (`event_time` / `last_event_at`).
- **`billing_apply_verified_purchase`:** Satın almayı veya geri yüklemeyi yalnızca ilgili ailenin ebeveyni bağlayabilir; başka birinin denemesi reddedilir (`purchase_not_yours`).
- **Erişim kapısı:**
  - Erişim veren durumlar: `trialing`, `active` (dönem sonu +1 gün) ve `grace`.
  - `has_baby_permission` içerik izinleri için abonelik ister.
  - Yazma koruyucusu, sahibinin kendi içeriğini düzenlediği yazmaları da reddeder (`subscription_inactive`).
  - Yükleyicinin kendi medya satırları ve Storage (okuma, yazma, silme) kapıdan geçer.
  - Bebek adı ve profil fotoğrafı, aile listesi, üye yönetimi ve hesap işlemleri açık kalır.
  - Kural `subscription_enforcement` bayrağıyla açılır.
- **`baby_access_state` RPC'si** uygulamaya şunları söyler: izin var mı, neden (`ok`, `enforcement_off`, `no_subscription`, `subscription_ended`, `payment_issue`, `account_unmapped`) ve kullanıcı ebeveyn mi.

### Edge Function'lar

- **`_shared/store_status.ts`:** Apple ve Google durumlarını saf fonksiyonlarla eşler (7 birim testi; Node ve Deno'da geçti):
  - Apple: aktif, deneme, ek süre, ödeme yeniden deneme, süresi dolmuş, iade.
  - Google: aktif, ek süre, askıda (on hold), iptal edilmiş ama dönem sonuna kadar aktif, süresi dolmuş, beklemede.
- **`_shared/app_store.ts`:** Apple JWS doğrulaması (`@apple/app-store-server-library` 3.1.0) ve App Store Server API ile durum okuma.
- **`_shared/google_play.ts`:** Servis hesabıyla OAuth ve `subscriptionsv2` durum okuma.
- **`billing-webhook`:** App Store Server Notifications V2 ve Google RTDN (Pub/Sub push, gizli token) adaptörleri.
- **`billing-verify-purchase` (JWT zorunlu):** Uygulamadan gelen satın alma ve geri yükleme makbuzunu mağazayla doğrular.
- Tüm fonksiyonlar `deno check` ile tip kontrolünden geçti (Deno 2.9.6).

### Flutter

- **Satın alma:** `in_app_purchase` paketi; StoreKit 2 bu sürümde varsayılan. `StoreBilling` servisi:
  - Satın alma sırasında intent kimliği Apple'da `appAccountToken`, Google'da `obfuscatedAccountId` olarak mağazaya iletilir.
  - Android'de plan değişikliği `ChangeSubscriptionParam` ile yapılır.
  - Satın alma dinleyicisi uygulama açılışında başlar; yarım kalan satın almalar sonradan tamamlanır.
  - Satın alma sunucu doğrulaması bitmeden "tamamlandı" sayılmaz; geçici hatada mağaza aynı satın almayı yeniden iletir.
  - Başka bir aileye ait satın alma kapatılır ve uygulanmaz.
  - "Satın alımları geri yükle" akışı var.
- **Aile paketi ekranı:** "Seç / Yükselt" gerçek mağaza satın almasını başlatır. Mağazanın yerelleştirilmiş fiyatı katalog fiyatının yanında gösterilir.
- **Ödeme sayfası (`/paywall`):** Router, aktif bebeğin ailesinin paketi yoksa kullanıcıyı buraya yönlendirir.
  - Açık kalan rotalar: ödeme sayfası, aile paketi, ayarlar (hesap silme ve çıkış dahil), davetle katılma, yeni bebek.
  - Ebeveyn paket seçer veya satın alımlarını geri yükler; aile üyesine "Anne veya Baba yenilemeli" bilgisi gösterilir.
  - Diğer çocuğa geçiş, "tekrar kontrol et" ve ayarlar düğmeleri var.
  - Paket etkinleşince kullanıcı otomatik olarak ana sayfaya döner.

### Kanıtlar

- **SQL:** `95_store_billing_access_gate_test.sql` (50 doğrulama):
  - Mağazaya göre checkout ve ürün kimlikleri
  - Yalnızca ebeveynin doğrulanmış satın alması; aile üyesi ve yabancı reddediliyor
  - Ebeveynin geri yüklemesi; yabancının geri yüklemesi reddediliyor
  - Mağazanın bağladığı intent uyuşmazlığı reddediliyor
  - Sıra dışı gelen eski olay yok sayılıyor
  - Aktif / ek süre / ödeme yeniden deneme / süresi dolmuş / dönem sonu geçmiş abonelik ayrı ayrı
  - Aile üyesi ve ebeveyn için: anılar, zaman tüneli, albüm, imzalı URL ve yazmalar kapalı; sahibinin kendi içeriğini düzenlemesi de kapalı
  - Bebek adı, aile listesi ve üye yönetimi açık
  - Ödeme sayfasından yeni satın alma başlatılabiliyor
  - Yenileme sonrası veriler geri geliyor
  - Eşlenmemiş bebek kapalı
  - Google plan değişikliği tek abonelik satırında kalıyor
  - Bayrak kapalıyken eski davranış sürüyor
  - Lifecycle etkilenmiyor
- **Flutter:** 114 test. `store_paywall_test.dart` (7 test):
  - Google ürün kimliğini ayrıştırma
  - Abonelik yokken açık kalan rotalar
  - Erişim kapısı mesajları
  - Ödeme sayfasında ebeveyn ve aile üyesi görünümleri; geri yükleme
  - Plan seçiminin intent'e bağlı mağaza satın almasını başlatması
  - Mağazası olmayan platformda satın alma başlamaması
- **Toplam:** 505 SQL doğrulaması ve üç gerçek yarış testi geçti.

### Çalıştırılamayan testler

- Gerçek App Store Sandbox ve Google Play test satın alması yapılamadı; mağaza konsollarında ürünler henüz tanımlı değil ve cihaz yok.
- Apple JWS doğrulaması ve Google API çağrıları yalnızca tip kontrolünden geçti. Durum eşleme mantığı birim testli.

### Açık işler

- Mağaza konsollarında ürünlerin oluşturulması, secret'ların girilmesi ve bildirim URL'lerinin tanımlanması (`docs/operations/store-billing-setup.md`).
- Bayrak açılmadan önce eşleme raporunun boşaltılması; açılınca aktif paketi olmayan aileler ödeme sayfasına düşer.
- Kaçan mağaza bildirimlerine karşı dönem sonu toleransı (+1 gün) var. Bunun yanında periyodik bir "mağazayla uzlaştırma" işi eklenebilir.

## Faz 7'nin giriş koşulları

- Aile hesabı, abonelik projeksiyonu ve ödeme olayı altyapısı hazır.
- Faz 7 (premium ürün kataloğu, sipariş, entitlement) aynı `billing_events` ve adaptör yaklaşımını kullanabilir.
- Entitlement'lar `familyAccountId + babyId + productCode` üçlüsüne bağlanacak.
