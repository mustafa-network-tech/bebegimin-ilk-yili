# ADR 0005 — Offline HTML arşivi: paket mimarisi ve tarayıcı matrisi

- Durum: Kabul edildi (Faz 11)
- Tarih: 2026-10-01

## Bağlam

Master plan §2.11 ve Faz 11:

- `first_year_html`, LOCKED arşivin mühürlü snapshot'ından üretilen, **internetsiz** açılan, değiştirilemez bir ZIP paketidir.
- Pakette signed URL, CDN, analytics veya harici ağ bağımlılığı olamaz. İçerik ekleme / düzenleme arayüzü veya sunucuya yazma yolu bulunmaz.
- Paket; HTML / CSS / JS / font / medyayı göreli yollarla içerir. ZIP içinde entry manifest, SHA-256, toplam boyut ve sürüm dosyası bulunur.

## Kararlar

### 1. Üretim yeri: ortak çıktı worker'ı

- Paket, Faz 10'da kurulan Deno + ffmpeg worker'ında üretilir. Worker `workers/film` → `workers/output` olarak genelleştirildi; `WORKER_PRODUCTS` ile hangi ürünleri alacağı seçilir (varsayılan: film + HTML).
- Kaynak, işin bağlı olduğu mühürlü snapshot'tır (`output_snapshot_payload`, checksum doğrulamalı). Uygulamanın bir ayar seçimi yoktur; arşiv snapshot'ın tamamıdır. Mühürlü zaman kapsülleri ve kişisel favoriler zaten snapshot'ta yoktur.

### 2. Statik, önceden üretilmiş sayfalar

- `file://` altında `fetch` / XHR tarayıcılarda engellidir ve service worker çalışmaz. Bu yüzden veriler JSON'dan okunmaz: her sayfa sunucuda tam HTML olarak üretilir.
- JavaScript yalnız isteğe bağlı iyileştirmedir (görsel büyütme, klavye gezinmesi). JS kapalıyken veya önizleme uygulamalarında da metin, görsel ve video bağlantıları çalışır.
- Sayfalar: `index.html` (kapak, doğum bilgileri, içindekiler), bölüm sayfaları (Seni beklerken, Doğduğun gün, 1.–12. Ay, Bir yaşında ve sonrası), `ilkler.html`, `mektuplar.html`, `aile.html`.
- Her sayfada sıkı CSP meta etiketi vardır. Uzak kaynak, form gönderimi ve gömülü çerçeve yasaktır; yalnız paketteki dosyalar yüklenir.

### 3. Güvenlik

- Tüm kullanıcı metni HTML-escape edilir. Kullanıcı metni hiçbir zaman script, stil veya URL bağlamına girmez; bağlantıya çevrilmez.
- Dosya adları kullanıcıdan gelmez: medya `media/<uuid>.jpg|-k.jpg|-p.jpg|.mp4`, sayfalar sabit adlıdır. ZIP yazıcısı her yolu izin listesi kalıbıyla doğrular (`..` yok, mutlak yol yok, yalnız küçük ASCII). Uzantı izin listesi: `html, css, js, ttf, jpg, mp4, json, txt`. Çalıştırılabilir dosya veya launcher yoktur.
- Fotoğraflar ve videolar yeniden kodlanır; EXIF / GPS dahil tüm metaveri silinir.

### 4. Medya

- Fotoğraf: uzun kenar en çok 2048 px JPEG + 480 px küçük resim.
- Video: H.264 High / AAC, uzun kenar en çok 1280 px, `+faststart`, poster karesi. Tarayıcılarda yaygın oynatılan tek profil budur.
- Dönüştürülemeyen veya bulunamayan medya paketi bozmaz. Yerinde "bu medya pakete eklenemedi" notu gösterilir ve `manifest.json` içinde `skipped` olarak listelenir. Sayı yayın kaydına yazılır.

### 5. ZIP

- Kendi deterministik ZIP yazıcımız kullanılır: sıkıştırmasız (STORE), CRC-32'li, sabit tarih (1980-01-01), sıralı girişler, tek kök klasör.
- `manifest.json`: sürüm, ürün, bebek, snapshot kimliği / checksum'ı, her dosyanın yolu, boyutu, MIME'ı ve SHA-256'sı, toplam boyut, atlanan medya. `surum.txt` ve `benioku.txt` (açılış yönergesi) bulunur.
- Worker, yüklemeden önce yazdığı ZIP'i yeniden okuyup giriş listesini ve her girişin SHA-256'sını manifest'le karşılaştırır.
- Üst sınır output bucket limitidir (2 GB). Aşan arşiv `bundle_too_large` ile tekrar denenmeden biter.

### 6. Tarayıcı / işletim sistemi matrisi

| Ortam | Destek | Açılış |
|---|---|---|
| Windows 10/11, macOS 13+, Linux — Chrome, Edge, Firefox (güncel ve bir önceki ana sürüm) | **Tam** | ZIP'i klasöre çıkar, `index.html`'i çift tıkla |
| macOS 13+ Safari 16+ | **Tam** | Aynı |
| iPadOS / iOS 16+ | En iyi çaba | Dosyalar uygulamasında ZIP'e dokunup çıkar, `index.html`'i aç (önizleme; metin, görsel ve video çalışır) |
| Android 10+ | En iyi çaba | Dosyalar uygulamasıyla çıkar, `file://` destekleyen bir tarayıcıda aç (ör. Firefox) |

Otomatik doğrulama headless Chromium ile yapılır (CI: Ubuntu üzerinde Google Chrome; yerelde Chrome / Edge). Ağ çevrimdışı moda alınır, tüm istekler kaydedilir ve `file:` dışındaki her istek test hatasıdır. Mobil ortamlar manuel kontrol listesindedir.

## Sonuçlar

- HTML paketi için ek altyapı gerekmez; film worker'ı aynı konteynerde arşivleri de üretir.
- Kill switch: `html_renderer` (yeni istek), `output_worker` (tüm tüketim), `premium_storefront` (satış).
