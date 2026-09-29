# Bebeğimin İlk Yılı — Master Implementation Planı ve Uygulama Sözleşmesi

> **Belge türü:** Codex / Claude için doğrudan uygulanabilir ana teknik anayasa  
> **Dil:** Türkçe  
> **Kapsam:** Mevcut çalışan Flutter + Supabase uygulamasının korunarak yeni ürün modeline geçirilmesi  
> **Temel ilke:** Sıfırdan uygulama yazma. Mevcut güçlü mimariyi koru; yaşam döngüsü, güvenlik, ödeme ve premium çıktı katmanlarını kontrollü migration'larla ekle.

---

## 0. Bu belge nasıl kullanılacak?

Bu dosya yalnız bir fikir listesi değildir. Uygulamayı geliştirecek Codex veya Claude için bağlayıcı uygulama sözleşmesidir.

Kullanıcı örneğin **“Faz 4'te kaldık; master planı oku ve Faz 4'ü uygula”** dediğinde:

1. Bu belgenin tamamını oku.
2. “Değiştirilemez ürün kuralları” bölümünü önceki sohbetlerden daha yüksek öncelikli kabul et.
3. `PHASE_STATUS.md`, son faz raporu, migration geçmişi, test sonuçları ve Git durumunu incele.
4. Önceki fazların çıkış koşullarının gerçekten sağlandığını doğrula.
5. Yalnız istenen fazın kapsamını uygula. Zorunlu güvenlik düzeltmesi dışında sonraki fazlara geçme.
6. Önceki fazların veri modeli, API, RLS ve kullanıcı deneyimi sözleşmelerini bozma.
7. Faz sonunda testleri çalıştır, rapor yaz, tek amaçlı commit/checkpoint oluştur ve dur.

Bir önceki faz eksikse sessizce varsayım yapma. Eksikliği raporla; mevcut faz için zorunlu olan en küçük düzeltmeyi ayrı commit olarak tamamla veya kullanıcıdan karar iste.

### Normatif kelimeler

- **ZORUNLU:** Uygulama ve kabul için şarttır.
- **YASAK:** Yapılmamalıdır.
- **ÖNERİLEN:** Güçlü varsayılan; aksi gerekçelendirilmelidir.
- **GELECEK:** Bu master planın aktif kapsamı dışındadır.

### Kaynak önceliği

Çelişki halinde şu sıra geçerlidir:

1. Bu belgedeki “Değiştirilemez ürün kuralları”.
2. Kullanıcının bu belgeden sonra açıkça verdiği yeni kararlar.
3. Tamamlanmış fazların migration ve API sözleşmeleri.
4. Mevcut kod davranışı.
5. Eski analiz raporundaki öneriler.

Eski rapordaki `365 gün` varsayımı geçersizdir. Nihai teknik yaşam döngüsü **375 gün + en fazla 30 gün onaylı uzatma** olarak uygulanacaktır.

---

## 1. Mevcut sistem hakkında doğrulanmış bulgular

Bu plan aşağıdaki gerçek mevcut mimariyi koruyarak ilerler:

- İstemci Flutter'dır; feature-first katmanları `domain`, `data`, `application`, `presentation`, ortak `core` yapısıdır.
- State yönetimi Riverpod 3, navigasyon `go_router` ve `StatefulShellRoute` tabanlıdır.
- Backend Supabase Auth, PostgreSQL, RLS, private Storage ve Edge Function'lardan oluşur.
- Kimlik doğrulamada e-posta/şifre, e-posta doğrulama, PKCE, şifre sıfırlama ve deep link akışları vardır.
- Aile üyeliği bugün global household yerine bebek bazlı `family_members` çemberiyle çalışır.
- Aktif bebek cihazda tutulur ve `activeBabyProvider` ile özelliklere yayılır.
- İçerikler: anılar, fotoğraflar, videolar, ilkler, mektuplar, yorum/notlar, zaman kapsülleri, favoriler, özel gün kategorisi, profil hikâyesi ve kitap projesidir.
- `baby_id` foreign key, bileşik foreign key, RLS ve Storage path yapısı genel olarak güçlüdür.
- Private Storage yolları bebek ve kayıt kimliğini içerir.
- `timeline_entries` security-invoker view olarak alttaki RLS kurallarına uyar.
- Mevcut kitap/PDF altyapısı gerçektir ve kapsamlıdır: `BookComposer`, `BookRenderResolver`, `BookPdfBuilder`, üç boyut, bölüm/öğe düzenleme, Türkçe font, TrimBox/BleedBox, sürümleme ve export davranışı vardır.
- Film ve offline HTML için mevcut feature, tablo, route, job veya artifact altyapısı yoktur.
- Abonelik, ödeme, entitlement, platform Super Admin ve uzatma modeli yoktur.
- Mevcut sistem bir yaş sonrasında da yazmaya izin verir; yeni model bu davranışı kontrollü olarak tersine çevirecektir.

### Korunacak güçlü parçalar

- Mevcut feature-first mimari ve isimlendirme yaklaşımı.
- `baby_id` tabanlı izolasyon ve bileşik foreign key örüntüsü.
- Mevcut aile rol/yetki altyapısının işe yarayan bölümleri.
- Private bucket yaklaşımı ve kayıtla doğrulanan Storage yolları.
- Kitap editörü, `BookComposer`, render resolver ve PDF motoru.
- Zaman kapsülü gizliliği, author/uploader sahteciliği önlemleri, son yöneticiyi silmeme gibi mevcut güvenlik kontrolleri.
- Hesap/KVKK silme için ayrı privileged yol.

### Düzeltilmesi zorunlu mevcut açıklar

- Bazı detay route ve sorguları yalnız `contentId` taşır; aynı kullanıcı iki bebeğe erişebildiğinde yanlış bebeğin bağlamı kullanılabilir.
- Lifecycle hiçbir content RLS, Storage policy veya ortak mutation guard içinde uygulanmaz.
- Profil aktifken kitap taslağı, düzenleme, önizleme, export ve indirme mümkündür.
- Doğum tarihi lifecycle'ı ileri taşıyacak şekilde değiştirilebilir.
- Upload kuyruğu kapanış sınırını geçebilir.
- Kitap Storage okuması gerçek artifact/export kaydına yeterince sıkı bağlı değildir.
- Resmî premium artifact üretiminin yalnız istemcide olması lisans sınırını güvenli kılmaz.

---

## 2. Değiştirilemez ürün kuralları

### 2.1 Yaşam döngüsü

1. Her bebek için standart aktif dönem doğum tarihinden itibaren **375 takvim günüdür**.
2. `base_close_date = birth_date + 375 gün` olarak hesaplanır.
3. Onaylanmış uzatma yoksa:
   - `business_date < base_close_date` → `ACTIVE`
   - `business_date >= base_close_date` → `LOCKED`
4. Bir defaya mahsus, **1–30 tam gün** uzatma istenebilir.
5. Uzatmayı yalnız platform **Super Admin** onaylayabilir veya reddedebilir.
6. Onaylanmışsa `effective_close_date = base_close_date + approved_days` olur.
7. Hiçbir bebek `birth_date + 405 gün` sonrasına kadar aktif kalamaz.
8. `status` elle güncellenen bir boolean/enum olarak esas alınmayacaktır. Durum server'ın resmi iş tarihi, doğum tarihi ve değiştirilemez uzatma kararından türetilecektir.
9. Ürün iş saat dilimi **Europe/Istanbul**'dur. İstemci saati karar kaynağı değildir.
10. Tarih sınırı yarı açık aralıkla uygulanır: kapanış tarihinin İstanbul saatine göre başladığı anda profil `LOCKED` olur.
11. 365. gün/birinci doğum günü ve onu takip eden standart 10 günlük final dönemi 375 günlük sürenin içindedir.
12. Onaylı ek sürede eklenen geçerli içerikler Kitap, Film ve HTML kaynak arşivine dahildir.
13. Abonelik, ödeme veya premium ürün satın alma lifecycle'ı uzatamaz, kısaltamaz, yeniden açamaz.

#### Pending uzatma için kesin uygulama kuralı

Eski konuşmada “pending talep sonuçlanana kadar profili açık tutma” fikri önerilmiş ancak kesinleştirilmemiştir ve **405 günlük mutlak tavanla çelişebilir**. Bu nedenle bu planda uygulanacak güvenli sözleşme şudur:

- Uzatma talebi yalnız profil `ACTIVE` iken ve `base_close_date` gelmeden yapılabilir.
- Operasyon/Super Admin kuyruğunda talebin kapanıştan önce sonuçlandırılması için uyarı ve SLA oluşturulur.
- `base_close_date` geldiğinde hâlâ pending olan talep atomik olarak `expired` olur ve profil `LOCKED` kalır.
- Profil pending nedeniyle otomatik açık tutulmaz; sonradan yeniden açılmaz.
- Kullanıcı bu davranışı değiştirmek isterse bu anayasanın lifecycle sürümü açıkça revize edilmeden kod değiştirilmez.

### 2.2 ACTIVE profilde izinler

Yetkiler dahilinde şu işlemler açıktır:

- Anı, fotoğraf, video, ilk, mektup, yorum/not ve zaman kapsülü oluşturma.
- Mevcut içeriği düzenleme/silme.
- Bebek profilini izinli sınırlar içinde yönetme.
- Aile üyeliği/davetleri yönetme.
- Uzatma hakkı varsa tek uzatma talebi oluşturma.
- Arşiv, takvim, arama ve görüntüleme.

Şu işlemler herkes için tamamen kapalıdır; Anne/Baba ve Super Admin'in normal kullanıcı oturumu da istisna değildir:

- Kitap alanını açma veya kitap taslağı görme.
- Kitap/Film/HTML önizleme.
- Kitap/Film/HTML satın alma.
- Kitap/Film/HTML oluşturma/render etme.
- Kitap/Film/HTML artifact indirme veya yeniden indirme.
- Eski/legacy premium proje veya export'larını görme.

UI'da devre dışı bir kart göstermek tek başına yeterli değildir. Route, provider/repository, RPC, RLS ve Storage katmanları da reddetmelidir.

### 2.3 LOCKED profilde izinler

Şunlar açıktır:

- Arşiv, takvim, arama ve geçmiş içeriği salt okunur görüntüleme.
- Uygun lifecycle + abonelik + entitlement koşullarıyla Kitap/Film/HTML işlemleri.
- Satın alınmış final artifact'ların yetkili kişilerce indirilmesi/yeniden indirilmesi.
- Aile üyesi ekleme/çıkarma ve çıktı indirme izni yönetimi; bunlar arşiv içeriği değildir.
- Kullanıcıya özel favori işaretleri; bunlar kaynak arşivi veya çıktı snapshot'ını değiştiremez.
- Yasal hesap/veri silme süreçleri.

Şunlar kapalıdır:

- Bebek adı, doğum tarihi, avatar, kapak, hikâye veya lifecycle'ı etkileyen profil alanlarını normal kullanıcı olarak değiştirme.
- Anı, medya, ilk, mektup, yorum/not, zaman kapsülü veya bebeğe özel milestone tipi ekleme/düzenleme/silme.
- Storage'a yeni kaynak medya yazma, var olanı değiştirme/silme.
- `include_in_book` gibi kaynak içerik alanlarını değiştirme.

LOCKED profilde ortadaki büyük `+` butonu gizlenir. Kullanıcıya önce aksiyon verip sonra hata göstermek kabul edilmez.

### 2.4 Çoklu bebek izolasyonu

