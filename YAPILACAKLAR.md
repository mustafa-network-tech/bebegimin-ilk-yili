# Yapılacaklar

**Durum tarihi:** 2026-10-02.

**Dal:** `claude/amazing-wright-j0u0mm`. Son commit `dd171f8`; push edildi.

## Mevcut durum

- 2026-10-02 inceleme düzeltmelerinin tamamı 14 ayrı commit olarak işlendi.
- Kapsam: inceleme raporundaki Y-1…Y-11, O-1…O-5, O-7, O-8 ve D-1, D-3…D-6 bulguları. Rapor (`CLAUDE-REPORT.MD`) 2026-10-03'te silindi; gerekirse git geçmişinden okunabilir (son hâli `dd171f8`).
- CI'da (`37005070382`) şu job'lar başarılı geçti:
  - Flutter analyze + testler,
  - SQL/RLS testleri,
  - Edge Functions,
  - Output worker (ffmpeg + headless Chrome entegrasyon testleri dahil),
  - Android APK.
- iOS job'ı atlandı.
- Aşağıdakiler henüz yapılmadı.

Ayrıntılar ve gerekçeler: ürün kararları [GELISTIRME.MD](GELISTIRME.MD) "Karar kaydı" bölümünde (P-1…P-13), operasyon adımları [docs/operations/release-runbook.md](docs/operations/release-runbook.md) içinde.

---

## 1. Önce: yeni değişiklikleri ortamlara taşımak

Bu adımlar yapılmadan 2026-10-02 düzeltmeleri hiçbir Supabase projesinde etkin değildir. Değişiklikler yalnız repoda ve CI'da doğrulandı.

- [ ] **Migration'ları staging'e uygula.** Uygulanacak 9 yeni ileri migration:
  - `20261002000100_parent_only_extension_requests.sql`
  - `20261002000200_parent_authority.sql`
  - `20261002000300_output_cutoff.sql`
  - `20261002000400_subscription_read_only.sql`
  - `20261002000500_media_date_guard.sql`
  - `20261002000600_parent_only_downloads.sql`
  - `20261002000700_output_person_names.sql`
  - `20261002000800_release_health_demo_accounts.sql`
  - `20261002000900_small_hardening.sql`

  ```bash
  supabase link --project-ref <staging-ref>
  supabase db push
  ```
- [ ] **Uygulamadan sonra staging'de raporları kontrol et:**
  - `admin_parent_authority_report()`: yöneticiliği alınan ebeveyn dışı kişiler ve ebeveyn yöneticisi olmayan bebekler. Bu bebekler destek ekibiyle tek tek çözülmeli.
  - `admin_media_date_report()`: tarih aralığı dışındaki eski medya. Eski kayıtlar değiştirilmez, yalnız raporlanır.
  - `admin_release_health()`: `demo_accounts` değeri `ok` olmalı.
- [ ] **Değişen Edge Function'ları deploy et:**
  ```bash
  supabase functions deploy privacy-actions
  supabase functions deploy book-artifact-finalize
  supabase functions deploy output-download
  ```
- [ ] **Output worker imajını yeniden derleyip staging'de çalıştır** (bkz. §2). Değişiklik: HTML'de kişi adı artık "İsim + yakınlık" biçiminde.
- [ ] **Mobil uygulamanın yeni sürümünü staging'e bağlı derle.** Yeni rotalar (`/babies/:babyId/...`), salt okunur abonelik ve ebeveyn kuralları ancak bu sürümle görünür.
- [ ] **Staging'de elle kontrol et:**
  - [ ] Aile üyesi uzatma talep edemiyor; ekranda "Anne veya Baba talep eder" yazıyor.
  - [ ] Aile üyesi Kitap, Film ve HTML ekranlarını görmüyor ve indiremiyor.
  - [ ] Bir ebeveyn diğerini çıkaramıyor ve yöneticiliğini alamıyor.
  - [ ] Bebeği yalnız Anne veya Baba silebiliyor.
  - [ ] Tek ebeveyn, önce bebekleri silmeden hesabını silemiyor; ekran engelleyen bebekleri listeliyor.
  - [ ] Abonelik bitince arşiv okunabiliyor. Yazma, yükleme ve premium işlemleri kapalı; ekranda salt okunur bandı görünüyor.
  - [ ] Uzatma alan bebekte Kitap, Film ve HTML uzatma dönemindeki içeriği içeriyor, sonrasını içermiyor.
  - [ ] Çıktılarda isimler "Esra Teyzesi" biçiminde.
- [ ] **Staging'de sorun çıkmazsa aynı adımları production'da tekrarla.** Production'a hiçbir zaman `supabase/seed.sql` uygulanmaz.

## 2. Docker imajını doğrulamak

