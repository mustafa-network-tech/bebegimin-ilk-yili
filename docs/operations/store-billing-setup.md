# Mağaza aboneliği kurulumu (App Store / Google Play)

Kod tarafı hazırdır. Canlıya almadan önce aşağıdaki adımlar mağaza konsollarında ve Supabase'de yapılmalıdır. Uygulama kimlikleri:

- iOS bundle ID: `app.bebegimin.bebegiminIlkYili`
- Android paket adı: `com.mkdigitalsystems.bebegimin_ilk_yili`

## 1. Ürünler

Fiyatlar ve kapasiteler veritabanı kataloğundan gelir. Mağazadaki fiyatlar katalogla aynı tutulmalıdır.

| Plan | Dönem | Katalog | App Store ürün kimliği | Google Play ürün : base plan |
|---|---|---:|---|---|
| Small Family | Aylık | 299,00 TL | `bebegimin.small_family.monthly` | `small_family : monthly` |
| Small Family | Yıllık | 3.229,20 TL | `bebegimin.small_family.annual` | `small_family : annual` |
| Normal Family | Aylık | 369,00 TL | `bebegimin.normal_family.monthly` | `normal_family : monthly` |
| Normal Family | Yıllık | 3.985,20 TL | `bebegimin.normal_family.annual` | `normal_family : annual` |
| Large Family | Aylık | 469,00 TL | `bebegimin.large_family.monthly` | `large_family : monthly` |
| Large Family | Yıllık | 5.065,20 TL | `bebegimin.large_family.annual` | `large_family : annual` |

**App Store Connect:**

- Altı otomatik yenilenen abonelik tek bir abonelik grubunda olmalıdır. Grup içindeki sıralama yükseltme ve düşürmeyi belirler; Large en üstte olmalıdır.
- "Family Sharing" kapalı kalmalıdır. Abonelik zaten aile hesabı bazlıdır ve uygulama içinde paylaşılır.

**Google Play Console:**

- Üç abonelik ürünü (`small_family`, `normal_family`, `large_family`) oluşturulur.
- Her birinde `monthly` ve `annual` adlı iki otomatik yenilenen base plan bulunur.

Farklı kimlikler kullanılırsa `subscription_plan_provider_products` tablosu yeni bir migration ile güncellenmelidir.

### Premium tek seferlik ürünler (Faz 7)

Premium ürünler her iki mağazada da **consumable** olarak tanımlanır. Böylece aynı ürün her bebek için ayrı satın alınabilir; kalıcı hak sunucuda tutulur (ADR 0003).

| Ürün | Katalog | App Store ürün kimliği (Consumable) | Google Play tek seferlik ürün |
|---|---:|---|---|
| Dijital İlk Yıl Kitabı (PDF) | 349,00 TL | `bebegimin.first_year_book` | `first_year_book` |
| Offline HTML Hatırası | 449,00 TL | `bebegimin.first_year_html` | `first_year_html` |
| İlk Yıl Filmi (MP4) | 549,00 TL | `bebegimin.first_year_film` | `first_year_film` |

- Mağaza fiyatı katalogla aynı olmalıdır. Apple makbuzundaki fiyat siparişle karşılaştırılır; uyuşmazsa ödeme reddedilir.
- Fiziksel / basılı kitap bir mağaza ürünü değildir.
- Google RTDN ayarlarında tek seferlik ürün bildirimleri (one-time product) ve iptal edilen satın alma (voided purchases) bildirimleri de etkin olmalıdır.
- Satış, ürünler canlıya alındıktan sonra açılır:
  ```sql
  update public.platform_flags set enabled = true, note = 'Premium ürünler canlı' where key = 'premium_storefront';
  ```
  Kapatmak için aynı komut `enabled = false` ile çalıştırılır. Verilmiş haklar ve siparişler korunur.

## 2. Sunucu secret'ları

```bash
supabase secrets set \
  APPLE_BUNDLE_ID=app.bebegimin.bebegiminIlkYili \
  APPLE_APP_APPLE_ID=<App Store Connect Apple ID> \
  APPLE_ENVIRONMENT=Production \
  APPLE_ROOT_CERTS_B64=<Apple Root CA - G3 .cer, base64> \
  APPLE_ISSUER_ID=<...> APPLE_KEY_ID=<...> APPLE_PRIVATE_KEY="$(cat SubscriptionKey_XXXX.p8)" \
  GOOGLE_PLAY_PACKAGE_NAME=com.mkdigitalsystems.bebegimin_ilk_yili \
  GOOGLE_PLAY_SERVICE_ACCOUNT="$(cat play-service-account.json)" \
  GOOGLE_RTDN_TOKEN=<uzun rastgele değer>
supabase functions deploy billing-webhook --no-verify-jwt
supabase functions deploy billing-verify-purchase
```

- Apple kök sertifikası (Apple Root CA - G3): https://www.apple.com/certificateauthority/
- App Store Server API anahtarı: App Store Connect > Users and Access > Integrations > In-App Purchase.
- Google servis hesabı: Play Console > Users and permissions. "View financial data" ve "Manage orders and subscriptions" yetkileri verilmelidir.

## 3. Mağaza bildirimleri

- **App Store Server Notifications V2 URL'si** (Production ve Sandbox):
  `https://<PROJECT_REF>.supabase.co/functions/v1/billing-webhook?provider=app_store`
- **Google Play RTDN:**
  1. Bir Pub/Sub topic oluşturulur ve Play Console > Monetization setup ekranında bağlanır.
  2. Topic için bir push subscription oluşturulur. Endpoint:
     `https://<PROJECT_REF>.supabase.co/functions/v1/billing-webhook?provider=google_play&token=<GOOGLE_RTDN_TOKEN>`

## 4. Test

1. Apple Sandbox ve Google lisanslı test hesaplarıyla satın alma, yenileme, iptal, plan yükseltme/düşürme ve geri yükleme denenir. Sandbox için `APPLE_ENVIRONMENT=Sandbox` kullanılır.
2. Her işlemden sonra `billing_events` tablosunda `result = 'applied'` görülmeli, `subscriptions` tablosu doğru durumu göstermelidir.

## 5. Kuralı açma

1. Eşleme raporu kontrol edilir; açık kayıt kalmamalıdır:
   `select * from family_account_migration_report where resolved_at is null;`
2. Uygulamanın mağaza sürümü yayındadır ve mevcut aileler paket seçebilir durumdadır.
3. Kural açılır:
   ```sql
   update public.platform_flags set enabled = true, note = 'Mağaza abonelikleri canlı' where key = 'subscription_enforcement';
   ```

Bu andan itibaren aktif paketi olmayan ailelerin arşivi salt okunur olur (karar P-2, 2026-10-02): görüntüleme sürer; içerik ekleme, düzenleme ve premium işlemler kapanır. Uygulama salt okunur bandından ödeme sayfasına yönlendirir.

Geri almak için aynı komut `enabled = false` ile çalıştırılır. Hiçbir veri silinmez.
