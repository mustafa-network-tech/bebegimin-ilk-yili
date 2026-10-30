# Faz 07 Sonuç Raporu

- **Durum:** COMPLETE. Dosya üretimi Faz 8–11'de gelecek; o zamana kadar satın alınan ürün "Hazırlanıyor" gösterilir, plandaki "hazırlanıyor/altyapı bekliyor" koşuluna uygun.
- **Başlangıç commit'i:** `cb5f678` (Faz 6 ile aynı checkpoint)
- **Bitiş commit'i:** Faz 6 ile ortak commit (kullanıcı talebi; hash için `git log`)
- **Eklenen migration:** `supabase/migrations/20260929000500_premium_entitlements.sql`
- **ADR:** `docs/implementation/ADR/0003-premium-products-and-entitlements.md`

## Değişen dosyalar

- **Veritabanı:** yeni migration; `supabase/tests/97_premium_entitlements_test.sql` (yeni)
- **Edge Function'lar:**
  - `_shared/store_status.ts`: tek seferlik ürün eşlemeleri
  - `_shared/app_store.ts`: consumable işlemler, bildirimleri ürün türüne göre yönlendirme
  - `_shared/google_play.ts`: `purchases.products`
  - `_shared/billing.ts`: tek seferlik ürün ve iptal bildirimleri (RTDN one-time / voided)
  - `billing-webhook`, `billing-verify-purchase`: ürün türüne göre yönlendirme
  - `tests/store_status.test.ts`: 2 yeni test
- **Flutter:**
  - Yeni `lib/features/premium/` modülü: models, repository, providers, `premium_store_screen.dart`
  - `store_billing.dart`: `buyPremium`, sunucu onayından sonra tüketme
  - `subscription_repository.dart`: doğrulama isteğine ürün ve sipariş kimliği
  - Ana sayfa girişi, `/babies/:babyId/premium` rotası, hata mesajları
  - `lifecycle_widgets.dart`: yer tutucu kart kaldırıldı
- **Testler:** `test/premium/premium_store_test.dart`, `test/subscription/store_paywall_test.dart` (sahte mağaza güncellendi)
- **Doküman:** `docs/operations/store-billing-setup.md` (premium ürünler bölümü)

## Uygulananlar

- **Tablolar:**
  - Katalog: `premium_products` (sürümlü, satırları değiştirilemez) ve `premium_product_provider_products` (mock, App Store, Google Play eşlemeleri)
  - Sipariş: `premium_orders` (fiyat ve para birimi sabitlenir) ve `premium_order_events` (append-only, olay kimliğine göre idempotent)
  - Hak: `product_entitlements` (aile + bebek + ürün başına tek aktif hak; silinmez, yalnızca iadeyle iptal edilir)
  - Tamamı yalnızca sunucu tarafından yazılır; RLS açık, istemci grant'i yok.
- **Fiyatlar:**
  - `first_year_book 34900`, `first_year_html 44900`, `first_year_film 54900` TRY; teslim biçimi PDF / HTML-ZIP / MP4.
  - Fiziksel baskı katalogda yok.
  - Fiyatlar yalnızca katalogdan gelir. Flutter fiyatları katalogdan gösterir, mağazanın yerelleştirilmiş fiyatını yanına ekler.
- **Satın alma koşulları** (`premium_purchase_block`, `request_premium_purchase`), hepsi sağlanmalı:
  - Bebek LOCKED (`premium_requires_locked`).
  - Kullanıcı aile hesabının aktif ebeveyni (`not_parent`).
  - Aile aboneliği erişim veriyor (`subscription_required`).
  - `premium_storefront` bayrağı açık (`storefront_closed`; varsayılan kapalı).
  - Ürün henüz satın alınmamış (`already_owned`).
- **Mağaza vitrini:**
  - `premium_storefront`: yalnızca LOCKED bebeğin ebeveynine ürünleri, fiyatları, sahiplik durumunu ve satın alma engelini gösterir.
  - `baby_entitlements`: sahip olunan ürünleri tüm aile üyelerine gösterir (Anne'nin aldığı ürün Baba'da da görünür).