1. Her liste, detay, provider, cache, route, repository sorgusu, mutation ve artifact anahtarı bebek bağlamını açıkça taşır.
2. Detay kimliği en az `(babyId, contentId)` olmalıdır.
3. Repository sorgusu hem `id` hem `baby_id` ile sınırlandırılır.
4. Dönen modelin `babyId` değeri route `babyId` ile eşleşmezse erişim reddedilir ve güvenlik olayı loglanır.
5. Defne `LOCKED`, Ece `ACTIVE` olabilir; birinin lifecycle, üyelik, lisans, içerik, sayaç, önbellek veya artifact durumu diğerine geçmez.
6. Bir bebeğin Book entitlement'ı kardeş bebeğe Film/HTML/Book hakkı vermez.
7. Aktif bebek UI kolaylığıdır; güvenlik ve veri seçimi için örtük kaynak olamaz.

### 2.5 Aile, roller ve aile paketi aboneliği

1. Anne ve Baba iki ayrı kullanıcı hesabı ve iki ayrı login kullanır.
2. İki ebeveyn eşit yönetici hakkına sahiptir; “hesabı ilk açan daha yetkili” ürün davranışı oluşturulmaz.
3. Ebeveynler tek bir aile hesabına (`family_account`) bağlıdır.
4. Abonelik kişiye veya bebeğe değil, **`family_account` seviyesinde tek paket aboneliğidir**. Anne ve Baba ayrı ayrı ücret ödemez; Family Member'ın ayrı/bireysel ücretli aboneliği yoktur.
5. İlk ebeveyn ikinci ebeveyni davet eder. İki aktif ebeveyn sınırı (`max_parent_seats = 2`) kontrollü RPC/transaction ile korunur.
6. Anne veya Baba Family Member davet edebilir.
7. Aile üyeliği, lifecycle, subscription ve product entitlement birbirinden ayrı kavramlardır.
8. Abonelik kaybı bebeği `ACTIVE` veya `LOCKED` yapmaz ve satın alınmış entitlement'ı silmez.

#### 2.5.1 Aile paketi planları

Her plan Anne + Baba'yı içerir; parent hesapları Family Member kapasitesinden sayılmaz.

| Plan | `plan_code` | `max_parent_seats` | `max_family_members` | Maks. aktif kullanıcı | Aylık | Aylık `price_minor` | Yıllık (%10 indirimli) | Yıllık `price_minor` |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Small Family | `small_family` | 2 | 3 | 5 | 299 TL | `29900` | 3.229,20 TL | `322920` |
| Normal Family | `normal_family` | 2 | 6 | 8 | 369 TL | `36900` | 3.985,20 TL | `398520` |
| Large Family | `large_family` | 2 | 12 | 14 | 469 TL | `46900` | 5.065,20 TL | `506520` |

- `billing_period`: `monthly | annual`; `currency`: `TRY`.
- Yıllık fiyat kuralı: `annual_price = monthly_price × 12 × 0.90`; yani 12 aylık toplam üzerinden %10 indirim. İndirimsiz yıllık toplamlar: Small 3.588 TL, Normal 4.428 TL, Large 5.628 TL.
- Plan fiyatlarının ve kapasitelerinin tek resmî kaynağı server-side plan kataloğu / payment provider mapping'dir. Fiyat ve kapasite Flutter, RPC veya Edge Function içine dağınık hard-code edilmez; istemci katalogdan okur.

#### 2.5.2 Family Member erişimi ve kapasite

- Family Member, `family_account`'un mevcut aboneliği kapsamında kullanılır; ayrı abonelik gerektirmez.
- Family Member erişimi için tümü gerekir:
  1. `family_account` aboneliği aktiftir.
  2. Kullanıcı bu `family_account` içinde aktif Family Member'dır.
  3. Aktif Family Member sayısı planın `max_family_members` kapasitesini aşmaz.
  4. İlgili permission kuralları sağlanır.