Worker imajı şu an hiçbir yerde derlenmedi. Bu doğrulama runbook'taki go-live kapısıdır. İki yol var:

- [ ] **A) CI'a ekle (önerilen).** `.github/workflows/ci.yml` dosyasına imajı derleyen bir job ekle:
  ```bash
  docker build -f workers/output/Dockerfile -t bebegimin-output-worker .
  docker run --rm bebegimin-output-worker ffmpeg -version
  ```
  GitHub'ın Linux makinelerinde Docker hazır geliyor. Bu iş ayrı bir commit olarak yapılmalı.
- [ ] **B) Yerelde dene.** Önce Docker Desktop'ı kur (`winget install Docker.DockerDesktop`; WSL2 ve yeniden başlatma isteyebilir). Sonra depo kökünde aynı iki komutu çalıştır.
- Başarı ölçütü: `deno cache --frozen` adımı hatasız geçiyor. Bu, `deno.lock` ile Deno 2.9.7'nin uyumlu olduğunu gösterir.

İsteğe bağlı: worker entegrasyon testlerini yerelde de çalıştırmak için (Chrome kurulu, ffmpeg eksik):

```powershell
winget install Gyan.FFmpeg
cd workers\output
$env:FFMPEG_PATH="ffmpeg"; $env:FFPROBE_PATH="ffprobe"
$env:CHROME_PATH="C:\Program Files\Google\Chrome\Application\chrome.exe"
deno task test
```

Bu değişkenler tanımlı değilse entegrasyon testleri çalışmadan atlanır.

## 3. Go-live kapıları (Faz 13; inceleme bulguları Y-7 ve O-9)

Bunlar kapanmadan production'da bayrak açılmaz ve gerçek ödeme alınmaz. Ayrıntılar runbook'ta.

- [ ] Staging, production'a yakın veri hacmiyle hazır. Staging rollout ve cohort planı uygulanmış.
- [ ] Gerçek veri mutabakatı %100 ya da onaylı bir istisna listesi var.
- [ ] Mağaza ürün kimlikleri gerçek değerlerle değiştirildi; şu an placeholder (`20260929000400_store_billing_access_gate.sql`).
- [ ] App Store ve Google Play sandbox testleri:
  - [ ] Abonelik ve üç premium ürünün satın alınması.
  - [ ] Restore akışı. Premium ürünler "consumable"; Apple restore UX'i ayrıca test edilmeli.
  - [ ] Webhook: aynı olay iki kez gelince tek etki oluşuyor (idempotency).
- [ ] Gerçek cihaz testleri:
  - [ ] Soğuk açılışta (cold start) deep link.
  - [ ] Film oynatma.
  - [ ] HTML ZIP'in iOS ve Android'de internetsiz açılması.