- **Ödeme projeksiyonu** (`premium_apply_event`), yalnızca mağazada doğrulanmış olaylarla:
  - Ödemeyi mağazanın bağladığı sipariş kimliğiyle siparişe bağlar; istemcinin iddiası mağazayla çelişirse reddeder.
  - Ürün, fiyat ve para birimi siparişle eşleşmezse reddeder.
  - `paid` hak verir. Aynı ürün için ikinci ödeme `duplicate_payment` olarak işaretlenir, ikinci hak oluşmaz.
  - `refunded` / `revoked` hakkı iptal eder; iade edilmiş sipariş tekrar ödenemez.
  - Ürün kimliği olmayan ödeme hiçbir zaman hak vermez. Google iptal bildirimlerinde ürün kimliği yoktur; iade için kabul edilir.
- **Doğrulanmış satın alma:** `premium_apply_verified_purchase` satın almayı yalnızca ilgili ailenin ebeveynine bağlar (`purchase_not_yours`).
- **Mağaza entegrasyonu:**
  - Apple: consumable işlem JWS'si doğrulanır; fiyat milli birimden kuruşa çevrilir. REFUND ve REVOKE bildirimleri hakkı iptal eder.
  - Google: `purchases.products` ile durum okunur; tek seferlik ürün ve iptal (voided) bildirimleri RTDN ile işlenir.
  - `store_product_kind` makbuzları ve bildirimleri abonelik veya premium hattına yönlendirir.
- **Flutter:**
  - LOCKED ana sayfada "İlk Yıl hatıraları" kartı mağaza vitrinine götürür.
  - AKTİF profilde vitrin tamamen kapalıdır; kapanış tarihi gösterilir.
  - Ebeveyn üç ayrı ürünü ayrı fiyatlarla görür. Kitap kartı "PDF · Fiziksel / basılı kitap bu ürüne dahil değildir" der.
  - Sahip olunan ürün "Satın al" yerine "Satın alındı · Hazırlanıyor" durumunu gösterir.
  - Abonelik yoksa "Aile paketine git" yönlendirmesi, bayrak kapalıysa "Yakında satışta" görünür.
  - Aile üyesi fiyat ve satın alma görmez, yalnızca sahip olunan ürünleri görür.
  - Satın alma sırasında sipariş kimliği mağazaya iletilir; ürün consumable olarak alınır. Android'de sunucu hakkı verdikten sonra tüketilir.

## Kabul kriterleri ve kanıtlar

`97_premium_entitlements_test.sql` 61 doğrulama içeriyor:

- **Katalog:** Yalnızca 34900 / 44900 / 54900 TRY var; emekliye ayrılmış veya taslak fiyat yok. Kitap PDF olarak tanımlı. Katalog satırı değiştirilemiyor. Mağaza ürün kimlikleri doğru.
- **Satın alma koşulları:**
  - AKTİF bebek satın alamıyor, vitrini de göremiyor.
  - Abonelik yoksa ve bayrak kapalıysa satın alma reddediliyor.
  - Aile üyesi vitrini ve satın almayı kullanamıyor; yabancı bebeği hiç göremiyor.
  - LOCKED + ebeveyn + abonelik + bayrak açık olduğunda satın alma açılıyor.
- **Doğrulama olmadan hak yok:** Yanlış fiyat, yanlış para birimi, başka ürün, siparişsiz ödeme, mağazayla çelişen sipariş, ürün kimliği olmayan ödeme reddediliyor. Yabancı ve aile üyesi satın almayı bağlayamıyor.
- **Tekrarlar tek hak üretiyor:** Makbuzun tekrar gönderilmesi `duplicate`; aynı satın alma için gelen mağaza bildirimi yeni hak üretmiyor.
- **Paylaşım ve bağımsızlık:**
  - Hak aile hesabına ait. Anne'nin satın aldığını Baba görüyor ve tekrar satın alamıyor (`already_owned`); aile üyeleri sahip olunan ürünü görüyor.
  - Kitap, filmi ya da HTML'i açmıyor.
  - Bir bebeğin kitabı kardeşini açmıyor.