- Kapasite (Small 3 / Normal 6 / Large 12; parent'lar hariç) Family Member daveti ve aktivasyonu sırasında **server-side**, transaction/RPC ile ve eşzamanlı isteklere dayanıklı biçimde kontrol edilir. Yalnız Flutter/UI kontrolü yeterli değildir.
- Kapasite doluyken yeni Family Member aktif hale getirilemez.

#### 2.5.3 Plan değişikliği

- Upgrade yolları: Small → Normal, Small → Large, Normal → Large. Upgrade doğrulanmış provider olayıyla aktifleştiğinde yeni kapasite kullanılabilir hale gelir.
- Downgrade sırasında aktif Family Member sayısı yeni plan kapasitesinden yüksekse üyeler otomatik silinmez, üyelerin verileri silinmez ve permission'lar sessizce değiştirilmez.
- Bu durum subscription/provider policy tarafından kontrollü şekilde ele alınır; kesin politika (ör. kapasite uygun hale gelene kadar downgrade'i bekletmek veya parent'ın açık seçimini istemek) Faz 6 ADR'ında belgelenir.

#### 2.5.4 Çoklu bebek

- Abonelik bebeğe değil `family_account`'a aittir ve aynı aile hesabındaki tüm bebekleri kapsar. Yeni kardeş plan fiyatını artırmaz; her bebek için ayrı abonelik alınmaz.
- Örnek: Anne, Baba, 3 Family Member, Defne ve Ece aynı `family_account` altındaysa Small Family yeterlidir.
- Buna rağmen her bebeğin lifecycle'ı, ACTIVE/LOCKED durumu, extension hakkı, immutable snapshot'ı, premium entitlement'ları ve final artifact'ları birbirinden bağımsızdır.

### 2.6 Premium ürünler ve lisanslar

Premium ürünler birbirinden bağımsız, baby-scoped, tek seferlik dijital satın alımlardır:

| Ürün | Kod | Teslim formatı | Tek seferlik fiyat | `price_minor` | Kapsam |
|---|---|---|---:|---:|---|
| Dijital İlk Yıl Kitabı | `first_year_book` | PDF | 349 TL | `34900` | Bebeğe ait resmî, baskıya hazır dijital PDF artifact; fiziksel baskı dahil değildir |
| Offline HTML Hatırası | `first_year_html` | Offline HTML bundle / ZIP | 449 TL | `44900` | LOCKED arşivin immutable, interaktif, internetsiz açılabilen kopyası |
| İlk Yıl Filmi | `first_year_film` | MP4 | 549 TL | `54900` | İçeriğe göre dinamik süre, en fazla 10 dakika resmî video artifact |

Kurallar:

- Fiyatlar veritabanında kuruş olarak `first_year_book = 34900`, `first_year_html = 44900`, `first_year_film = 54900`, para birimi `TRY` tutulur.
- Bu üç fiyat bağlayıcı premium fiyat setidir; farklı eski veya taslak premium fiyatlar katalog seed'i, test, UI metni ya da provider eşlemesinde kullanılamaz. Small Family aylık abonelik fiyatı premium ürün fiyatı değildir.
- Premium fiyatların tek resmî kaynağı server-side product catalog / price configuration kaydıdır; ödeme sağlayıcısı ürün/SKU eşlemesi (payment provider mapping) bu katalogla eşleştirilir. Fiyatlar Flutter, Edge Function, RPC veya UI metinlerine dağınık hard-code edilmez; istemci fiyatı katalogdan okur.
- Fiyat değişikliği yeni sürümlü katalog kaydıdır; entitlement, lifecycle veya ACTIVE/LOCKED mantığını değiştirmez.
- Fiziksel/basılı kitap bu ürünlerden biri değildir ve kataloğa sabit fiyatlı premium ürün olarak eklenmez; bkz. 2.9.1.
- Siparişte fiyat/para birimi snapshot'ı alınır; katalog fiyatı sonradan değişse de geçmiş sipariş değişmez.
- Entitlement satın alan kullanıcıya değil **`familyAccountId + babyId + productCode`** üçlüsüne aittir.
- Anne satın aldıysa Baba aynı bebek/ürün için yeniden satın almaz.
- Book satın almak Film veya HTML hakkı vermez; her ürün ayrı entitlement'dır.
- Aynı bebek/ürün için başarılı entitlement idempotent ve benzersizdir.
- İade, chargeback ve fraud durumları append-only ödeme olaylarıyla işlenir; geçmiş silinmez.
- Premium satış yalnız `LOCKED` profilde mümkündür.

### 2.7 Re-download ve Family Member indirme

- Satın alınmış entitlement kalıcı iş kaydıdır; abonelik kesilince silinmez.
- Artifact üretimi tamamlanmışsa Anne ve Baba, `family_account` aboneliği aktifken yeniden indirebilir.
- Aile aboneliği pasifken artifact ve entitlement korunur; indirme kapatılır, abonelik yeniden etkinleşince re-download tekrar açılır.
- Family Member yalnız şu koşulların tümünde final artifact indirebilir:
  1. Aynı aile hesabında aktif Family Member üyeliği vardır.
  2. `family_account` aboneliği aktiftir ve plan kapasitesi aşılmamıştır (bkz. 2.5.2). Family Member'dan ayrı/bireysel abonelik aranmaz.
  3. Anne veya Baba ilgili bebek ve ürün için `download_final_artifact` izni vermiştir.
  4. Bebek `LOCKED` durumdadır.
  5. İlgili product entitlement aktiftir.
  6. Artifact `ready` ve doğrulanmış durumdadır.
- Family Member satın alma yapamaz, kaynak seçemez, manifest değiştiremez, render başlatamaz, yeniden oluşturamaz veya düzenleyemez.
- İzin ürün bazında verilir; Book izni Film/HTML izni değildir.
- Bu re-download kuralları Dijital Kitap (PDF), Film (MP4) ve Offline HTML (ZIP) için aynıdır; fiyat değişikliği bu kuralları değiştirmez.
- İndirme yetkisi kısa ömürlü, kullanıcıya özel signed URL veya yetkili download endpoint'i üzerinden her istekte yeniden doğrulanır.

### 2.8 Resmî çıktı sözleşmesi

- Tüm premium çıktılar aynı sürümlenmiş, immutable **archive source snapshot/manifest** üzerinden beslenir.
- Snapshot üretim anındaki içerik, tarih, yazar adı/yakınlık, metin, medya kimliği, checksum ve seçim bilgisini sabitler.
- Canlı profil adı veya aile ilişkisi sonradan değişse de eski artifact kendiliğinden değişmez.
- Yeni artifact sürümü istenirse yeni snapshot ve job oluşturulur; eski kayıt silinmez.
- Resmî artifact üretimi backend job ile doğrulanır. Mevcut istemci PDF motoru korunabilir ancak resmî lisanslı artifact kaydı server tarafından verilmeden indirilebilir ürün sayılmaz.
- Her artifact'ta `baby_id`, `product_code`, `snapshot_id`, `version`, `storage_path`, `mime_type`, `byte_size`, `sha256`, durum ve zaman damgaları bulunur.
- Storage okuması gerçek ve yetkili `output_artifacts` kaydına bağlı olmak zorundadır.

### 2.9 Dijital Kitap

- `first_year_book` bir **dijital üründür**. Satın alınan ana artifact baskıya hazır PDF'tir; **349 TL** tek seferlik fiyat (`34900` TRY) yalnız bu dijital PDF entitlement'ını kapsar.
- Mevcut BookComposer/PDF altyapısı yeniden yazılmayacaktır.
- Kapak, hoş geldin, doğum, 1–12. ay, ilkler, aile mektupları, “Bir Yaşındayım”, arka kapak yapısı korunur.
- Bölüm/öğe seçimi, gizleme, sıralama, özel sayfa, kapak, başlık, not ve açıklama yetenekleri korunur.
- A4, 21×21, 30×30; önizleme ve baskıya hazır PDF kalitesi; TrimBox/BleedBox; gömülü Türkçe fontlar korunur. Bunlar PDF'in teknik özellikleridir; fiziksel baskı hizmeti anlamına gelmez.
- Kaynak arşiv LOCKED olduğu için düzenleme `book_items`/proje konfigürasyonu üzerinde yapılır; kaynak content satırları değiştirilmez.
- ACTIVE profilde mevcut eski projeler dahil hiçbir kitap verisi kullanıcıya açılmaz.

#### 2.9.1 Fiziksel / basılı kitap

- Fiziksel kitap `first_year_book` entitlement'ına ve 349 TL fiyata **dahil değildir**.
- Fiziksel kitap ayrı bir destek/sipariş hizmetidir; sabit ürün fiyatı yoktur ve bu belgede sabit TRY fiyatı tanımlanmaz.
- Fiyatı istenirse şu değişkenlere göre ayrıca hesaplanır: sayfa sayısı, kitap ölçüsü, kağıt türü, kapak/cilt seçeneği, güncel matbaa/baskı maliyeti, kargo ve gerekiyorsa baskı/hizmet bedeli.
- Premium entitlement modeli (`products`, `orders`, `product_entitlements`) fiziksel baskı siparişi için kullanılmaz; fiziksel baskı siparişi premium entitlement üretmez, premium entitlement da fiziksel baskı hakkı vermez.
- İleride fiziksel kitap sipariş sistemi geliştirilecekse ayrı order/fulfillment akışı olarak tasarlanır (GELECEK). Faz 0–13 kapsamına matbaa, baskı, kargo veya fulfillment entegrasyonu eklenmez.

### 2.10 Film

- `first_year_film` tek seferlik **549 TL** (`54900` TRY) fiyatlı dijital üründür; final artifact MP4'tür.
- Film resmî çıktısı en fazla **10 dakika** olabilir; job planı ve son artifact süresi server tarafından doğrulanır.
- 10 dakika hedef süre değil **üst sınırdır**. Süre içerik miktarına göre dinamik belirlenir; içerik azsa film yapay şekilde 10 dakikaya uzatılmaz.
- Film LOCKED arşivin immutable snapshot'ından, server-side output job/artifact pipeline'ı ile üretilir; final filmin Flutter cihazında render edilmesi öngörülmez.
- Fotoğraf, video, tarih, anı, ilk, özel gün, mektup, metin, müzik/seslendirme tercihleri manifest tabanlıdır.
- Thumbnail, codec/transcoding, retry, progress, cancellation, checksum ve kaynak sürüm bilgisi bulunur.
- Çıktı indirilebilir yaygın bir MP4 profilinde üretilir; kesin codec/bitrate platform testiyle belirlenir.

### 2.11 Offline HTML

- `first_year_html` tek seferlik **449 TL** (`44900` TRY) fiyatlı dijital üründür.
- Amacı LOCKED First Year Archive'ın kalıcı, interaktif, internetsiz kullanılabilen dijital hatıra kopyasıdır; yaşayan/düzenlenebilir bir günlük değildir.
- Profil LOCKED olduktan sonra (375 günlük temel dönem ve varsa onaylı uzatma bittikten sonra) mühürlenen immutable snapshot'tan üretilir.
- Final HTML artifact immutable'dır: içine sonradan yeni anı, fotoğraf, video, mektup, milestone veya başka kaynak içerik eklenemez; mevcut içerik değiştirilemez veya silinemez. Paket içerik ekleme/düzenleme arayüzü veya sunucuya yazma yolu içermez.
- Hosting zorunluluğu yoktur; final artifact gerekli HTML/CSS/JS/medya dosyalarını içeren ZIP/bundle olabilir.
- Ürün tek bir uzaktaki web sayfası veya signed URL koleksiyonu değildir.
- İndirilen paket tüm gerekli HTML/CSS/JS/font/medyayı göreli yerel yollarla içermelidir.
- Süresi dolan Supabase signed URL'leri bundle içine gömülmez.
- Paket ZIP olarak indirilebilir; çıkarıldığında desteklenen masaüstü/mobil tarayıcıda internetsiz çalışmalıdır.
- Paket manifest, checksum, sürüm, byte size ve güvenli dosya adı listesi içermelidir.
- Harici ağ çağrıları varsayılan olarak yasaktır; telemetry/cdn bağımlılığı offline artifact içinde bulunmaz.

### 2.12 Kapsam dışı

**Kardeşlerin kitaplarını, videolarını veya HTML arşivlerini tek birleşik ürün/çıktıda birleştirme fikri GELECEK kapsamındadır.**

Bu plan kapsamında:

- Birleştirilmiş kardeş artifact'ı,
- Çok bebekli tek kitap,
- Kardeşler arası ortak film timeline'ı,
- Tek HTML paketinde birden çok bebek,
- Bundle indirimi veya bundle fiyatı

tasarlanmayacak ve uygulanmayacaktır. Veri modeli gelecekte birleşmeye engel olmayabilir; ancak bugünkü entitlement, snapshot, job ve artifact'lar daima tek `baby_id` taşır.

**Fiziksel/basılı kitap sipariş, baskı ve fulfillment akışı da GELECEK kapsamındadır** (bkz. 2.9.1); bu planın hiçbir fazında uygulanmaz.

---

## 3. Çapraz katman mimari sözleşmeleri

### 3.1 Dört ayrı yetki ekseni

Her hassas işlem aşağıdaki dört ekseni ayrı ayrı doğrulamalıdır:

| Eksen | Soru | Örnek |
|---|---|---|
| Membership | Kullanıcı bu aile/bebeğe bağlı mı? | Ece'nin teyzesi mi? |
| Lifecycle | Bebek ACTIVE mi LOCKED mı? | İçerik yazılabilir mi? |
| Subscription | `family_account` paket aboneliği aktif mi, kapasite uygun mu? | Re-download açılabilir mi? |
| Entitlement | Bu bebek için bu ürün satın alınmış mı? | Defne Film lisansı var mı? |

Bu eksenler tek bir `has_access` boolean'ına sıkıştırılmayacaktır.

### 3.1.1 Premium erişim karar matrisi

| İşlem | Lifecycle | Rol/üyelik | Abonelik | Entitlement |
|---|---|---|---|---|
| Ürünleri/fiyatları görme | LOCKED | Aktif parent | Gerekmez; pasifse abonelik uyarısı göster | Gerekmez |
| Ürün satın alma | LOCKED | Aktif parent | Aktif `family_account` aboneliği | Henüz olmamalı |
| Proje düzenleme / render başlatma | LOCKED | Aktif parent | Aktif `family_account` aboneliği | İlgili ürün için aktif |
| Parent indirme / re-download | LOCKED | Aktif parent | Aktif `family_account` aboneliği | İlgili ürün için aktif + ready artifact |
| Family Member final indirme | LOCKED | Aktif member + ürün bazlı parent izni | Aktif `family_account` aboneliği + plan kapasitesi içinde (bkz. 2.5.2); ayrı member aboneliği yok | İlgili ürün için aktif + ready artifact |

Subscription pasif olduğunda ürün ve sahiplik bilgisi kaybolmaz; kullanıcıya yeniden etkinleştirme yolu gösterilir. Bu matris hiçbir koşulda lifecycle'ı değiştirmez.

### 3.2 Server gerçeği

- Lifecycle, ödeme ve entitlement kararı server kaynaklıdır.
- Flutter yalnız server özetini gösterir; istemci tarihi veya yerel cache güvenlik kararı veremez.
- UI gizleme bir güvenlik kontrolü sayılmaz.
- RLS, trigger/guard, RPC ve Storage policy birlikte uygulanır.
- `SECURITY DEFINER` fonksiyonlarda sabit `search_path`, açık rol kontrolü ve en dar `GRANT` zorunludur.

### 3.3 Route ve cache anahtarları

- Route örneği: `/babies/:babyId/memories/:contentId`.
- Provider family örneği: `(babyId, contentId)`.
- Repository örneği: `.eq('baby_id', babyId).eq('id', contentId)`.
- Cache key, upload queue namespace, local draft ve analytics context `userId + babyId + recordId` içermelidir.
- Logout ve aile/bebek değişiminde kullanıcıya/bebeğe özel kuyruk ve hassas cache temizlenmelidir.

### 3.4 Mutation matrisi

LOCKED durumda aşağıdaki kaynaklarda `INSERT/UPDATE/DELETE` backend tarafından reddedilir:

- `babies` içindeki arşiv/profil alanları,
- `memories`,
- `milestones`,
- bebeğe özel `milestone_types`,
- `letters`,
- `media`,
- `comments`,
- `time_capsules` ve içerikleri,
- kaynak Storage objeleri,
- kaynak içerik seçimini değiştiren alanlar.

Lifecycle'dan ayrı kalabilecekler:

- Aile hesabı üyeliği ve davetler,
- Abonelik/ödeme kayıtları,
- Product entitlement,
- Output proje konfigürasyonu, job ve artifact,
- Kişisel favorites,
- Yasal silme/mahremiyet operasyonları.

### 3.5 Doğum tarihi düzeltmesi

- Doğum tarihi lifecycle'ın güvenlik girdisidir; sıradan profil alanı gibi sınırsız değiştirilemez.
- İçerik oluşmadan önce Anne/Baba kontrollü RPC ile düzeltebilir; audit log zorunludur.
- İçerik oluştuktan sonra veya profil LOCKED olduktan sonra yalnız Super Admin, gerekçe ve önce/sonra değerleriyle düzeltebilir.
- Düzeltme, uzatma hakkını sıfırlamaz ve ikinci uzatma hakkı üretmez.
- Düzeltme sonucu kapanmış profil açılacaksa açık bir admin onayı ve güvenlik olayı gerekir; otomatik yan etki yasaktır.

### 3.6 Gizlilik ve yasal silme

- Immutable archive iş kuralı yasal silme hakkını engellemez.
- Hesap/KVKK silme işlemleri normal kullanıcı mutation policy'sinden ayrı, audited privileged servis yolundan yürür.
- Silme; artifact, ödeme ve vergi kayıtlarının yasal saklama zorunluluğunu sınıflandırılmış retention politikasıyla ele alır.
- Service-role hiçbir normal UI işleminde kullanılmaz.

---

## 4. Hedef veri modeli

İsimler mevcut repo konvansiyonuna uydurulabilir; anlam ve benzersizlikler korunmalıdır.

### 4.1 Platform ve lifecycle

#### `platform_user_roles`

- `user_id`
- `role` (`super_admin`)
- `granted_by`, `granted_at`, `revoked_at`
- İstemci doğrudan yazamaz.

#### `baby_extension_requests`

- `id`, `baby_id`, `requested_by`
- `requested_days` check `1..30`
- `status`: `pending | approved | rejected | expired`
- `decided_by`, `decided_at`, `decision_note`
- `created_at`, `updated_at`
- `UNIQUE (baby_id)`; reddedilmiş/expired talep de ikinci başvuruyu açmaz.
- Karar alanları immutable; yalnız karar RPC'si yazar.

#### Lifecycle fonksiyonları

- `business_date_istanbul()`
- `baby_base_close_date(baby_id)`
- `baby_approved_extension_days(baby_id)`
- `baby_effective_close_date(baby_id)`
- `baby_is_active(baby_id)`
- `baby_is_locked(baby_id)`
- `baby_lifecycle_summary(baby_id)`
- `assert_baby_active(baby_id)`

Özet en az `status`, `base_close_date`, `effective_close_date`, `remaining_days`, `extension_status`, `can_request_extension` döndürür.

### 4.2 Aile hesabı ve abonelik

#### `family_accounts`

- `id`, `display_name`, `created_by`, `created_at`, `status`

#### `family_account_members`

- `family_account_id`, `user_id`
- `role`: `parent | family_member`
- `relationship_label`
- `status`: `invited | active | suspended | removed`
- `invited_by`, zaman damgaları
- En fazla iki aktif parent (`max_parent_seats`), yalnız transaction/RPC ile korunur.
- Aktif Family Member sayısı aktif planın `max_family_members` değerini aşamaz; davet ve aktivasyonda transaction/RPC ile korunur. Parent'lar bu sayıya dahil değildir.

#### `family_account_babies`

- `family_account_id`, `baby_id`
- Her bebek aynı anda tek aktif aile hesabına bağlıdır.

#### `subscription_plans`

- `code`: `small_family | normal_family | large_family`
- `max_parent_seats`: `2` (tüm planlar)
- `max_family_members`: `3`, `6`, `12`
- Fiyatlar plan + `billing_period` (`monthly | annual`) bazında tutulur:
  - `monthly` `price_minor`: `29900`, `36900`, `46900`
  - `annual` `price_minor`: `322920`, `398520`, `506520`
- `currency`: `TRY`
- Yıllık fiyat `monthly_price × 12 × 0.90` kuralına uymak zorundadır; seed ve testler bu eşitliği doğrular.
- Ödeme sağlayıcısı ürün/SKU eşlemesi plan + `billing_period` bazındadır.
- Plan fiyat ve kapasitesinin tek resmî kaynağıdır. Katalog kaydı sürümlü/aktiflik tarihli olmalıdır.

#### `subscriptions`

- `id`, `family_account_id`
- Abonelik yalnız `family_account`'a bağlıdır; kişi bazlı beneficiary alanı veya Family Member aboneliği yoktur.
- Bir `family_account` için aynı anda en fazla bir aktif abonelik bulunur.
- `plan_code`, `billing_period`, `status`
- `provider`, `provider_customer_id`, `provider_subscription_id`
- `current_period_start/end`, `cancel_at_period_end`
- `created_at`, `updated_at`
- Provider olayları değil, doğrulanmış projeksiyondur.

#### `billing_events`

- Provider webhook/receipt olayları append-only tutulur.
- Provider event ID benzersiz ve idempotent olmalıdır.
- İmza/receipt server-side doğrulanmadan subscription açılmaz.

### 4.3 Premium katalog ve entitlement

#### `products`

- `code`: `first_year_book | first_year_html | first_year_film`
- `price_minor`: `34900`, `44900`, `54900`
- `currency`: `TRY`
- sürüm, aktiflik tarihleri, ödeme sağlayıcısı ürün/SKU eşlemesi
- Premium fiyatların tek resmî kaynağıdır; fiziksel/basılı kitap bu katalogda sabit fiyatlı ürün olarak yer almaz.

#### `orders` ve `order_events`

- Aile hesabı, kullanıcı, baby, product, fiyat snapshot'ı, provider referansı, durum.
- Yalnız premium dijital ürün siparişleri içindir; fiziksel baskı siparişi/fulfillment bu tablolara karıştırılmaz.
- Ödeme olayları append-only; order durumu idempotent projeksiyon.

#### `product_entitlements`

- `family_account_id`, `baby_id`, `product_code`
- `source_order_id`, `status`, `granted_at`, `revoked_at`
- Aktif kayıt için benzersiz `family_account_id + baby_id + product_code`.

#### `artifact_download_permissions`

- `family_account_id`, `baby_id`, `product_code`, `member_user_id`
- `granted_by`, `granted_at`, `revoked_at`
- Yalnız aktif parent yönetebilir.

### 4.4 Snapshot, job ve artifact

#### `archive_snapshots`

- `id`, `baby_id`, `schema_version`, `content_version`
- `manifest_json`, `manifest_sha256`
- `created_by`, `created_at`, `sealed_at`
- Sealed snapshot immutable.

#### `output_projects`

- `id`, `baby_id`, `product_code`, `entitlement_id`
- Ürüne özel edit konfigürasyonu; kaynak içerik değiştirmez.

#### `output_jobs`

- `id`, `baby_id`, `product_code`, `project_id`, `snapshot_id`
- `status`: `queued | running | succeeded | failed | canceled`
- `attempt_count`, `max_attempts`, `progress`, `error_code`, `error_detail`
- İdempotency key, worker lease/heartbeat, created/started/finished timestamps.

#### `output_artifacts`

- `id`, `job_id`, `baby_id`, `product_code`, `snapshot_id`
- `version`, `storage_path`, `mime_type`, `byte_size`, `sha256`
- `status`: `staging | ready | quarantined | revoked`
- Artifact ready olmadan download yoktur.

### 4.5 Activity ve notification

En az şu olayları üret:

- `extension_requested`, `extension_approved`, `extension_rejected`, `extension_expired`
- `profile_locked`
- `subscription_activated`, `subscription_suspended`, `subscription_canceled`, `subscription_plan_changed`
- `entitlement_granted`, `entitlement_revoked`
- `output_job_started`, `output_ready`, `output_failed`
- `artifact_downloaded`
- `birth_date_corrected`

Notification deduplication anahtarı olay türü + hedef + sürüm içermelidir.

---

## 5. Her faz için ortak çalışma kuralları

Her fazda aşağıdakiler zorunludur:

1. Önce repo kökündeki `AGENTS.md`, README, ilgili migration, test ve feature dosyalarını oku.
2. Çalışma ağacındaki kullanıcı değişikliklerini koru; ilgisiz dosyaları düzeltme/formatlama.
3. Tarihsel migration'ları düzenleme. Her şema değişikliği için yeni ileri migration ekle.
4. Yeni public tabloyla aynı migration içinde `REVOKE`, dar `GRANT`, `ENABLE RLS`, policy ve gerekli indexleri tanımla.
5. Migration'ı transaction-safe ve mümkünse tekrar çalıştırmaya karşı güvenli tasarla.
6. Büyük/backfill işlemlerinde önce rapor/dry-run sorgusu, sonra veri migration'ı, sonra constraint doğrulaması uygula.
7. Yalnız UI kontrolü ekleme; backend enforcement olmadan faz tamamlanmış sayılmaz.
8. Başarısız veya geciken job/ödeme/webhook için idempotency ve retry tasarla.
9. Hassas hata mesajlarında kayıt varlığını sızdırma.
10. Yeni davranışı unit, widget/integration ve SQL/RLS testleriyle orantılı doğrula.
11. `flutter analyze`, ilgili Flutter testleri ve Supabase SQL testlerini çalıştır. Çalışmayan ortam varsa “geçti” deme; komut, hata ve doğrulanmayan kısmı raporla.
12. Dokümantasyonu ve `PHASE_STATUS.md` kaydını güncelle.
13. Faz başına tek amaçlı commit tercih et; migration ve ona bağımlı kod aynı checkpoint'te anlaşılır olmalıdır.
14. Commit/push yetkisi yoksa kesin commit mesajını öner ve çalışma ağacı özetini bırak.
15. **Bu faz dışında değişiklik yapma.** Sonraki faz için yalnız açık `TODO`/ADR bırak; erken özellik geliştirme.

### Faz sonu rapor şablonu

Her faz sonunda `docs/implementation/reports/PHASE_<NN>_REPORT.md` oluştur:

```md
# Faz NN Sonuç Raporu
- Durum: COMPLETE | PARTIAL | BLOCKED
- Başlangıç commit'i:
- Bitiş commit'i:
- Değişen dosyalar:
- Eklenen migration'lar:
- Korunan sözleşmeler:
- Kabul kriterleri ve kanıtları:
- Çalıştırılan testler ve sonuçları:
- Çalıştırılamayan testler / neden:
- Güvenlik ve veri migration notları:
- Rollback adımları:
- Bilinen riskler:
- Bir sonraki fazın giriş koşulları:
```

### `PHASE_STATUS.md` şablonu

```md
| Faz | Durum | Commit | Migration | Rapor | Tarih | Not |
|---|---|---|---|---|---|---|
```

Durum yalnız `NOT_STARTED`, `IN_PROGRESS`, `BLOCKED`, `COMPLETE` olabilir. Kabul kriterlerinin tamamı kanıtlanmadan `COMPLETE` yazma.

### Rollback ilkeleri

- Üretimde uygulanmış migration'ı silme veya tarihsel dosyayı değiştirme.
- Veri kaybına yol açan down migration kullanma.
- Riskli açılışları server-side feature flag/kill switch ile kapatılabilir yap.
- Yeni sütunları önce nullable/uyumlu ekle; backfill ve doğrulamadan sonra constraint sıkılaştır.
- Eski istemci sürümleriyle geçiş dönemi uyumluluğunu açıkça test et.
- Rollback, yeni write yolunu kapatma ve eski read yoluna dönme şeklinde ileri migration/flag ile yapılmalıdır.

---

# FAZLAR

## Faz 0 — Baseline, envanter ve yürütme kilidi

### Amaç

Kod değiştirmeden mevcut repo gerçeğini, test tabanını, migration sırasını ve üretim geçiş risklerini kayıt altına al.

### Giriş koşulları

- Repo okunabilir.
- Bu master plan erişilebilir.

### Yapılacaklar

- Mimariyi, paket sürümlerini, Supabase migration sırasını ve tüm feature'ları doğrula.
- Mevcut route, provider, repository, RLS, RPC ve Storage policy envanteri çıkar.
- Tüm `baby_id` kullanan tabloları ve parent-child bileşik foreign key'leri listele.
- Mevcut test sayısı ve başlangıç sonucunu kaydet; önceki rapordaki “54 Flutter test tanımı / 165 SQL assertion” bilgisini yeniden doğrula.
- Çalışma ağacındaki başlangıç değişikliklerini kaydet; kullanıcı değişikliklerine dokunma.
- Şu üretim veri raporlarını salt okunur hazırla:
  - 375 günü geçmiş bebekler,
  - 405 günü geçmiş içerikler,
  - aktif profildeki mevcut book projects/exports,
  - orphan Storage objeleri,
  - aynı ebeveyn kümesini paylaşan bebekler,
  - belirsiz aile-account eşlemeleri,
  - uploading/pending medya kayıtları.
- `docs/implementation/ADR` klasöründe lifecycle tarih semantiğini ve dört yetki eksenini kaydet.
- Feature flag/kill switch yaklaşımını belirle.

### Kabul kriterleri

- Hiçbir ürün davranışı değişmemiştir.
- Baseline test sonuçları dürüstçe kaydedilmiştir.
- Her riskli legacy veri sınıfı için adet ve önerilen işlem vardır.
- Sonraki fazların değiştireceği gerçek dosyalar doğrulanmıştır.

### Bu faz dışında değişiklik yapma

- Migration, RLS, route veya UI davranışı değiştirme.
- Ödeme sağlayıcısı seçme veya entegrasyon yazma.

### Çıkış/checkpoint

- `PHASE_00_REPORT.md`
- `PHASE_STATUS.md`
- Envanter/ADR commit'i: `docs: establish first-year implementation baseline`

---

## Faz 1 — Aynı aile içi çoklu bebek bağlam izolasyonu

### Amaç

Defne içeriğinin Ece bağlamında açılabilmesi riskini lifecycle ve ödeme katmanlarından önce ortadan kaldır.

### Giriş koşulları

- Faz 0 `COMPLETE`.
- Riskli route/repository listesi mevcut.

### Yapılacaklar

- `/memory/:id`, `/letter/:id`, `/milestone/:id` ve medya görüntüleyiciyi açık `babyId` taşıyan route'lara geçir.
- Tüm detay provider ve repository anahtarlarını `(babyId, contentId)` yap.
- Her detay sorgusuna `baby_id` filtresi ekle.
- Model `babyId` ile route `babyId` eşleşmesini doğrula.
- Yaş, ilk-yıl hesabı, author, favori ve permission context'inde `activeBabyProvider` yerine route/model bebeğini kullan.
- Upload queue, local cache ve image cache metadata'sını kullanıcı+bebek namespace'ine al; logout ve hesap/bebek değişimini test et.
- Eski deep link'leri güvenli migration redirect'iyle ele al: content ID'den bebek keşfetmeye çalışıp veri varlığını sızdırma; yetkili lookup sonrası canonical route'a yönlendir veya güvenli hata ver.

### Testler

- Anne hem Defne hem Ece'ye üye; aktif bebek Ece iken Defne linkini aç.
- Doğru bebeğin yaşı, izinleri ve içeriği görünmeli.
- Ece route'unda Defne content ID'si not-found/forbidden olmalı.
- Başka aile IDOR denemeleri varlık sızdırmamalı.
- Route restore/deep link ve tab değişimleri test edilmeli.
- Cache anahtarları arasında iki bebek verisi karışmamalı.

### Kabul kriterleri

- Hiçbir detay sorgusu yalnız `id` ile çalışmıyor.
- Hiçbir detay ekranı güvenlik/yaş hesabında örtük aktif bebeği kullanmıyor.
- Mevcut farklı aile RLS testleri ve yeni aynı aile-iki bebek testleri geçiyor.

### Bu faz dışında değişiklik yapma

- Lifecycle, abonelik, ürün veya kitap erişimi ekleme.

### Rollback/checkpoint

- Eski route'lar yalnız geçici redirect olarak kalabilir; güvenli olmayan sorguya geri dönme.
- Commit: `fix: scope content routes and queries by baby`

---

## Faz 2 — Lifecycle çekirdeği, uzatma ve Super Admin güvenlik modeli

### Amaç

375/405 günlük kuralı veritabanında tek doğruluk kaynağı olarak kur; henüz tüm içerik politikalarını çevirmeden lifecycle API'sini hazırla.

### Giriş koşulları

- Faz 1 `COMPLETE`.
- Europe/Istanbul tarih semantiği ADR ile sabit.

### Yapılacaklar

- Yeni migration ile `platform_user_roles` ve `baby_extension_requests` tablolarını oluştur.
- `is_super_admin()` ve lifecycle fonksiyonlarını ekle.
- Üye tarafından okunabilir `baby_lifecycle_summary` RPC/view oluştur.
- `request_baby_extension(baby_id, days)` RPC'sini transaction, unique constraint ve aktif profil kontrolüyle yaz.
- `decide_baby_extension(request_id, decision, note)` RPC'sini yalnız Super Admin'e aç.
- Pending talepleri base close date'te `expired` yapan idempotent scheduled işlem oluştur.
- Doğrudan client INSERT/UPDATE/DELETE'i kapat; karar alanlarını immutable yap.
- Karar ve expiration activity log/notification oluştur.
- İstemci için `BabyLifecycle` domain modeli ve server summary repository/provider ekle; bu fazda henüz tüm UI mutation'larını değiştirme.

### Tarih testleri

- Doğum tarihi ve `+374` ACTIVE, `+375` LOCKED.
- Onaylı 1, 7, 12, 29, 30 gün.
- 0, negatif, 31 gün reddi.
- 29 Şubat doğumu ve artık yıl.
- İstanbul 23:59:59 / 00:00 sınırı.
- İstemci saatini ileri/geri alma etkisiz.
- 30 gün uzatma ile mutlak kapanış `+405`.
- Standart kapanışa 3 gün kala 30 gün onaylandığında `remaining_days = 33`.

### Yetki/yarış testleri

- Baby admin Super Admin kararı veremez.
- Super Admin olmayan kullanıcı rol tablosuna yazamaz.
- Aynı bebek için eşzamanlı iki talebin yalnız biri başarılı olur.
- Pending/approved/rejected/expired sonrasında ikinci talep reddedilir.
- Karar ikinci kez değiştirilemez.
- Kapanıştaki pending talep expire olur ve profil açılmaz.

### Kabul kriterleri

- Lifecycle sonucu yalnız server tarihinden türetilir.
- 365 günlük hiçbir runtime varsayımı lifecycle kararı olarak kalmamıştır.
- Abonelik/entitlement lifecycle fonksiyonuna dahil değildir.
- Migration, RLS ve RPC testleri geçer.

### Bu faz dışında değişiklik yapma

- Tüm content policy'lerini henüz çevirmeye çalışma.
- Super Admin UI yazma.
- Abonelik/ödeme tabloları ekleme.

### Rollback/checkpoint

- Feature flag lifecycle özetini eski UI'dan gizleyebilir; veri tablolarını silme.
- Commit: `feat: add server-authoritative baby lifecycle and extensions`

---

## Faz 3 — Backend mutation, RLS, RPC ve Storage kilidi

### Amaç

LOCKED bebeğin kaynak arşivini değiştirilmiş istemci, REST, SQL/RPC veya Storage yoluyla değiştirmesini engelle.

### Giriş koşulları

- Faz 2 `COMPLETE` ve lifecycle fonksiyonları test edilmiş.

### Yapılacaklar

- İlgili tabloların INSERT/UPDATE/DELETE policy'lerine lifecycle koşulu ekle.
- Ortak trigger/guard ile RLS dışı/definer yolları da koru.
- `create_time_capsule`, mevcut content RPC'leri ve `register_book_export` gibi yolları açıkça denetle.
- `babies` tablosunda lifecycle etkileyen alanları güvenli RPC'ye taşı; doğum tarihi audit kuralını uygula.
- Storage insert/update/delete policy'lerine lifecycle kontrolü ekle:
  - `baby-media`,
  - avatar/kapak,
  - kapsül medyası,
  - kaynak arşivle ilişkili diğer yollar.
- Upload başlangıcında ve `uploading → ready` geçişinde lifecycle'ı tekrar kontrol et.
- Kilit anında yarım upload'ları güvenli biçimde fail/quarantine et; orphan cleanup kuyruğu oluştur.
- Medya silme akışında önce yetki/lifecycle doğrula; dosya ve DB sırası için tutarlı compensating cleanup kullan.
- Favorites ve family membership tablolarını lifecycle guard'a yanlışlıkla dahil etme.
- KVKK silme service yolunu regresyon testiyle koru.

### Test matrisi

Her kaynak için doğrudan REST/SQL test et:

- LOCKED INSERT/UPDATE/DELETE reddi.
- ACTIVE yetkili başarı.
- ACTIVE yetkisiz ret.
- `baby_id` değiştirme reddi.
- Başka bebeğin parent kaydına bağlanma reddi.
- Storage insert/update/delete reddi.
- Kapanış sınırını geçen upload finalize reddi.
- SECURITY DEFINER bypass denemesi reddi.

İki bebek senaryosu:

- Defne LOCKED, Ece ACTIVE.
- Defne salt okunur; Ece yetki dahilinde yazılabilir.
- Ece mutation'ı Defne listesine/Storage yoluna düşmez.

### Kabul kriterleri

- LOCKED kaynak içerik için tüm backend write yolları kapalıdır.
- UI olmadan curl/REST/RPC/Storage bypass testi başarısızdır.
- Yasal silme ve family membership yönetimi yanlışlıkla kırılmamıştır.

### Bu faz dışında değişiklik yapma

- Flutter ekranlarını kapsamlı yeniden tasarlama.
- Premium entitlement ekleme.

### Rollback/checkpoint

- Acil durumda write policy gevşetmek yerine lifecycle rollout flag'iyle yeni hesaplamayı kontrollü geri al; audit bırak.
- Commit: `security: enforce lifecycle across data and storage mutations`

---

## Faz 4 — Flutter lifecycle deneyimi ve ebeveyn uzatma akışı

### Amaç

Server lifecycle gerçeğini bütün kullanıcı deneyimine yansıt; ACTIVE ve LOCKED profilleri açıkça ayır.

### Giriş koşulları

- Faz 3 `COMPLETE`.
- Backend kilidi istemciden bağımsız çalışıyor.

### Yapılacaklar

- `BabyLifecycle` provider'ını aktif/route bebeğine bağla; cache invalidation ve app resume refresh ekle.
- ACTIVE ana ekranında server kaynaklı kalan gün sayacını göster.
- Onaylı uzatma sayaca dahil olsun; 3+30 örneği 33 gün göstersin.
- LOCKED başlık/ana ekranında “İlk Yılı tamamlandı” ve kilit durumunu göster.
- LOCKED bağlamda büyük `+`, ekle, düzenle ve sil aksiyonlarını kaldır.
- Form route'larına doğrudan deep link gelirse lifecycle guard ile salt okunur/geri yönlendirme uygula.
- Bebek profil formunu LOCKED durumda salt okunur yap.
- Arşiv, takvim, arama ve görüntüleme açık kalsın.
- ACTIVE profilde Book/Film/HTML kart, route, önizleme, satın alma ve indirme girişlerini tamamen gizle/engelle.
- LOCKED profilde premium ürün alanı için yer tutucu/feature flag gösterilebilir; entitlement fazı gelmeden sahte satın alma çalıştırma.
- Ebeveyn uzatma talep ekranı ekle:
  - yalnız hak varsa,
  - 1–30 gün doğrulaması,
  - tek talep uyarısı,
  - pending/approved/rejected/expired durumu,
  - base/effective kapanış tarihi.
- Backend retlerini kullanıcı dostu, güvenli ve idempotent göster.
- Erişilebilirlik, Türkçe tarih/metin ve boş/loading/error durumlarını tamamla.

### Testler

- ACTIVE Ece'de create aksiyonları ve sayaç var, premium yok.
- LOCKED Defne'de create/edit/delete yok, arşiv görüntüleniyor.
- Bebekler arasında hızlı geçişte sayaç ve aksiyon karışmıyor.
- Uygulama açıkken gece sınırı geçildiğinde refresh sonrası LOCKED olur.
- Offline cache eski ACTIVE dese bile mutation backend'de reddedilir; UI güvenli yenilenir.
- Deep link ile form bypass edilemez.
- Uzatma formu ikinci talebi açmaz.

### Kabul kriterleri

- ACTIVE/LOCKED deneyimi görsel ve işlevsel olarak ayrıdır.
- UI hiçbir premium özelliği ACTIVE profilde sunmaz.
- Bütün mutation ekranları backend gerçeğiyle uyumludur.

### Bu faz dışında değişiklik yapma

- Super Admin paneli, ödeme veya gerçek premium üretim yazma.
- Mevcut kitap motorunu yeniden yazma.

### Rollback/checkpoint

- UI flag geri alınsa bile Faz 3 backend güvenliği kalır.
- Commit: `feat: add lifecycle-aware active and locked experiences`

---

## Faz 5 — Super Admin operasyon paneli

### Amaç

Platform yöneticisinin uzatma ve doğum tarihi düzeltme gibi privileged işlemleri güvenli, denetlenebilir biçimde yönetmesini sağla.

### Giriş koşulları

- Faz 4 `COMPLETE`.
- Super Admin rol/RPC testleri hazır.

### Yapılacaklar

- Normal baby `is_admin` ile platform Super Admin'i kesin ayır.
- Ayrı korumalı admin route/shell oluştur; server claim/role her ekranda ve RPC'de doğrulansın.
- Pending uzatma kuyruğu, yaklaşan base close tarihi, requested days ve talep sahibi göster.
- Approve/reject için karar notu, double-submit koruması ve immutable sonuç göster.
- Expired talepler salt okunur görünsün; approve edilemesin.
- Audited doğum tarihi düzeltme ekranı/RPC'si ekle; önce/sonra lifecycle etkisini onaydan önce göster.
- Activity/audit görüntüsü ekle; hassas kişisel veriyi en az göster.
- Admin listelerinde pagination, filtre, rate limit ve güvenli arama uygula.
- Rol atama/kaldırmayı son kullanıcı UI'ına koyma; kontrollü operasyon süreci olarak belgele.

### Testler

- Normal parent admin route'a ve RPC'ye erişemez.
- Sahte client claim yeterli değildir; DB rolü gerekir.
- İki admin aynı talebi karara bağlarsa yalnız biri başarılı olur.
- Audit kaydı kararla atomik oluşur.
- Doğum tarihi düzeltmesi ikinci extension hakkı üretmez.

### Kabul kriterleri

- Tüm privileged aksiyonlar server tarafından korunur ve audit edilir.
- Pending SLA/uyarı kapanıştan önce operasyonu görünür kılar.

### Bu faz dışında değişiklik yapma

- Admin'e içerik düzenleme veya premium lisans bypass yetkisi verme.

### Rollback/checkpoint

- Admin UI flag ile kapatılabilir; role/lifecycle tabloları korunur.
- Commit: `feat: add audited super-admin lifecycle operations`

---

## Faz 6 — Aile hesabı ve aile paketi abonelik altyapısı

### Amaç

Mevcut bebek-bazlı üyeliği bozmadan `family_account` seviyesindeki Small/Normal/Large Family paket aboneliğini, aylık/yıllık billing'i, çoklu bebek kapsamını ve server-side Family Member kapasite kontrolünü kur.

### Giriş koşulları

- Faz 5 `COMPLETE`.
- Ödeme sağlayıcısı/store yöntemi yazılı olarak seçilmiş veya provider adapter arayüzüyle mock modda sınırlandırılmış.
- Legacy family mapping raporu hazır.

### Veri migration stratejisi

- `family_accounts`, üyeler, baby bağlantısı, plan, subscription ve billing event tablolarını ekle.
- Mevcut `family_members` izin modelini bir anda silme; uyumluluk katmanı kullan.
- Aile account backfill'i otomatik olarak yalnız kesin eşleşmelerde yap.
- Aynı kullanıcı birden çok bağımsız ailede bulunabilir; graph connected-component ile kontrolsüz household birleştirme YASAKTIR.
- Kesin olmayan parent kümelerini migration raporuna al ve manuel/operasyonel eşleme gerektir.
- İki parent sınırı ve eşit hakkı transaction/RPC ile koru.
- Family Member kapasitesini (`max_family_members`) davet ve aktivasyonda transaction/RPC ile koru; parent'ları sayma.
- Legacy eşlemede plan kapasitesini aşan aktif Family Member varsa üyeleri, verilerini veya permission'larını silme/değiştirme; migration raporuna al ve 2.5.3 politikasıyla ele al.
- Bebek oluşturma ve ikinci ebeveyn daveti yeni family account modeline atomik bağlansın.

### Abonelik kuralları

- Planlar, kapasiteler ve fiyatlar §2.5.1'deki gibidir: `small_family` (3 member), `normal_family` (6 member), `large_family` (12 member); her planda `max_parent_seats = 2`.
- `billing_period`: `monthly | annual`. Aylık `29900 / 36900 / 46900`, yıllık `322920 / 398520 / 506520` TRY; yıllık = aylık × 12 × 0.90.
- Tek aktif abonelik `family_account`'a aittir; iki parent'ı ve aile hesabındaki tüm bebekleri kapsar. Family Member'ın ayrı aboneliği yoktur.
- Family Member davet/aktivasyonunda kapasite server-side kontrol edilir; kapasite doluysa aktivasyon reddedilir.
- Upgrade (Small → Normal/Large, Normal → Large) doğrulanmış provider olayıyla yeni kapasiteyi açar. Kapasite aşımına yol açan downgrade politikası 2.5.3'e göre ADR ile belgelenir; üye, veri veya permission otomatik silinmez/değiştirilmez.
- Bekleyen davetlerin kapasiteye nasıl yansıtılacağı (rezervasyon veya yalnız aktivasyonda kontrol) ADR ile belirlenir; her durumda aktif Family Member sayısı kapasiteyi aşamaz.
- Provider webhook/receipt doğrulaması server-side ve idempotenttir.
- Client “ödendi” diyerek subscription açamaz.
- Trial, grace, past_due, canceled gibi provider durumları açık iç durumlara map edilir; lifecycle'a bağlanmaz.
- Plan fiyatı ve kapasitesini Flutter, RPC veya Edge Function içine hard-code etme; plan kataloğu / payment provider mapping resmî kaynaktır.

### Flutter

- Anne/Baba iki login ve eşit yönetim davranışını koru.
- Plan ekranında aktif planı (Small/Normal/Large), billing period'u, kapsanan bebekleri ve Family Member kapasite kullanımını göster; fiyatları katalogdan oku.
- Aylık/yıllık seçim ve upgrade akışını ekle; yıllık indirimi katalog değerinden göster.
- Family Member davet/aktiflik durumunu kişi bazında göster; kapasite doluysa upgrade yolunu göster (backend yine reddeder).
- Kapasite aşımına yol açacak downgrade'de durumu açıkça göster; üyeleri otomatik çıkarma.
- Abonelik yokluğunda arşiv erişimi için mevcut ürün kararı neyse uygula; ancak lifecycle veya entitlement silme.
- Restore purchase/receipt ve hesap eşleme akışını seçilen provider kurallarına göre güvenli yap.

### Testler

- İki parent tek `family_account` aboneliğini paylaşır; parent'lar ayrı ücret ödemez ve Family Member kapasitesine sayılmaz.
- Üçüncü parent eklenemez.
- İkinci/üçüncü bebek fiyatı artırmaz; Defne ve Ece aynı `family_account` altında tek Small Family aboneliğiyle kapsanır.
- Small'da 4., Normal'da 7., Large'da 13. aktif Family Member reddedilir.
- Eşzamanlı iki aktivasyon kapasiteyi aşamaz; UI atlanarak doğrudan REST/RPC ile de kapasite aşılamaz.
- Family Member için ayrı abonelik istenmez ve oluşturulamaz.
- Upgrade sonrası yeni kapasite kullanılabilir.
- Kapasiteyi aşan downgrade hiçbir üyeyi, veriyi veya permission'ı silmez/sessizce değiştirmez.
- Katalog yıllık fiyatları `monthly × 12 × 0.90` ile eşleşir: `322920 / 398520 / 506520`.
- Webhook replay çift subscription oluşturmaz.
- Başka family account receipt/IDOR reddedilir.
- Subscription veya plan değişimi lifecycle sonucunu değiştirmez.

### Kabul kriterleri

- Mevcut üyelikler veri kaybı olmadan family account'a map edilmiştir veya açık unresolved listede kalmıştır.
- Anne/Baba hakları eşittir ve tek `family_account` aboneliğiyle çalışır.
- Family Member'lar ayrı abonelik olmadan aile aboneliği kapsamında çalışır; kapasite server-side korunur.
- Small/Normal/Large aylık ve yıllık fiyatları katalogdan gelir ve doğrudur.

### Bu faz dışında değişiklik yapma

- Premium tek seferlik ürün satın alma veya artifact üretimi ekleme.

### Rollback/checkpoint

- Dual-read/feature flag ile eski membership gösterimine geri dönülebilir; yeni billing event'leri silinmez.
- Commit: `feat: add family accounts and subscription plans`

---

## Faz 7 — Premium ürün kataloğu, sipariş ve entitlement

### Amaç

LOCKED bebek için Book/Film/HTML tek seferlik satın alma haklarını güvenli ve birbirinden bağımsız kur.

### Giriş koşulları

- Faz 6 `COMPLETE`.
- Provider doğrulama/adaptor altyapısı çalışır.

### Yapılacaklar

- Products, orders, order events ve entitlements tablolarını ekle.
- `first_year_book = 34900`, `first_year_html = 44900`, `first_year_film = 54900` TRY minor unit fiyatlarını sürümlü katalog kaydı olarak seed et; ödeme sağlayıcısı ürün/SKU eşlemesini bu katalogla bağla.
- Fiyatları Flutter, Edge Function veya RPC içinde hard-code etme; storefront ve purchase intent fiyatı server kataloğundan alsın.
- Purchase intent yalnız LOCKED baby, aktif family membership, parent rolü ve aktif `family_account` aboneliği için oluşturulsun.
- Ödeme sonucu webhook/receipt ile doğrulanmadan entitlement verme.
- Aynı baby+product için idempotency ve active entitlement uniqueness uygula.
- Entitlement aile hesabı+bebek+ürüne bağlansın; purchaser'a bağlanıp diğer parent'ı dışlamasın.
- Refund/chargeback/revocation politikalarını append-only olaylarla uygula.
- ACTIVE profilde endpoint doğrudan reddetsin.
- Flutter'da LOCKED premium storefront ekle; ürünleri ve ayrı fiyatları göster. Dijital Kitap'ın PDF olduğunu ve fiziksel baskıyı içermediğini açıkça belirt.
- Sahip olunan ürün “Satın al” yerine artifact/proje durumuna yönlendirsin.

### Testler

- ACTIVE bebek satın alamaz.
- LOCKED bebekte parent satın alabilir.
- Family Member satın alamaz.
- Book entitlement Film/HTML açmaz.
- Defne entitlement'ı Ece'yi açmaz.
- Anne alımı Baba'da görünür; ikinci ücret oluşmaz.
- Webhook replay çift entitlement üretmez.
- Yanlış fiyat/currency/client sonucu reddedilir.
- Premium katalog yalnız `34900 / 44900 / 54900` TRY döner; emekliye ayrılmış veya taslak premium fiyat değerleri hiçbir seed, test, UI metni ya da provider eşlemesinde bulunmaz.
### Kabul kriterleri

- Üç ürün ayrı, doğru fiyatlı ve baby-scoped entitlement üretir.
- Lifecycle, subscription ve entitlement ayrı kalır.
- Henüz artifact altyapısı yoksa satın alma sonrası açık “hazırlanıyor/altyapı bekliyor” feature flag'i kullan; sahte dosya verme.

### Bu faz dışında değişiklik yapma

- Film/HTML renderer yazma.
- BookComposer'ı değiştirme.
- Fiziksel kitap baskı siparişi, fiyat hesaplama veya fulfillment akışı ekleme.

### Rollback/checkpoint

- Storefront/purchase intent kill switch ile kapanabilir; doğrulanmış order/entitlement kayıtları korunur.
- Commit: `feat: add baby-scoped premium entitlements`

---

## Faz 8 — Immutable archive snapshot, output job ve artifact altyapısı

### Amaç

Book, Film ve HTML'nin ortak güvenli üretim omurgasını oluştur.

### Giriş koşulları

- Faz 7 `COMPLETE`.
- Entitlement kontrolleri güvenilir.

### Yapılacaklar

- `archive_snapshots`, `output_projects`, `output_jobs`, `output_artifacts` tablolarını oluştur.
- Snapshot schema version ve canonical JSON/checksum tanımla.
- Snapshot yalnız LOCKED baby ve uygun entitlement bağlamında oluşturulsun.
- Uzatma dönemindeki geçerli içerikleri dahil et.
- Yazar adı/yakınlık gibi canlı join değerlerini snapshot'a al.
- Sealed snapshot'ı UPDATE/DELETE'e kapat.
- Job queue'da idempotency key, retry/backoff, max attempt, lease/heartbeat ve poison-job durumu uygula.
- Artifact upload sırasını `staging → checksum verify → DB record → ready` şeklinde güvenli yap.
- Orphan cleanup ve quarantine job'ı ekle.
- Artifact Storage path'ini `baby/product/snapshot/version` ile namespace et.
- Download endpoint/policy her istekte membership+lifecycle+subscription+entitlement+permission+artifact durumunu kontrol etsin.
- Signed URL kısa ömürlü olsun; log'da URL/token saklama.
- Gözlemlenebilirlik: job süreleri, failure code, retry ve artifact boyutu metrikleri.

### Testler

- ACTIVE snapshot/job oluşturamaz.
- Entitlement olmayan ürün snapshot/job oluşturamaz.
- Aktif `family_account` aboneliği olmadan parent snapshot/job oluşturamaz.
- Aynı idempotency key çift job üretmez.
- Snapshot mühürlendikten sonra değiştirilemez.
- Artifact kaydı olmayan Storage dosyası okunamaz.
- Checksum uyuşmazlığı `ready` olamaz.
- Defne artifact yolu Ece hakkıyla okunamaz.
- Subscription kapanınca artifact korunur ama download reddedilir.

### Kabul kriterleri

- Üç ürünün ortak üretim güvenlik omurgası hazırdır.
- Artifact yetkisi Storage klasör varsayımına değil gerçek DB kaydına bağlıdır.
- Retry/cleanup/veri bütünlüğü test edilmiştir.

### Bu faz dışında değişiklik yapma

- Ürüne özel renderer ayrıntılarını uygulama.

### Rollback/checkpoint

- Worker tüketimi durdurulabilir; queued job ve snapshot'lar korunur.
- Commit: `feat: add immutable output snapshot and artifact pipeline`

---

## Faz 9 — Kitap premium kapısı ve mevcut PDF motorunun entegrasyonu

### Amaç

Mevcut güçlü kitap deneyimini koruyarak yalnız LOCKED + entitled kullanıcıya resmî dijital PDF üretimi sağla. `first_year_book` dijital üründür; fiziksel baskı bu fazın konusu değildir (bkz. 2.9.1).

### Giriş koşulları

- Faz 8 `COMPLETE`.
- Book entitlement ve artifact pipeline hazır.

### Yapılacaklar

- Mevcut `BookComposer`, `BookRenderResolver`, `BookPdfBuilder` ve editör davranışını koru.
- ACTIVE durumda book project read/create/update, preview, render, export ve download'ı UI+RPC+RLS+Storage'da kapat.
- LOCKED + aktif `family_account` aboneliği + Book entitlement ile output project aç.
- Kaynak arşivi değiştirmeden book item/section configuration düzenle.
- Mevcut chapter planı, sıralama, gizleme, özel sayfa, kapak, metin ve üç formatı koru.
- Resmî PDF'yi snapshot/job/artifact sözleşmesine bağla.
- İstemci render motoru kullanılacaksa worker/secure orchestration'a taşınabilir veya doğrulanmış artifact upload protokolü kurulabilir; yalnız local dosyayı lisanslı artifact sayma.
- `register_book_export` lifecycle, entitlement, snapshot ve checksum doğrulaması olmadan çalışmasın.
- Her export gerçek artifact satırı ve doğru Storage path ile bağlı olsun.
- Legacy ACTIVE book projects/exports:
  - kullanıcıya gizle,
  - silme,
  - `legacy_quarantined` olarak raporla,
  - LOCKED + entitlement sonrası snapshot'tan yeni resmî artifact üret,
  - otomatik entitlement verme.

### Regresyon testleri

- Chapter dağılımı ve “Bir Yaşındayım”.
- Bölüm/öğe sırası ve hide/show.
- Özel sayfa, cover, başlık/not/açıklama.
- A4, 21×21, 30×30.
- Preview ve baskıya hazır PDF kalitesi.
- TrimBox/BleedBox ve Türkçe fontlar.
- PDF versioning, download/share ve cihazdan yazdırma (fiziksel baskı siparişi değildir).
- ACTIVE tüm book yolları reddi.
- LOCKED fakat entitlement yoksa ret.
- Artifact olmayan PDF Storage read reddi.

### Kabul kriterleri

- Mevcut kitap yeteneklerinde regresyon yoktur.
- Kitap yalnız LOCKED ve satın alınmış bebekte kullanılabilir.
- Resmî PDF sürümlü, checksum'lı ve re-download edilebilir artifact'tır.

### Bu faz dışında değişiklik yapma

- Film veya HTML UI/renderer yazma.
- Kitap motorunu estetik gerekçeyle yeniden tasarlama.
- Fiziksel baskı siparişi, matbaa, kargo veya fulfillment entegrasyonu ekleme.

### Rollback/checkpoint

- Book worker/storefront flag ile kapanabilir; mevcut source/project verisi korunur.
- Commit: `feat: gate and integrate official book artifacts`

---

## Faz 10 — En fazla 10 dakikalık Film ürünü

### Amaç

Immutable snapshot'tan güvenilir, indirilebilir ve en fazla 10 dakika süren resmî Film artifact'ı üret.

### Giriş koşulları

- Faz 9 `COMPLETE`.
- Film entitlement ve genel job pipeline hazır.
- Transcoding/render altyapısı ve kaynak limitleri ADR ile seçilmiş.

### Yapılacaklar

- Film output project ve scene manifest şemasını tanımla.
- Fotoğraf/video/metin/tarih/ilk/mektup/special-day kaynaklarını snapshot referansıyla seç.
- Timeline duration budget algoritması oluştur; UI ve server aynı sınırı gösterse de son karar server'dır.
- Süre bütçesi içerik miktarından türetilir; 600 saniye hedef değil üst sınırdır. İçerik azsa film yapay şekilde uzatılmaz.
- Çıktı süresini **600 saniyeyi aşmayacak** şekilde preflight ve post-render doğrula.
- Final MP4 server-side output job'u ile üretilir; Flutter cihazında final film render edilmez.
- Video thumbnail, codec probe, transcoding, orientation, audio normalize ve bozuk medya hata kodları ekle.
- Müzik/seslendirme kullanılıyorsa lisans, kullanıcı onayı ve audio ducking politikasını belgeleyip uygula.
- Retry aynı snapshot/project version için deterministik olmalı.
- MP4 artifact metadata, süre, çözünürlük, codec, byte size ve sha256 sakla.
- İlerleme, başarısızlık, tekrar deneme ve indirme UI'ı ekle.
- Family Member bu fazda üretim/edit UI'ına erişemez.

### Testler

- 600 saniye kabul, 600 saniye üstü reddedilir/truncate edilmez; kullanıcıdan düzenleme istenir.
- Az içerikli arşivde film süresi içerikle orantılıdır; 600 saniyeye dolgu yapılmaz.
- Bozuk/unsupported video güvenli hata verir.
- Dikey/yatay medya tutarlı çıktı verir.
- Retry çift artifact sürümü üretmez veya açık versioning uygular.
- ACTIVE/entitlement yok/member render denemeleri reddedilir.
- Final checksum ve duration probe doğrulanır.

### Kabul kriterleri

- Film en fazla 10 dakikadır ve offline indirilebilir MP4 artifact'tır.
- Üretim server-authoritative job ile izlenir.
- Kaynak snapshot sürümü artifact'ta bellidir.

### Bu faz dışında değişiklik yapma

- HTML renderer veya kardeş film birleştirme geliştirme.

### Rollback/checkpoint

- Film worker queue ve storefront kill switch ile kapatılabilir.
- Commit: `feat: add ten-minute first-year film artifacts`

---

## Faz 11 — İndirilebilir offline HTML ürünü

### Amaç

İnternet bağlantısı ve süresi dolan URL olmadan açılan taşınabilir arşiv paketi üret.

### Giriş koşulları

- Faz 10 `COMPLETE`.
- HTML entitlement ve snapshot/job/artifact pipeline hazır.
- Desteklenen tarayıcı/işletim sistemi matrisi ADR ile belirlenmiş.

### Yapılacaklar

- Offline bundle manifest şemasını oluştur.
- Bundle'ı yalnız LOCKED profilin mühürlü snapshot'ından üret; artifact immutable'dır, paket içinde içerik ekleme/düzenleme/silme arayüzü veya sunucuya yazma yolu bulunmaz.
- HTML, CSS, JS, font ve medya asset'lerini bundle içine kopyala; göreli yol kullan.
- Signed URL, CDN, analytics veya harici ağ zorunluluğunu kaldır.
- Dosya adlarını sanitize et; path traversal, executable içerik ve tehlikeli MIME'ları engelle.
- Kullanıcı metnini escape/sanitize et; stored XSS'nin offline pakete taşınmasını önle.
- Gerekirse video/audio codec uyumluluğunu bundle aşamasında dönüştür.
- Service worker kullanılıyorsa `file://` kısıtlarına güvenme; paket açılış senaryosunu gerçek ortamda test et.
- ZIP içinde entry manifest, sha256, toplam boyut ve sürüm dosyası üret.
- Açılış yönergesi ve platforma uygun launcher olmayan güvenli kullanım belgesi ekle.
- Uzak origin'e istek atılmadığını otomatik ağ testiyle doğrula.

### Testler

- Ağ tamamen kapalıyken paket açılır; metin, görsel ve desteklenen videolar çalışır.
- Signed URL expiration paketi etkilemez.
- Türkçe karakter, uzun dosya adı ve Unicode içerik çalışır.
- XSS/path traversal testleri geçer.
- ZIP checksum ve entry listesi manifestle eşleşir.
- Paket içinden yeni içerik eklenemez, mevcut içerik değiştirilemez/silinemez; aynı artifact'ın re-download'ı aynı sha256'yı verir.
- ACTIVE/entitlement yok/member create denemesi reddedilir.

### Kabul kriterleri

- Paket gerçekten offline çalışır.
- Artifact re-download edilebilir ZIP'tir.
- Harici ağ ve expiring URL bağımlılığı yoktur.

### Bu faz dışında değişiklik yapma

- Kardeş HTML birleştirme veya hosted website ürünü geliştirme.

### Rollback/checkpoint

- HTML worker/storefront ayrı kill switch ile kapanabilir.
- Commit: `feat: add downloadable offline html archive`

---

## Faz 12 — Family Member final indirme izinleri ve re-download sertleştirmesi

### Amaç

Ebeveyn kontrollü final artifact paylaşımını ve tüm ürünlerde tutarlı yeniden indirmeyi tamamla.

### Giriş koşulları

- Faz 9–11 `COMPLETE`.
- `family_account` aboneliği, Family Member kapasite kontrolü (Faz 6) ve üç product entitlement çalışıyor.

### Yapılacaklar

- `artifact_download_permissions` tablosu/RPC'sini ürün bazında etkinleştir.
- Yalnız aktif parent grant/revoke yapabilsin.
- Family Member UI'da yalnız izinli ve hazır final artifact'ı görsün.
- Purchase, edit, selection, render, regenerate route'larını Family Member için hem UI hem backend'de kapat.
- Her download isteğinde altı koşullu kontrolü yeniden yap.
- Kısa ömürlü signed URL'yi kullanıcıya ve mümkünse tek isteğe bağla; rate limit ve audit ekle.
- Anne/Baba re-download akışını üç üründe aynı davranışa getir.
- Subscription pasif/aktif geçişinde artifact korunması ve erişimin geri gelmesini test et.
- Üyelik kaldırma, izin revoke, entitlement revoke ve chargeback sonrası mevcut URL süresi/erişim politikasını belgeleyip uygula.

### Testler

- Aktif `family_account` aboneliği + kapasite içinde aktif Family Member + izin + artifact → indirme başarılı; Family Member'dan ayrı abonelik istenmez.
- Bu koşullardan herhangi biri yok → güvenli ret.
- Book izni Film/HTML açmaz.
- İzin revoke sonrası yeni URL alınamaz.
- Member render/edit/purchase endpoint'lerine erişemez.
- Aile aboneliği yenilenince aynı artifact yeniden indirilebilir; yeni satın alma gerekmez.
- İki bebek ve iki family account arasında URL/IDOR reddedilir.

### Kabul kriterleri

- Family Member yalnız ebeveyn izinli final çıktıyı indirebilir.
- Re-download kuralları Book/Film/HTML için aynıdır.
- Download audit ve rate limit çalışır.

### Bu faz dışında değişiklik yapma

- Kaynak arşiv paylaşım haklarını veya birleşik aile ürününü genişletme.

### Rollback/checkpoint

- Member download özelliği flag ile kapatılabilir; parent download etkilenmez.
- Commit: `feat: add parent-controlled family artifact downloads`

---

## Faz 13 — Legacy migration, güvenlik sertleştirme ve üretim açılışı

### Amaç

Mevcut veriyi kaybetmeden yeni modeli üretime kontrollü aç; gözlemlenebilirlik, performans ve geri dönüş planını tamamla.

### Giriş koşulları

- Faz 0–12 `COMPLETE`.
- Staging, production benzeri veri hacmi ve ödeme sandbox testleri hazır.

### Legacy veri politikası

- 375 günü geçmiş bebekler rollout anında raporlanır ve yeni lifecycle'a göre LOCKED olur.
- 405 gün sonrasına ait legacy içerik **silinmez**.
- Bu içerik read-only legacy arşiv olarak korunur; resmî “İlk Yıl” snapshot'ına varsayılan olarak dahil edilmez.
- Super Admin'in açık gerekçeli, audited grandfather kararı olmadan cutoff dışı legacy içerik resmî çıktıya girmez.
- ACTIVE dönemde oluşturulmuş eski book project/export silinmez; karantinaya alınır ve entitlement sayılmaz.
- Orphan Storage objeleri raporlanır; doğrulanmadan silinmez.
- Belirsiz family account eşlemeleri otomatik birleştirilmez.

### Yapılacaklar

- Backfill'leri batch, gözlemlenebilir ve yeniden başlatılabilir çalıştır.
- Önce shadow/read-only hesaplama, sonra internal cohort, sonra küçük kullanıcı cohort'u, sonra kademeli rollout yap.
- Lifecycle mismatch, mutation reject, job failure, payment webhook lag, artifact checksum ve download denial metrikleri kur.
- Alert ve runbook oluştur.
- RLS/Storage/IDOR için bağımsız saldırı testi yap.
- Dependency, secret, log redaction ve service-role kullanımını denetle.
- Index ve query planlarını gerçek veri hacminde ölç.
- Upload/job/storage maliyet ve quota limitlerini uygula.
- Privacy export/delete, retention, backup restore ve disaster recovery tatbikatı yap.
- Eski istemci sürümlerinin yeni policy karşısındaki davranışını test et; zorunlu minimum sürüm gerekiyorsa güvenli upgrade ekranı ekle.
- README, ERD, runbook, API sözleşmeleri ve kullanıcı destek metinlerini güncelle.

### Tam kabul test paketi

- Lifecycle sınırları ve timezone.
- Uzatma tekliği/yarış/Super Admin.
- İki bebek aynı aile ve farklı aile IDOR.
- Tüm content/RPC/Storage mutation bypass testleri.
- Tek `family_account` aboneliği (Small/Normal/Large, aylık/yıllık); Family Member kapasitesi, upgrade/downgrade ve ayrı member aboneliği olmaması.
- Üç ayrı entitlement ve doğru fiyat.
- Snapshot/job/artifact idempotency ve checksum.
- Book regresyon paketi.
- Film ≤600 saniye.
- HTML tam offline.
- Family Member izinli indirme.
- Re-download, cancel/reactivate, refund/chargeback.
- KVKK silme ve sealed time capsule regresyonu.
- Notification deduplication.

### Go-live kapıları

- Kritik/yüksek güvenlik bulgusu yok.
- Veri backfill mutabakatı %100 veya açıkça onaylanmış istisna listesi.
- Ödeme webhook/receipt idempotency kanıtlı.
- Rollback/kill switch tatbikatı başarılı.
- Backup ve restore denemesi başarılı.
- Support/admin runbook hazır.
- Kullanıcı onayı olmadan fiyat veya lifecycle semantiği değişmemiş.

### Kabul kriterleri

- Üretim rollout'u metriklerle kontrollü tamamlanmıştır.
- Legacy veri kaybı yoktur.
- Tüm faz raporları ve commit checkpoint'leri izlenebilir durumdadır.

### Bu faz dışında değişiklik yapma

- Kardeş çıktı birleştirme, yeni premium paket, fiyat deneyi veya fiziksel baskı sipariş akışı ekleme.

### Checkpoint

- Release tag önerisi: `first-year-lifecycle-v1`
- Commit: `release: complete first-year lifecycle and premium outputs`

---

## 6. Global test matrisi

### 6.1 Lifecycle

- `birth_date` ACTIVE.
- `birth_date + 374` ACTIVE.
- `birth_date + 375` LOCKED.
- 1/7/12/29/30 gün uzatma.
- 0/31/negatif ret.
- 29 Şubat ve artık yıl.
- İstanbul gece sınırı.
- İstemci saat manipülasyonu etkisiz.
- Pending kapanışta expired; yeniden açılma yok.

### 6.2 İki bebekli aile

Anne/Baba hem Defne hem Ece'ye erişir:

- Defne LOCKED, Ece ACTIVE.
- Defne SELECT açık; mutation kapalı.
- Ece yetkili mutation açık.
- Defne route'u Ece yaş/permission/cache bağlamını kullanmaz.
- Ece premium kapalı; Defne premium diğer şartlara bağlı açık.
- Entitlement, snapshot, artifact ve download URL'leri bebekler arasında geçmez.

### 6.3 Üyelik ve ödeme

- İki parent eşit hak; abonelik `family_account`'a ait tek pakettir (Small/Normal/Large).
- Aylık `29900 / 36900 / 46900`, yıllık `322920 / 398520 / 506520` TRY; yıllık = aylık × 12 × 0.90.
- Çoklu bebek ek ücret üretmez.
- Family Member ayrı abonelik gerektirmez; kapasite Small 3 / Normal 6 / Large 12 (parent'lar hariç) server-side korunur.
- Upgrade kapasiteyi açar; downgrade üye, veri veya permission silmez.
- Provider replay/idempotency.
- Subscription lifecycle'ı değiştirmez.
- Entitlement purchaser yerine baby+family product kapsamındadır.

### 6.4 Premium

- Dijital Kitap (PDF) 349 TL, Offline HTML 449 TL, Film (MP4) 549 TL; katalog `34900 / 44900 / 54900` TRY.
- Fiyat server kataloğundan gelir; istemcide hard-code fiyat yok.
- Fiziksel kitap 349 TL'ye dahil değil ve katalogda sabit fiyatlı ürün değil.
- Film içerik azsa 10 dakikaya uzatılmaz; HTML artifact immutable'dır.
- Her ürün ayrı entitlement.
- ACTIVE satın alma/preview/generate/download yok.
- LOCKED + entitlement + uygun subscription ile doğru akış.
- Artifact kaydı olmayan Storage objesi okunamaz.
- Re-download yeni satın alma üretmez.

### 6.5 Güvenlik

- RLS doğrudan REST/SQL bypass.
- RPC/SECURITY DEFINER bypass.
- Storage path tahmini/IDOR.
- Route contentId swap.
- Cross-family ve same-family cross-baby.
- Webhook forgery/replay.
- Signed URL reuse/expiry/rate limit.
- Offline HTML XSS/path traversal.
- Admin privilege escalation.

---

## 7. Model devralma/handoff komutu

Kullanıcı yeni bir modele aşağıdaki kısa komutu verebilir:

```text
Repo içindeki Bebeğimin İlk Yılı Master Implementation Planı'nın tamamını ve PHASE_STATUS.md dosyasını oku. Önceki tamamlanmış fazların sözleşmelerini bozma. Faz <N>'in giriş koşullarını doğrula ve yalnız Faz <N>'i uygula. Bu faz dışında değişiklik yapma. Faz sonunda ilgili testleri çalıştır, PHASE_<NN>_REPORT.md raporunu ve checkpoint/commit özetini oluştur; kabul kriterleri tamamlanmadıysa fazı COMPLETE işaretleme.
```

Model, “önceki model yaptı” ifadesini kanıt saymamalı; commit, migration, test ve raporla doğrulamalıdır.

---

## 8. Son değişmez kontrol listesi

Bir faz veya release tamamlandı denmeden önce şu soruların tümü “evet” olmalıdır:

- [ ] Lifecycle 375 gün, uzatma tek seferlik 1–30 gün, mutlak tavan 405 gün mü?
- [ ] Europe/Istanbul server tarihi kullanılıyor mu?
- [ ] ACTIVE iken Book/Film/HTML tüm katmanlarda kapalı mı?
- [ ] LOCKED iken kaynak mutation tüm katmanlarda kapalı mı?
- [ ] Uzatma dönemindeki geçerli içerik çıktılara dahil mi?
- [ ] Her route/sorgu/cache `(babyId, contentId)` bağlamına sadık mı?
- [ ] Anne+Baba iki login/eşit hak ve abonelik tek `family_account` paketi (Small/Normal/Large) mi?
- [ ] Plan fiyatları aylık/yıllık katalogdan geliyor ve yıllık = aylık × 12 × 0.90 mı?
- [ ] Çoklu bebek aile aboneliği fiyatını artırmıyor mu?
- [ ] Family Member kapasitesi (3/6/12, parent'lar hariç) server-side korunuyor ve Family Member'dan ayrı abonelik istenmiyor mu?
- [ ] Family Member yalnız aktif aile aboneliği, kapasite ve ürün bazlı parent izniyle final artifact indirebiliyor mu?
- [ ] Dijital Kitap/HTML/Film 349/449/549 TL (`34900/44900/54900` TRY), fiyatlar server kataloğundan ve ayrı entitlement mı?
- [ ] Fiziksel kitap dijital PDF entitlement'ından ayrı ve sabit fiyatsız mı?
- [ ] Lifecycle, membership, subscription ve entitlement ayrı mı?
- [ ] Re-download entitlement'ı silmeden subscription/permission ile korunuyor mu?
- [ ] `BookComposer` ve mevcut PDF yetenekleri korunmuş mu?
- [ ] Film süresi server doğrulamasıyla en fazla 10 dakika mı?
- [ ] HTML paketi gerçekten offline ve expiring URL'siz mi?
- [ ] RLS + trigger/RPC + Storage guard birlikte mi?
- [ ] Super Admin, baby admin'den ayrı ve audited mi?
- [ ] Legacy veri silinmeden raporlanıp karantinaya alınmış mı?
- [ ] Migration/rollback/checkpoint/faz raporu hazır mı?
- [ ] Kardeş çıktı birleştirme açıkça kapsam dışında mı?

Bu kontrol listesindeki tek bir kritik madde eksikse sistem veya ilgili faz tamamlanmış sayılmaz.