- [ ] Kill switch tatbikatı (runbook §5).
- [ ] Yedek / geri yükleme tatbikatı; PITR açık (runbook §6).
- [ ] Bağımsız güvenlik testi (pentest) raporu.
- [ ] OSV / bağımlılık taraması.
- [ ] En az iki Super Admin hesabı var.
- [ ] Mağaza sürümleri `DEMO_MODE` kapalı derleniyor.
- [ ] iOS derlemesi doğrulandı (CI'da `skipped`).

## 4. Hukuk ve doküman

- [ ] **Hukuk teyidi:**
  - P-12 gerekçesi aydınlatma metnine yazılmalı: çıktıları yalnız ebeveynler indirir ve üçüncü kişilere dağıtım uygulama tarafından yapılmaz.
  - Silinen bebekte sipariş kayıtlarının saklama süresi belirlenmeli.
- [ ] **O-6:** Kitap PDF'inin içeriği sunucuda doğrulanmıyor. Bu kabul edilmiş bir tasarım riski; ADR'ye yazılmalı.
- [ ] **Bütün kanıtlar kaydedildikten sonra:** `PHASE_STATUS.md` içinde Faz 13'ü `COMPLETE` yap ve `first-year-lifecycle-v1` etiketini oluştur.

## 5. İsteğe bağlı iyileştirmeler

Bunlar zorunlu değil.

- [ ] Liste ekranlarını `/babies/:babyId/...` rotalarına taşı: zaman tüneli, albüm, takvim, arama, ilkler, mektuplar, kapsüller. Şu an seçili bebeği gösteriyorlar; detay ve yazma rotaları zaten bebek kimliği taşıyor.
- [ ] Kota yarışı için test ekle (D-2). Pratikte risk düşük. Teorik pencere: bebek aile hesabı değiştirirse kota `baby_id` ile, kilit `family_account_id` ile hesaplanıyor.
- [ ] Ürün kararı: kilit gününde ebeveynlere giden iki bildirim (`profile_locked` + `book_ready`) tek bildirimde birleştirilsin mi? (D-4)
- [ ] Ürün kararı: hesap silmeden önce yeniden kimlik doğrulama istensin mi? (D-5)
- [ ] Önceden var olan `deno lint` (`no-import-prefix`) ve `deno fmt` farklarını temizle; ardından CI'a lint ve format kontrolü ekle.

## 6. Kapalı test aşamasında yapılacak eklemeler

Google Play içerik derecelendirme anketinde "kullanıcı içeriği bildirme özelliği" sorusu **Hayır** olarak cevaplandı. Bu iki ekleme, üretime geçmeden önce kapalı test sürerken yapılacak.

- [ ] **Destek e-posta adresi:** gizlilik politikasındaki `iletisim@mk-digitalsystems.com` kullanılacak. Politikanın 9. maddesi içerik bildirimleri için bu adresi ve "İçerik bildirimi" konusunu gösteriyor (3 Ekim 2026).
- [ ] **Ayarlar'a "Destek / İletişim" satırı ekle.** Satır, destek e-postasına yazmayı açmalı. Bazı hata mesajları kullanıcıyı desteğe yönlendiriyor ama uygulamada destek iletişimi yok (ör. [film_models.dart:211](lib/features/film/domain/film_models.dart#L211), [baby_form_screen.dart:212](lib/features/babies/presentation/baby_form_screen.dart#L212)).
- [ ] **İçerik ve üye menülerine "Bildir" seçeneği ekle.** Fotoğraf/video, anı, yorum, mektup ve aile üyesi menülerinde bulunmalı. Destek e-postasına içerik türü, içerik kimliği ve bebek kimliği hazır yazılmış bir mesaj açması yeterli. Google'ın kullanıcı içeriği (UGC) politikası uygulama içinde bildirme yolu bekliyor.
- [ ] **Bunlar eklendikten sonra** Play Console'daki içerik derecelendirme anketini güncelle: "Uygulama, kullanıcıları veya kullanıcı tarafından oluşturulan içerikleri bildirme özelliği içeriyor mu?" → **Evet**.
- [ ] **Bilgi: Videolardaki konum bilgisi silinmiyor olabilir.** Fotoğraflar yüklenmeden önce içlerindeki konum bilgisi (EXIF/GPS) cihazda siliniyor ([image_processing.dart:41](lib/features/media/data/image_processing.dart#L41)). Videolar için böyle bir kod görülmedi. Telefonla çekilen videolarda çekim yeri kayıtlı olabilir ve bu bilgi aile üyelerine giden dosyada kalır.
  - Play Console içerik derecelendirmesindeki "kullanıcının geçerli konumunu paylaşıyor mu?" sorusu bundan etkilenmiyor (**Hayır**). Uygulama cihazın konumunu almıyor, konum izni de istemiyor.
  - **Veri güvenliği** formunda konum verisi sorulduğunda bu durum dikkate alınmalı.
  - Karar verilmeli: videolardaki konum bilgisi yüklemeden önce temizlensin mi? Kodda doğrulandı: videolar hiç işlenmeden, çekildiği gibi yükleniyor.
  - Gizlilik politikası (§1) ve KVKK aydınlatma metni (§2) bu durumu anlatacak şekilde güncellendi (3 Ekim 2026). Videolardaki konum bilgisi temizlenmeye başlanırsa bu iki metin de yeniden düzeltilmeli.
  - Ayarlar'daki "Yüklenen fotoğrafların EXIF (konum dahil) bilgileri cihazda temizlenir" yazısı ([settings_screens.dart:501](lib/features/settings/presentation/settings_screens.dart#L501)) yalnızca fotoğrafları kapsıyor. Videolar temizlenmezse bu yazı yanlış anlaşılabilir.


Android paket kimliği:  com.mkdigitalsystems.bebegimin_ilk_yili     bu olacak paket ısmı

⚠️ Supabase e-postasıyla ilgili bir uyarı: Bildiğim kadarıyla, Supabase'in hazır e-posta sistemi yalnızca deneme için tasarlanmış. Saatte birkaç e-postayla sınırlı ve yalnızca projenin ekip üyelerine e-posta gönderiyor. Bu doğruysa, uygulama yayınlandığında gerçek kullanıcılara doğrulama e-postaları gitmeyebilir. Yayından önce Supabase panelinde Authentication → SMTP Settings bölümünü kontrol edin. Burada özel bir gönderim servisi (ör. Resend, Brevo) tanımlarsanız, o servisi de politikaya eklemem gerekir.

gızlılık url    https://mustafaoner.net/kvkk-veri-isleme-gizlilik-politikalari/bebegimin-ilk-yili