# ADR 0003 — Premium ürünler, siparişler ve bebek bazlı haklar

- Durum: Kabul edildi (Faz 7)
- Tarih: 2026-09-29

## Bağlam

Master plan §2.6 ve §3.1.1'de premium ürün kuralları şöyle tanımlanır:

- Dijital Kitap (PDF), Offline HTML ve İlk Yıl Filmi birbirinden bağımsız, tek seferlik dijital ürünlerdir.
- Satın alma hakkı (entitlement) bebeğe ve aile hesabına bağlıdır: `familyAccountId + babyId + productCode`.
- Satın alma yalnızca LOCKED profilde, aktif ebeveyn ve aktif aile aboneliğiyle mümkündür.

Faz 6'da ödeme sağlayıcısı App Store / Google Play uygulama içi satın alma olarak seçildi.

## Kararlar

### 1. Mağazada "consumable" ürün, kalıcı hak sunucuda

**Sorun:** Aynı aile her bebek için aynı ürünü ayrı ayrı satın alabilmelidir (Defne'nin kitabı, Ece'nin kitabı). Mağazalarda "tüketilmeyen" (non-consumable) ürün, aynı Apple / Google hesabı tarafından yalnızca bir kez alınabilir.

**Karar:**
- Üç ürün mağazada **consumable** tanımlanır.
- Kalıcı kayıt sunucudaki `product_entitlements` tablosudur: bebek bazlı, silinmez, yalnızca doğrulanmış iadeyle iptal edilir.
- Mağazadaki "geri yükle" bu ürünler için kullanılmaz. Sahip olunan ürünler her cihazda sunucudan okunur ve yeniden indirme Faz 12'de sunucu üzerinden yapılır.
- Android'de satın alma, sunucu hakkı verdikten **sonra** tüketilir (`autoConsume: false`). Doğrulama başarısız olursa satın alma tüketilmez ve mağaza onu yeniden iletir.

### 2. Sipariş bağlama

- Ebeveyn `request_premium_purchase` ile sipariş açar. Sipariş kataloğun o anki fiyatını ve para birimini sabitler.
- Sipariş kimliği mağazaya Apple `appAccountToken` / Google `obfuscatedAccountId` olarak iletilir. Sunucu bu değeri **mağazanın doğrulanmış makbuzundan geri okuyarak** ödemeyi siparişe bağlar.
- İstemcinin bildirdiği sipariş kimliği mağazanın değeriyle çelişirse ödeme reddedilir.
- Satın almayı yalnızca siparişin ailesindeki bir ebeveyn bağlayabilir (`purchase_not_yours`).

### 3. Fiyat ve para birimi doğrulaması

- Apple makbuzundaki fiyat (milli birim) ve para birimi, siparişin sabitlenmiş fiyatıyla karşılaştırılır; uyuşmazsa reddedilir.
- Google'ın satın alma API'si fiyat döndürmez. Burada ürün eşlemesi ve Play Console'daki fiyat esas alınır.
- Ürün uyuşmazlığı (başka bir ürünle ödeme) her iki mağazada da reddedilir.

### 4. Tekillik, çift ödeme ve iade

- Aynı aile + bebek + ürün için aynı anda yalnızca bir aktif hak olabilir (kısmi unique index).
- Aynı ürün için ikinci bir ödeme gelirse ikinci hak oluşmaz. Olay `duplicate_payment` olarak işaretlenir ve operasyon tarafından iade edilir.
- Ödeme ve iade olayları `premium_order_events` tablosunda append-only tutulur.
- Apple REFUND / REVOKE bildirimleri ve Google iptal (voided purchase) bildirimleri hakkı `revoked` yapar. Hak kaydı silinmez; iadeden sonra yeniden satın alınabilir.

### 5. Kapsam ve bağımsızlık

- Katalog `34900 / 44900 / 54900` TRY'dir, sürümlüdür ve satırları değiştirilemez. Fiziksel baskı katalogda yoktur.
- Abonelik bitince hak silinmez; yalnızca yeni satın alma için aktif abonelik gerekir.
- Lifecycle hiçbir koşulda değişmez.
- `platform_flags.premium_storefront` bayrağı varsayılan olarak kapalıdır. Mağaza ürünleri canlıya alınınca açılır.
- Artifact altyapısı (Faz 8–11) gelene kadar sahip olunan ürün "Hazırlanıyor" olarak görünür. Sahte dosya verilmez.

## Sonuçlar

- Ebeveynler aynı ürünü farklı bebekler için ayrı ayrı satın alabilir.
- Anne'nin satın aldığı ürün Baba'da görünür; ikinci ücret oluşmaz.
- Mağaza konsollarında üç ürün her platformda consumable olarak tanımlanmalıdır (`docs/operations/store-billing-setup.md`).