- **Çift ödeme:** İki açık sipariş için iki ödeme gelirse tek hak oluşuyor; ikinci ödeme `duplicate_payment` olarak işaretleniyor.
- **İade:** Hak `revoked` oluyor, sipariş `refunded`. İade edilmiş sipariş tekrar ödenemiyor. Hak silinemiyor ve iptalden sonra yeniden aktif edilemiyor. Olaylar append-only. İadeden sonra yeni satın alma tek aktif hakla sonuçlanıyor.
- **Bağımsızlık:** Abonelik bitince haklar korunuyor, yeni satın alma ise abonelik istiyor. Lifecycle durumu ve kapanış tarihi değişmiyor.
- **Mağaza durum eşleme** (Node ve Deno'da 9 birim testi):
  - Apple: tek seferlik ödeme, kuruş çevirisi, iade.
  - Google: satın alındı, iptal, beklemede, voided.
- **Flutter** (`premium_store_test.dart`, 7 test):
  - Ürün tanımları ve engel ipuçları
  - AKTİF profilde vitrin yok
  - LOCKED'da üç ayrı ürün, katalog fiyatları ve "fiziksel baskı dahil değil" metni
  - Sahip olunan ürün "Hazırlanıyor"
  - Satın alma siparişi açıp mağaza satın almasını başlatıyor
  - Abonelik yoksa aile paketine yönlendirme; bayrak kapalıysa "Yakında"
  - Aile üyesi görünümü

## Çalıştırılan testler ve sonuçları

- `flutter analyze --no-pub`: başarılı, sorun yok.
- `flutter test --no-pub`: başarılı, 121 test.
- `dart format --output=none --set-exit-if-changed lib test`: başarılı.
- `supabase/tests/run_db_tests.sh` (PostgreSQL 16.4): başarılı. On iki migration, 566 SQL doğrulaması ve üç gerçek yarış testi.
- `deno check billing-webhook billing-verify-purchase`: başarılı.
- `deno test` / `node --test` (store_status): başarılı, 9 test.

## Çalıştırılamayan testler / neden

- Gerçek App Store ve Google Play test satın alması yapılamadı; mağaza ürünleri henüz tanımlı değil ve cihaz yok.
- Aynı ürün için eşzamanlı iki ödeme ayrı bir yarış testiyle denenmedi. Kısmi unique index ile sıralı senaryo test edildi ve aynı index eşzamanlı ödemelerde de ikinci hakkı engeller.

## Güvenlik notları

- Tüm yeni SECURITY DEFINER fonksiyonlarda `search_path` sabit.
- Hak verme yalnızca service role'e açık `premium_apply_event` / `premium_apply_verified_purchase` üzerinden yapılır.
- İstemci yalnızca sipariş açabilir. Tabloları doğrudan okuyamaz ve yazamaz.

## Rollback adımları

- `update public.platform_flags set enabled = false where key = 'premium_storefront';` ile satış kapanır.
- Doğrulanmış siparişler ve haklar korunur.

## Bilinen riskler

- **Consumable seçimi:** Apple "Satın alımları geri yükle" consumable ürünleri kapsamaz. Kalıcılık sunucudaki haktan gelir (ADR 0003); App Store incelemesinde bu açıklanmalıdır.
- **Google'da fiyat doğrulaması yok:** Satın alma API'si fiyat döndürmediği için fiyat Play Console yapılandırmasına dayanır.
- **Çift ödeme iadesi:** `duplicate_payment` olarak işaretlenen ödemelerin iadesi operasyon sürecidir; otomatik iade yok.
- **Dosya üretimi yok:** Artifact yok; Faz 8–11'de bağlanacak. `artifact_download_permissions` Faz 12 kapsamında.
- **Kitap sunucuda hâlâ açık:** Kitap tabloları ve `books` bucket'ı AKTİF profilde açık; Faz 9'da kapanacak.

## Faz 8'in giriş koşulları

- Bebek bazlı haklar ve sipariş olayları hazır.
- Faz 8 (değiştirilemez arşiv anlık görüntüsü, iş ve artifact altyapısı) `product_entitlements` üzerinden çalışacak.
