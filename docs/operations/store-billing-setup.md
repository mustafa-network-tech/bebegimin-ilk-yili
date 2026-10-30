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
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(cat play-service-account.json)" \
  GOOGLE_RTDN_TOKEN=<uzun rastgele değer>
supabase functions deploy billing-webhook --no-verify-jwt
supabase functions deploy billing-verify-purchase
```

> RTDN kurulmadan yenileme / iptal / iade takibi için bkz.
> [billing-reconcile-setup.md](billing-reconcile-setup.md) (zamanlanmış `billing-reconcile`,
> `BILLING_RECONCILE_SECRET`; varsayılan olarak kapalıdır).

- Apple kök sertifikası (Apple Root CA - G3): https://www.apple.com/certificateauthority/
- App Store Server API anahtarı: App Store Connect > Users and Access > Integrations > In-App Purchase.
- Google servis hesabı: Play Console > Users and permissions. "View financial data" ve "Manage orders and subscriptions" yetkileri verilmelidir.

Admin Paneli'ndeki salt-okunur katalog kontrolü için Vercel projesine de
`GOOGLE_PLAY_PACKAGE_NAME` ve `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` değişkenleri
server-only olarak eklenir. Bu değişkenlerde `NEXT_PUBLIC_` öneki kullanılmaz.
Admin Paneli Google Play ürünlerini veya fiyatlarını değiştirmez; yalnız gerçek
katalog durumunu okuyup denetimli bir kontrol sonucu kaydeder.

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

## 6. Satın alma doğrulama hataları ve yapılandırma kontrol listesi

`billing-verify-purchase` hata durumunda yalnızca güvenli bir kod döndürür ve loglar (token, anahtar veya makbuz asla yazılmaz). Uygulama her kod için "Aboneliğiniz etkinleştirilmedi" diyen Türkçe bir mesaj gösterir. Başarı yalnızca yanıtta `granted: true` varsa kabul edilir; Google satın alması ancak o zaman onaylanır (acknowledge). Onaylanmayan satın almalar Google tarafından 3 gün içinde otomatik iade edilir.

| Kod | Anlamı | Bakılacak yer |
|---|---|---|
| `not_configured` | Supabase secret'ı eksik veya bozuk | Supabase > Edge Functions > Secrets: `GOOGLE_PLAY_PACKAGE_NAME`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (tam JSON), `GOOGLE_RTDN_TOKEN` |
| `google_401` | Hizmet hesabı anahtarı reddedildi | Anahtar iptal/yenilenmiş olabilir; yeni JSON ile secret'ı güncelleyin |
| `google_403` | Hizmet hesabının Play Console yetkisi yok | Play Console > Users and permissions; Cloud'da Android Publisher API etkin mi |
| `google_404` | Satın alma jetonu Google'da yok | Test hesabı/uygulama paketi/ürün eşleşmesi |
| `product_not_found` | Ürün kimliği veritabanı eşlemesinde yok | `subscription_plan_provider_products` |
| `base_plan_unavailable` | Base plan eşlemesi/etkinliği yok | Play Console'da base plan Etkin mi; `small_family:monthly` / `:annual` |
| `verification_failed` | Beklenmeyen doğrulama hatası | Edge Function logları (`code` alanı) |
| `purchase_rejected` | Google doğruladı ama aile hesabına uygulanamadı | `select error from billing_events where result = 'rejected' order by id desc limit 10;` |
| `temporary_error` | Google/ağ geçici hata | Uygulama sonraki açılışta yeniden dener |

Supabase ve Vercel değişkenleri **birbirinin yerine geçmez**: satın alma doğrulaması yalnızca Supabase secret'larını, Admin Paneli katalog kontrolü yalnızca Vercel değişkenlerini okur.

**Yayın sırası:** (1) migration `20261028000100_billing_event_retry.sql`, (2) `billing-verify-purchase` ve `billing-webhook` deploy, (3) uygulama sürümü. Yeni uygulama yalnızca `granted: true` yanıtını başarı sayar; eski sunucuyla çalışırsa satın alma doğrulanmış sayılmaz. Geri alma: önce uygulama sürümünü durdurun, sonra fonksiyonları eski sürüme, en son `supabase/rollbacks/20261028000100_billing_event_retry.down.sql` dosyasını çalıştırın (yalnızca fonksiyon gövdelerini eski haline getirir, veri silmez).
