# ADR 0002 — Aile hesabı, aile paketi aboneliği ve kapasite politikaları

- Durum: Kabul edildi (Faz 6; 2026-09-29 ürün kararlarıyla güncellendi)
- Tarih: 2026-09-29

## Bağlam

Master plan §2.5 abonelik kurallarını tanımlar:

- Abonelik kişiye değil `family_account`'a aittir.
- İki ebeveyn koltuğu vardır.
- Plan kapasiteleri Small 3, Normal 6, Large 12 Family Member'dır; ebeveynler bu sayıya dahil değildir.
- Fiyatlar kataloğa göre aylık/yıllık belirlenir.

Mevcut sistemde üyelik bebek bazlıdır (`family_members`) ve ödeme sağlayıcısı henüz seçilmemiştir.

## Kararlar

### 1. Uyumluluk katmanı

- Bebek bazlı `family_members` (yakınlık + izinler) aynen korunur.
- `family_account_members` bu kayıtlardan türetilir: bir kişi hesabın ilk bebeğine katıldığında hesapta etkinleşir, son bebeğinden ayrıldığında `removed` olur.
- Ebeveyn = ilgili bebekte `relation ∈ {anne, baba}` ve `is_admin`.

### 2. Aktivasyon noktası ve bekleyen davetler

- Bekleyen davetler kapasiteden yer ayırmaz; davet oluşturmak her zaman mümkündür.
- Kapasitenin resmî kontrolü aktivasyon anında yapılır: `family_members` insert olduğunda.
- Aynı hesaptaki aktivasyonlar `family_accounts` satırındaki kilitle sıraya girer; eşzamanlı iki kabul kapasiteyi aşamaz.
- Arayüz kapasiteyi gösterir ve dolduğunda plan yükseltme yolunu sunar.

### 3. Kapasiteyi aşan plan düşürme

- Sağlayıcının bildirdiği plan uygulanır (müşteri o plana geçmiştir).
- Abonelik `over_capacity = true` olarak işaretlenir.
- Hiçbir üye, veri veya izin silinmez ya da değiştirilmez.
- Aktif üye sayısı kapasiteye inene kadar yeni Family Member etkinleştirilemez.
- Ebeveynler, kimin çıkacağına kendileri karar verir; çıkış olunca bayrak kendiliğinden temizlenir.
- Neden: Sağlayıcı tarafında düşürmeyi bekletmek her sağlayıcıda mümkün değildir. Bu yaklaşım kimseyi habersiz silmez.

### 4. Abonelik bitince erişim (ürün kararı, 2026-09-29)

- Aile paketi aktif değilse, o ailedeki **herkes** (Anne, Baba ve aile üyeleri) arşivi kullanamaz ve ödeme sayfasına yönlendirilir.
- **Erişim veren durumlar:** `trialing`, `active` (dönem sonu 1 gün toleransla geçmemiş) ve `grace`.
- **Erişim vermeyen durumlar:** `past_due` (ek sürenin bitmesinden sonra ödeme yeniden deneniyor), `canceled`, `expired` ve hiç aboneliği olmamak.
- Kural sunucuda uygulanır:
  - `has_baby_permission` içerik izinleri için abonelik ister.
  - Ortak yazma koruyucusu (`lifecycle_source_guard`) yazmaları reddeder.
  - Storage imzalı URL'leri ve yüklemeler reddedilir.
  - Yükleyicinin kendi medya satırlarını görmesi de aboneliğe bağlanır.
- Açık kalanlar:
  - Bebek adı ve profil fotoğrafı (ödeme sayfası için)
  - Aile listesi ve üye yönetimi (`manage_members`, `invite_members`)
  - Hesap ayarları, çıkış yapma, hesap/veri silme
  - Başka bir aileye katılma
- Hiçbir veri silinmez. Paket yenilenince her şey kaldığı yerden açılır.
- Ebeveyn ödeme sayfasında paket seçer veya satın alımlarını geri yükler. Aile üyesine "Anne veya Baba paketi yenilemeli" bilgisi gösterilir.
- Kural `platform_flags.subscription_enforcement` bayrağı açıldığında devreye girer (varsayılan kapalı). Mağaza ürünleri canlıya alınıp mevcut aileler paket seçebilir hale gelince açılmalıdır; önce açılırsa bugünkü tüm kullanıcılar ödeme sayfasına düşer.
- Henüz bir aile hesabına eşlenmemiş bebekler, bayrak açıkken "eşleştiriliyor" durumunda kapalı kalır. Bayrak açılmadan önce eşleme raporu (`family_account_migration_report`) boşaltılmalıdır.
- Lifecycle ve premium haklar bu kuraldan etkilenmez.

### 5. Ödeme sağlayıcısı: App Store ve Google Play uygulama içi abonelik (ürün kararı, 2026-09-29)

- **Satın alma akışı:**
  1. Ebeveyn `request_subscription_checkout(..., p_provider)` ile bir intent (UUID) açar.
  2. Uygulama bu UUID'yi mağazaya iletir: Apple'da StoreKit 2 `appAccountToken`, Google'da `obfuscatedAccountId`.
  3. Sunucu bu değeri **mağazadan geri okuyarak** (`bound_intent_id`) satın almayı aile hesabına bağlar. İstemcinin bildirdiği değere güvenilmez.
- **Uygulamadan doğrulama:** Uygulama satın alma veya geri yükleme sonrasında makbuzu `billing-verify-purchase` fonksiyonuna gönderir.
  - Apple: JWS, Apple kök sertifikalarıyla doğrulanır; mümkünse durum App Store Server API'den alınır.
  - Google: purchase token ile durum Play Developer API'den (`subscriptionsv2`) okunur.
  - Satın almayı yalnızca ilgili ailenin ebeveyni bağlayabilir. Başka bir ailenin aboneliğini geri yüklemek reddedilir (`purchase_not_yours`).
- **Mağaza bildirimleri:** `billing-webhook`
  - Apple: App Store Server Notifications V2; JWS doğrulanır.
  - Google: RTDN (Pub/Sub push, URL'de gizli token); durum her seferinde Play API'den yeniden okunur.
- **Güvenilir işleme:**
  - Olaylar olay kimliğine göre idempotenttir; sıra dışı gelen eski olay yeni durumu ezmez (`event_time`).
  - Google'ın plan değişikliğinde verdiği yeni token (`linkedPurchaseToken`) aynı abonelik satırını günceller.
- **Ürün kimlikleri** `subscription_plan_provider_products` tablosunda tutulur ve mağazada oluşturulan kimliklerle birebir aynı olmalıdır:
  - App Store: `bebegimin.<plan>.<dönem>`
  - Google Play: `<plan>:<base plan>`
- **Mock sağlayıcı** geliştirme ve test için korunur.

### 6. Katalog

- Fiyatlar ve kapasiteler `subscription_plans` tablosunda sürümlü tutulur.
- Satırlar değiştirilemez; fiyat değişikliği yeni bir sürümdür.
- Yıllık fiyat = aylık × 12 × 0,90 kuralı ve aylık/yıllık kapasite eşitliği trigger ile zorunlu tutulur.
- Flutter fiyatı ve kapasiteyi yalnızca katalogdan okur.

### 7. Eski verinin aktarımı

- Yalnızca kesin eşleşmeler otomatik eşlenir: aynı 1–2 ebeveyn kümesine sahip bebekler tek hesapta toplanır.
- İki farklı ebeveyn kümesinde görünen kullanıcıların bebekleri birleştirilmez; `family_account_migration_report` tablosuna `ambiguous_parent_sets` olarak yazılır. Bağlı bileşen (graph) ile hane birleştirme yapılmaz.
- Ebeveyni olmayan bebekler raporda `no_parent` olarak yer alır.
- Raporlanan bebekler `resolve_family_account_mapping` ile manuel olarak eşlenir.
- Eşleme hiçbir üyeliği silmez.

### 8. Bebek oluşturma

`create_baby`, bebeği oluşturanın hesabına atomik olarak bağlar:

- Kullanıcı tek bir hesapta ebeveynse bebek o hesaba eklenir.
- Hiçbir hesapta değilse yeni hesap oluşturulur.
- Birden fazla hesapta ebeveynse `p_family_account_id` parametresi gerekir (`family_account_ambiguous`).

İkinci ebeveynin davet kabulü, ebeveyn koltuğu kontrolüyle aynı transaction içinde yapılır.

## Sonuçlar

- Kişi bazlı veya Family Member aboneliği yoktur.
- İkinci ve sonraki bebekler fiyatı artırmaz.
- Aile hesabının ekranda seçilmesi (birden fazla hesap durumu) sonraki işlerdendir.
