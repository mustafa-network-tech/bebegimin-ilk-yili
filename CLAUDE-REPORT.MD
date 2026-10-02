# Claude Salt Okunur Teknik İnceleme Raporu

**Proje:** Bebeğimin İlk Yılı (Flutter + Supabase)
**İnceleme tarihi:** 2026-10-01
**Branch / HEAD:** `claude/amazing-wright-j0u0mm` / `be4c1c1` (`feat(phase-13): legacy policy, release health, erasure fix and hardening`)
**Ana sözleşme:** [GELISTIRME.MD](GELISTIRME.MD) (1.556 satır, tamamı okundu)
**İnceleme türü:** Salt okunur statik inceleme (2026-10-01). İnceleme sırasında hiçbir kod, migration, test veya mevcut doküman değiştirilmedi.
**Uygulama (2026-10-02):** Kullanıcının açık onayı ve P-1…P-13 kararlarıyla bulgular düzeltildi; her adım ayrı bir commit'tir (bkz. bulgulardaki "Durum" notları ve §9).
**Güncelleme (2026-10-02):** Kullanıcının P-1…P-13 ürün kararları işlendi (bkz. §8). Etkilenen bulgular (Y-2, Y-3, Y-6, Y-8, O-2) ve düzeltme sırası (§9) buna göre güncellendi. Kararlar sonrası üç yeni bulgu eklendi:
- Y-8: hesap silmede ebeveyn olmayan üyeye otomatik yöneticilik; tek ebeveynin hesap silmesi;
- Y-9: bir ebeveyn diğerini çıkarabiliyor; ebeveyn daveti ebeveyn onayına bağlı değil;
- Y-10: çıktılarda kişi isim biçimi;
- Y-11: aile üyesi indirme yolu ve medya paylaşım düğmesi (P-12).

---

## 0. Yönetici özeti

Repo, master planın 0–13. fazlarının neredeyse tamamını **gerçek kod** olarak içeriyor: 19 migration (~11.000 satır SQL), 138 Dart kaynak dosyası, 7 Edge Function, ayrı bir Deno + ffmpeg output worker'ı ve geniş bir test paketi (~1.011 SQL assertion çağrısı, 155 Flutter testi, 15 Edge testi, 17 worker testi — faz raporlarındaki sayılarla tutarlı). Lifecycle (375 + en fazla 30 gün, Europe/Istanbul), RLS/Storage kilidi, dört yetki ekseni, aile paketi aboneliği, bebek bazlı premium entitlement, mühürlü snapshot → job → artifact hattı ve Family Member indirme izinleri sözleşmeye büyük ölçüde sadık uygulanmış.

**Karar: ÜRETİM İÇİN NO-GO.** `PHASE_STATUS.md` içinde Faz 13'ün `IN_PROGRESS` olması doğru. Ortam gerektiren go-live kapılarının yanında, bu incelemede **önceki Codex raporunda olmayan** üç yüksek önemli sözleşme ihlali bulundu:

1. **Kitap, ilk doğum gününden sonraki içeriği hiç alamıyor** (10 günlük final dönemi + onaylı uzatma). Plan §2.1/11–12 ve §8 kontrol listesi bunu açıkça zorunlu kılıyor. Film ve HTML bu içeriği alıyor; yalnız Kitap almıyor.
2. **Ebeveyn olmayan bir "yönetici" (ör. teyze) bebeği tamamen silebiliyor.** Satın alınmış Kitap/Film/HTML çıktıları da silinir. `delete_baby_for_user` yalnız `is_admin` kontrol ediyor; UI ise ebeveyn olmayana da yönetici bayrağı verebiliyor.
3. **Ömürde tek olan uzatma hakkını herhangi bir aile üyesi tüketebiliyor.** Örneğin hiç yetkisi olmayan bir teyze 1 günlük talep açarsa ebeveynler bir daha talep açamaz.

Codex raporunun bulgularının çoğu doğrulandı. Ancak iki bulgu yeniden değerlendirildi: **snapshot cutoff** bir uygulama hatasından çok planın kendi içindeki çelişkisi, **kota yarışı** ise pratikte büyük ölçüde mevcut değil (ayrıntılar §5'te).

**2026-10-02 kararları sonrası:**
- **Snapshot cutoff:** Resmî çıktı efektif kapanışa kadardır (375 gün + varsa onaylı uzatma, en fazla 405). Mevcut "her bebek için +405" kesimi artık **kesin bir sözleşme ihlali**.
- **Abonelik bitince erişim:** Arşiv salt okunur kalmalı. Mevcut kod okumayı da tamamen kapattığı için **değişmesi gereken davranış**.
- **Bebek silme:** Yetki iki ebeveynin her birine ait. Ebeveyn olmayan yöneticinin silebilmesi (Y-2) kesin olarak hata.

---

## 1. GELISTIRME.MD analizi

### 1.1 Belgenin yapısı

| Bölüm | İçerik | Değerlendirme |
|---|---|---|
| §0 | Kullanım, normatif kelimeler, kaynak önceliği | Güçlü. "Önceki model yaptı" ifadesi kanıt sayılmıyor. |
| §1 | Mevcut sistem bulguları, korunacaklar, zorunlu düzeltmeler | Gerçek kodla uyumlu (doğrulandı). |
| §2 | Değiştirilemez ürün kuralları: lifecycle, ACTIVE/LOCKED, çoklu bebek, aile/abonelik, premium, re-download, çıktı, Kitap/Film/HTML, kapsam dışı | Çok net. Fiyatlar kuruş cinsinden tek kaynakta. |
| §3 | Dört yetki ekseni, karar matrisi, server gerçeği, route/cache anahtarları, mutation matrisi, doğum tarihi, KVKK | Güçlü, ama silme yetkisini tanımlamıyor (bkz. 1.2). |
| §4 | Hedef veri modeli | Uygulamada isimler küçük farklarla korunmuş (ör. `premium_orders`). |
| §5 | Ortak faz kuralları, rapor ve rollback şablonları | Uygulanmış; yalnız Faz 0 raporu eksik. |
| Faz 0–13 | Her faz için amaç, giriş/çıkış, test, kabul kriterleri | Ayrıntılı ve test edilebilir. |
| §6–8 | Global test matrisi, handoff komutu, son kontrol listesi | §8 kontrol listesi bu raporda madde madde değerlendirildi (§7). |

### 1.2 Belgenin kendi zayıf noktaları ve çelişkileri

Bunlar kod hatası değil, ürün sahibinin karar vermesi gereken plan açıklarıdır. **P-1…P-5 ve ek kararlar P-6…P-12 2026-10-02'de karara bağlandı (bkz. §8). Açık ürün kararı kalmadı; yalnız hukuk onayı ve GELISTIRME.MD karar kaydı bekliyor.**

- **P-1 — Legacy cutoff çelişkisi.** §2.1/12'ye göre yalnız onaylı uzatma dönemindeki içerik çıktılara girer. Bu, efektif kapanıştan sonraki içeriğin girmemesi demek. Faz 13 "Legacy veri politikası" ise yalnız "**405 gün sonrasına** ait legacy içerik"i dışarıda bırakıyor. Uygulama Faz 13 metnini birebir izlemiş (`birth_date + 405`). Uzatma almamış eski bir bebeğin 376–405. gün içeriği bu yüzden resmî çıktıya giriyor. İki madde uzlaştırılmalı.
- **P-2 — Abonelik bitince arşiv erişimi.** §2.3 LOCKED arşivin görüntülenmesini açık sayıyor. §2.7 abonelik pasifken yalnız indirmenin kapanacağını söylüyor. 2026-09-29 ürün kararıyla ise abonelik pasifken **tüm arşiv** (okuma dahil) sunucuda kapatılıyor ([20260929000400_store_billing_access_gate.sql:1-13](supabase/migrations/20260929000400_store_billing_access_gate.sql#L1-L13)). Kaynak önceliği #2 gereği bu karar meşru. Ama GELISTIRME.MD'ye işlenmemiş, dolayısıyla belge ile sistem birbirini tutmuyor.
- **P-3 — Bebek silme yetkisi tanımsız.** Plan iki ebeveyni eşit sayıyor ve Family Member'ın satın alma/düzenleme yapamayacağını söylüyor. Ancak KVKK kapsamında bebeği kimin silebileceğini, diğer ebeveynin onayı gerekip gerekmediğini ve satın alınmış çıktıların akıbetini tanımlamıyor.
- **P-4 — Veri dışa aktarım kapsamı tanımsız.** Faz 13 yalnız "privacy export/delete ... tatbikatı" diyor. Neyin, kime, hangi formatta verileceği belirtilmemiş.
- **P-5 — "Parent" ile "baby admin" ayrımı.** Plan `family_account_members.role = parent` modelini getiriyor. Eski `family_members.is_admin` bayrağı ise ebeveyn olmayanlara da verilebiliyor. Hangi işlemin hangi kavrama bağlı olduğu planda netleştirilmemiş. Y-2 ve Y-3 bulgularının kökü bu boşluk.

---

## 2. İnceleme kapsamı ve yöntemi

- GELISTIRME.MD'nin tamamı, `PHASE_STATUS.md`, `codex-report.MD`, Faz 13 raporu, runbook, ADR'ler okundu.
- Okunan migration'lar: Faz 2 lifecycle (tamamı), Faz 3 kilit çekirdeği, Faz 13 (tamamı). Faz 6/7/8/9/10/11/12 migration'ları hedefli olarak incelendi.
- Flutter: router, kitap domain/data/presentation, form ekranları, repository sorguları, paywall, aile üyesi ekranları.
- Edge Functions: `book-artifact-finalize`, `output-download`, `privacy-actions`, `_shared/cors.ts`.
- Worker: Dockerfile, `deno.json`, HTML üreticisi (CSP/escape).
- CI (`.github/workflows/ci.yml`), `.gitignore`, `env/`, `seed.sql`.
- Testler statik olarak sayıldı. Hiçbir test çalıştırılmadı; "geçti" beyanları faz raporlarına aittir.

### 2.1 Repo durumu

- Tracked çalışma ağacı temiz. Untracked dosyalar: `x` (37 KB migration çıktı logu, artık dosya) ve `codex-report.MD`.
- Release etiketi yok (`first-year-lifecycle-v1` atılmamış; doğru).
- `docs/implementation/reports/PHASE_00_REPORT.md` **yok**.
- `env/dev.json` gitignore'da (doğru). İçinde barındırılan bir Supabase projesi + `DEMO_MODE: true` var (bkz. O-4).

---

## 3. Faz bazında uyum tablosu

| Faz | PHASE_STATUS | Claude değerlendirmesi | Ana not |
|---|---|---|---|
| 0 | COMPLETE | **Eksik** | Zorunlu `PHASE_00_REPORT.md` yok; "kullanıcı beyanı" kanıt olarak alınmış (§0 kuralına aykırı). |
| 1 | COMPLETE | Kısmen | İçerik detay rotaları `(babyId, contentId)`'ye geçmiş, repository'ler `baby_id` filtreli. Kitap/Film/Arşiv rotaları, oluşturma formları ve üye ekranı aktif bebeğe bağlı (Y-4). |
| 2 | COMPLETE | Büyük ölçüde | 375/405, İstanbul tarihi, tekil talep, expire job doğru. Talebi **herhangi bir üye** açabiliyor (Y-3). |
| 3 | COMPLETE | Uyumlu | Tetikleyici + RLS + Storage kilidi güçlü; doğum tarihi RPC'ye taşınmış. `media.taken_on` guard'sız (O-1). |
| 4 | COMPLETE | Uyumlu | ACTIVE/LOCKED deneyimi, `LifecycleWriteGuard`, uzatma ekranı mevcut. |
| 5 | COMPLETE | Uyumlu | Super Admin ayrı, audited, rate-limited. |
| 6 | COMPLETE | Uyumlu (karar notuyla) | Planlar/fiyatlar doğru. Abonelik kapısı tüm arşivi kapatıyor (P-2). Mağaza ürün ID'leri placeholder. |
| 7 | COMPLETE | Uyumlu | 34900/44900/54900 TRY doğru; istemcide hard-code fiyat yok. |
| 8 | COMPLETE | Uyumlu | Snapshot/job/artifact, lease, checksum, 60 sn indirme. |
| 9 | COMPLETE | **İhlal var** | Kitap uzatma/final dönem içeriğini alamıyor (Y-1); finalize kurtarma açığı (Y-5). |
| 10 | COMPLETE | Uyumlu | 600 sn üst sınır, dolgu yok, uzatma içeriği 14. bölümde. |
| 11 | COMPLETE | Uyumlu | CSP, `esc()`, göreli yollar, deterministik ZIP. |
| 12 | COMPLETE | **Karar sonrası ters yönde** | Teknik olarak sağlam: altı koşullu indirme, denetim, hız sınırı. Ancak P-12'ye göre aile üyeleri hiç indiremez; Faz 12'nin aile üyesi indirme özelliği kaldırılmalı (Y-11). |
| 13 | IN_PROGRESS | Doğru durum | Ortam kapıları açık; export yok; erasure yetkisi sorunlu. |

---

## 4. Bulgular

Önem dereceleri: **YÜKSEK** (sözleşme ihlali veya geri alınamaz kayıp riski), **ORTA**, **DÜŞÜK**. "Yeni" etiketi bu bulgunun Codex raporunda olmadığını gösterir.

### Y-1 — Kitap, ilk doğum gününden sonraki içeriği alamıyor  `YÜKSEK · Yeni · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02): O-2 ile birlikte düzeltildi; ayrı commit olarak işlendi.**
> - **Sunucu:** [20261002000300_output_cutoff.sql](supabase/migrations/20261002000300_output_cutoff.sql)
>   - `build_archive_snapshot_content` içeriği bebeğin kendi efektif kapanışından önceki tarihlerle sınırlıyor: `tarih < doğum + 375 + onaylı uzatma`. Grandfather kararı hepsini dahil etmeye devam ediyor.
>   - `admin_legacy_rollout_report` kapanış tarihi ve sonrasındaki içeriği sayıyor.
>   - Mühürlü eski snapshot'lar değişmiyor.
> - **Kitap (istemci):**
>   - `FirstYearPeriod`'a `standardClose` (doğum + 375) ve `isClosingWindow` eklendi. `isBookCandidate` artık kapanış tarihine kadar olan içeriği kabul ediyor.
>   - `BookSource.closeDate` kapanış tarihini taşıyor: editörde sunucu lifecycle özetinden, resmî baskıda mühürlü snapshot'ın `effective_close_date` alanından.
>   - Final dönem ve uzatma içeriği "Bir Yaşındayım" bölümüne giriyor; manuel ekleme adayları ve mektuplar da aynı sınırı kullanıyor.
>   - Anı/zaman tüneli rozetleri artık standart 375 günü kapsıyor; uzatmalı bebekte uzatma günleri rozetsiz kalabilir, kitap planı ise uzatmayı içerir.
> - **Testler:**
>   - [99q_output_cutoff_test.sql](supabase/tests/99q_output_cutoff_test.sql): uzatmasız, 7 gün ve 30 gün; 374, 375, 381, 404 ve 405. günler.
>   - [99r](supabase/tests/99r_release_hardening_test.sql) karara göre güncellendi.
>   - Composer, `first_year` ve snapshot testlerine 4 yeni Flutter testi eklendi.
> - **Doğrulama:** SQL **1073 doğrulama geçti**, `flutter test` **170/170**, `flutter analyze` ve `dart format` temiz.
> - **Not:** PDF'teki "365 gün" istatistiği ilk yılı anlatan bir başlık olarak bırakıldı.

**Sözleşme:** §2.1/11: 365. gün ve onu izleyen 10 günlük final dönemi 375 günün içindedir. §2.1/12: onaylı ek sürede eklenen içerik Kitap, Film ve HTML'ye dahildir. §8: "Uzatma dönemindeki geçerli içerik çıktılara dahil mi?"

**Kod:**
- [first_year.dart:52](lib/core/utils/first_year.dart#L52): `isBookCandidate` yalnız hamilelik, 365 gün ve ilk doğum gününü kapsıyor.
- [book_composer.dart:103-113](lib/features/book/domain/book_composer.dart#L103-L113): `slotForDate` doğum gününden sonraki tarih için `null` dönüyor, yani içerik kitaba girmiyor. Mektuplar da `firstBirthday` ile sınırlı.
- [book_page_editor_screen.dart:68-96](lib/features/book/presentation/book_page_editor_screen.dart#L68-L96): manuel ekleme adayları da aynı filtreden geçiyor. Yalnız mektuplar istisna.
- Karşılaştırma: Film tarafında [film_chapter](supabase/migrations/20261001000200_film_artifacts.sql#L42-L55) bu içeriği 14. bölüme ("Bir yaşında", uzatma penceresi) alıyor. HTML snapshot'ın tamamını kullanıyor.

**Etki:** 366–375. gün ve onaylı uzatma (en fazla 405. gün) içindeki anı, fotoğraf, video ve ilkler, ücretli Dijital Kitap'a **hiçbir yolla** girmiyor. Kullanıcı uzatma için başvurup içerik ekliyor, ama 349 TL'lik kitapta bu içeriği göremiyor. Ek olarak PDF'te sabit "365 gün" istatistiği basılıyor ([book_pdf_builder.dart:664](lib/features/book/pdf/book_pdf_builder.dart#L664)).

**Öneri:** Kitap aday penceresini snapshot'taki `lifecycle.effective_close_date`'e bağlamak (yarı açık aralık) ve "Bir Yaşındayım" bölümünü 366 → efektif kapanış aralığını kapsayacak şekilde genişletmek. Final dönem ve uzatma içeriği için composer ve widget regresyon testleri eklemek. Bu değişiklik BookComposer'ın yeniden yazılması değildir; yalnız tarih penceresi düzeltmesidir.

### Y-2 — Ebeveyn olmayan "yönetici" bebeği ve satın alınmış çıktıları silebiliyor  `YÜKSEK · Yeni · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02): Y-2, Y-8 ve Y-9 birlikte düzeltildi; ayrı commit olarak işlendi.**
> - **Migration:** [20261002000200_parent_authority.sql](supabase/migrations/20261002000200_parent_authority.sql)
>   - `family_members_parent_guard` tetikleyicisi: P-5, P-8, P-9.
>   - `family_invitations_parent_guard` tetikleyicisi: ebeveyn olmayan yönetici daveti yasak; anne/baba davetini yalnız ebeveyn oluşturur.
>   - `add_member_from_sibling`: ebeveyn kontrolü eklendi.
>   - `delete_baby_for_user`: yalnız ebeveyn.
>   - `prepare_account_deletion`: tek ebeveyn ve tek üye durumunda `delete_babies_first` reddi; bebekler örtük silinmez; halef yalnız diğer anne/baba olur ve aile hesabına ebeveyn olarak işlenir.
>   - `account_deletion_blockers()`: ayarlar ekranı için.
>   - `admin_parent_authority_report()`: Super Admin raporu.
>   - `revoke_non_parent_admins()`: idempotent temizlik.
>   - Eski verideki ebeveyn olmayan yöneticiler audit kaydıyla normal üyeye indirilir, izinleri değişmez. Ebeveyn yöneticisi olmayan bebeklerde yönetici korunur ve raporlanır.
> - **SQL testi:** [14_parent_authority_test.sql](supabase/tests/14_parent_authority_test.sql), 37 doğrulama.
>   - Mevcut iki test, kararlarla bilinçli olarak değişen davranışa göre güncellendi: [60_account_notifications_test.sql](supabase/tests/60_account_notifications_test.sql) (P-10 ve P-3 mesajı).
>   - İki eski veri fixture'ı yeni guard'ı yalnız ekleme süresince devre dışı bırakıyor: [90_family_accounts_subscriptions_test.sql](supabase/tests/90_family_accounts_subscriptions_test.sql) ve 13.
> - **Edge:** [privacy-actions](supabase/functions/privacy-actions/index.ts) `delete_babies_first` için 409 ve Türkçe mesaj döndürüyor; bebek silme reddinde de yeni mesaj var.
> - **Flutter:**
>   - Bebek oluşturmada yalnız Anne/Baba seçilebilir; "Sil" yalnız ebeveyne görünür.
>   - Üye ekranında diğer ebeveyn salt okunurdur, anne/baba ilişkisini yalnız ebeveyn atar, yönetici anahtarı yalnız anne/baba ilişkisinde görünür.
>   - Davet ve kardeşten eklemede anne/baba seçeneği yalnız ebeveyne gösterilir; anne/baba daveti otomatik olarak eşit yöneticidir.
>   - Hesap silme ekranı engelleyen bebekleri listeler ve düğmeyi kapatır.
>   - Yeni hata metinleri eklendi. [parent_authority_test.dart](test/family/parent_authority_test.dart) 6 test içeriyor.
> - **Doğrulama (yerel, geçici PostgreSQL 16.10 ve Deno 2.9.7 ile):**
>   - `run_db_tests.sh`: **1068 doğrulama, tamamı geçti** (Y-3 testleri dahil).
>   - `flutter analyze` temiz, `flutter test` **166/166**, `dart format` temiz.
>   - Edge: `deno check` (4 fonksiyon) temiz, `deno test` **15/15**, `deno lint` ve `deno fmt --check` temiz.
> - **Doküman:** [client-rpc-contracts.md](docs/api/client-rpc-contracts.md), [support-texts.md](docs/support/support-texts.md), [README.md](README.md).

**Kod:**
- [20260926000600_views_rpc.sql:107](supabase/migrations/20260926000600_views_rpc.sql#L107): `delete_baby_for_user` yalnız `family_members.is_admin` koşulunu kontrol ediyor. `relation in ('anne','baba')` veya `family_account` parent rolü aranmıyor.
- [member_screens.dart:160-165](lib/features/family/presentation/member_screens.dart#L160-L165): bir yönetici, akrabalık ilişkisinden bağımsız olarak herhangi bir üyeye yönetici anahtarını açabiliyor. Davet ekranında da `_admin` alanı var.
- Faz 13 [babies_erase_outputs](supabase/migrations/20261001000500_release_hardening.sql#L539-L576) bebek silindiğinde tüm snapshot, artifact ve indirme kayıtlarını siliyor. Entitlement'lar `baby_id = NULL` olarak kalıyor.
- Testler yalnız yönetici olmayan teyzenin reddedildiğini doğruluyor ([60_account_notifications_test.sql:78](supabase/tests/60_account_notifications_test.sql#L78)). "Yönetici yapılmış teyze" senaryosu test edilmiyor.

**Etki:** Bir babaanne veya teyze yönetici yapılırsa ebeveynlerin haberi olmadan bebeği, tüm anıları ve **para ödenmiş** Kitap/Film/HTML çıktılarını geri dönüşsüz silebilir. Bu, plandaki "iki ebeveyn eşit yönetici" ve "Family Member satın alma/düzenleme yapamaz" ilkelerinin ruhuna aykırı ve geri alınamaz.

**Öneri (P-3 kararına göre):** Bebek silmeyi yalnız aktif ebeveynlere (anne/baba + admin, `family_account` parent rolü) açmak. İki ebeveynin **her biri tek başına** silebilir; ikinci ebeveyn onayı aranmaz. Ebeveyn olmayan yöneticinin silme denemesi reddedilmeli; "yönetici yapılmış teyze silemez" ve "baba tek başına silebilir" SQL testleri eklenmeli. Öneri: silme öncesinde diğer ebeveyne bildirim ve aktivite kaydı oluşturulmalı (karar gerektirmeyen şeffaflık önlemi).

**P-5 kararı (yönetici yalnız anne ve baba, eşit hak):** Bu karar Y-2'nin kökünü kaldırıyor; ebeveyn olmayan yönetici artık hiç var olmamalı. Gerekli değişiklikler:
- **Veritabanı kuralı:** `family_members` üzerinde `is_admin → relation in ('anne','baba')` kuralı. Yeni ileri migration ile; önce mevcut ebeveyn olmayan yöneticiler dry-run ile raporlanmalı, sonra audit kaydıyla normal üyeye indirilmeli, sonra kural etkinleştirilmeli.
- **Yönetici atanan yollar:** Davet (`family_invitations.is_admin`), davet kabulü, `add_from_sibling` (`p_is_admin`) ve üye düzenleme yolları ebeveyn olmayana yönetici veremeyecek şekilde sınırlanmalı.
- **Uygulama arayüzü:** [member_screens.dart:160-165](lib/features/family/presentation/member_screens.dart#L160-L165) ve davet ekranındaki yönetici anahtarı yalnız anne/baba ilişkisi için gösterilmeli.
- **Eşitlik:** Yönetici yetkileri iki ebeveyn arasında birebir eşit olmalı; "hesabı ilk açan" veya "davet eden" farkı oluşmamalı (§2.5/2). Hiçbir ebeveyn diğerini aileden çıkaramaz veya yöneticiliğini alamaz (P-9, bkz. Y-9).

### Y-3 — Tek seferlik uzatma hakkını herhangi bir üye tüketebiliyor  `YÜKSEK · Yeni · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Çalışma ağacında düzeltildi, henüz commit edilmedi.
> - **Migration:** [20261002000100_parent_only_extension_requests.sql](supabase/migrations/20261002000100_parent_only_extension_requests.sql). İç kullanımlı `is_baby_parent()` eklendi; `request_baby_extension` ebeveyn olmayanı INSERT'ten önce `not_parent` ile reddediyor; `baby_lifecycle_summary.can_request_extension` artık ebeveyne bağlı.
> - **SQL testi:** [13_parent_only_extension_test.sql](supabase/tests/13_parent_only_extension_test.sql). Kapsadığı durumlar: ebeveyn olmayan üye, eski veride ebeveyn olmayan yönetici, üye olmayan kişi, hakkın tüketilmemesi, anne ve baba başarısı, ikinci talep reddi, yardımcının istemciye kapalı olması. **Doğrulandı:** Geçici yerel PostgreSQL 16.10 ile `run_db_tests.sh` tam paketi geçti.
> - **Flutter:** [lifecycle_screen.dart](lib/features/babies/presentation/lifecycle_screen.dart) ebeveyn kontrolü kapanış mesajından önce yapılıyor. 2 yeni widget testi eklendi. `flutter analyze` temiz, `flutter test` 160/160 geçti, `dart format` temiz.
> - **Doküman:** [client-rpc-contracts.md](docs/api/client-rpc-contracts.md) güncellendi.

**Kod:** [20260927000100_lifecycle_extensions.sql:347](supabase/migrations/20260927000100_lifecycle_extensions.sql#L347): `request_baby_extension` yalnız `is_baby_member` kontrol ediyor. `baby_lifecycle_summary.can_request_extension` de rol bakmıyor ([L282-285](supabase/migrations/20260927000100_lifecycle_extensions.sql#L282-L285)). Sonraki migration'larda fonksiyon yeniden tanımlanmamış.

**Sözleşme:** Faz 4 "**Ebeveyn** uzatma talep ekranı" diyor. §2.2'de talep "yetkiler dahilinde" yapılabilir. `UNIQUE (baby_id)` nedeniyle hak ömürde birdir; reddedilen veya süresi dolan talep de yeni hak açmaz.

**Etki:** Hiçbir izni olmayan bir Family Member 1 günlük talep açtığında ebeveynlerin 30 günlük talep hakkı kalıcı olarak kaybolur. Geri alma yolu yok.

**Karar (P-6, 2026-10-02): Uzatma talebini yalnız ebeveynler açabilir.**

**Gerekli düzeltme:** RPC'yi aktif parent (anne/baba + admin) ile sınırlandırmak; `can_request_extension`'ı arayan kullanıcının rolüne göre hesaplamak (Family Member için her zaman `false`); uzatma ekranında talep formunu yalnız ebeveyne göstermek. Yeni SQL testleri: "Family Member talep açamaz", "yönetici yapılmış akraba talep açamaz", "anne veya baba açabilir, ikincisi açamaz". Yetkisiz denemede hak tüketilmemeli; reddetme INSERT'ten önce yapılmalı.

### Y-4 — Premium rotaları ve bazı mutation'lar açık `babyId` taşımıyor  `YÜKSEK · Codex CXR-03 doğrulandı ve genişletildi · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi.
> - **Rotalar:**
>   - Kitap: `/babies/:babyId/book`, `…/book/editor`, `…/book/view`, `…/book/pages/:pageId`.
>   - Arşiv: `/babies/:babyId/archive`. Film: `/babies/:babyId/film`, `…/film/view`.
>   - Üye: `/babies/:babyId/members/:memberId`.
>   - Kapılar ve ekranlar `babyByIdProvider(routeBabyId)` kullanıyor. Erişilemeyen veya bilinmeyen bebek için tarafsız bir "Sayfa bulunamadı" görünümü (`RouteBabyMissing`) var.
>   - Eski `/book`, `/film`, `/archive`, `/family/member/:id` adresleri (saklı bildirimler, eski sürümler) seçili bebeğin yeni adresine yönleniyor.
>   - Bildirim ve mağaza bağlantıları yeni adresleri kullanıyor.
> - **Formlar:** `/memory/new`, `/milestone/new`, `/letter/new`, `/capsule/new` rotaları `PinnedActiveBaby` ile bebeği açılış anında sabitliyor. Form ve yazma koruması aynı bebeğe bağlı; seçim değişse de form hedefini değiştirmiyor. Kapsül formuna `babyId` eklendi.
> - **Depolar:** Kitap (`_reload`, `applySync`, `updateProject`, `deletePage`, `deleteItem`) ve aile üyesi (`updateMember`, `removeMember`) işlemleri `baby_id` + `id` ile sınırlı.
> - **Testler:** Kitap/Film/Arşiv/üye testleri yeni parametrelere göre güncellendi. Yeni testler: bilinmeyen bebek için kapı, `PinnedActiveBaby` sabitleme, "Sayfa bulunamadı" görünümü.
> - **Doğrulama:** `flutter test` **178/178**, `flutter analyze` ve `dart format` temiz. Bu adımda SQL ve Edge değişmedi.
> - **Kalan (bilinçli):** Liste ekranları (zaman tüneli, albüm, takvim, arama, ilkler, mektuplar, kapsüller) hâlâ seçili bebeği gösteriyor. Bunlar salt okuma görünümü; yazma ve detay yolları artık bebek kimliği taşıyor. İstenirse ayrı bir adımda `/babies/:babyId/...` biçimine taşınabilir.

**Doğrulanan:** [router.dart:209-239](lib/app/router.dart#L209-L239). `/book`, `/book/editor`, `/book/view`, `/book/page/:pageId`, `archiveRoute`, `filmRoute`, `filmViewRoute` rotalarının hiçbiri `babyId` taşımıyor. `BookRouteGate`, `FilmRouteGate` ve `ArchiveRouteGate` `activeBabyProvider` kullanıyor. [book_repository.dart](lib/features/book/data/book_repository.dart#L35) içinde `_reload`, `applySync` (L126), `updateProject` (L148), `deletePage` (L180) ve `deleteItem` (L189) yalnız `id` ile çalışıyor.

**Ek (yeni):**
- Oluşturma formları (`/memory/new`, `/milestone/new`, `/letter/new`, `/capsule/new`) bebeği `activeBabyProvider`'ı **build sırasında izleyerek** alıyor ([memory_form_screen.dart:160](lib/features/memories/presentation/memory_form_screen.dart#L160)). Form açıkken aktif bebek değişirse girilen veri ve seçilen medya diğer bebeğe kaydedilebilir.
- `/family/member/:id` ve [family_repository.dart:53-56](lib/features/family/data/family_repository.dart#L53-L56) (`updateMember` / `removeMember`) yalnız üyelik id'si ile çalışıyor.
- Liste ekranları (timeline, album, letters, milestones, capsules, search) aktif bebeğe bağlı. Plan §2.4/7'ye göre aktif bebek yalnız UI kolaylığıdır. Okuma için kabul edilebilir, ama §3.3 route anahtar kuralına uymuyor.

**Etki:** RLS farklı aile saldırılarını engelliyor. Aynı ebeveynin iki bebeği arasında ise yanlış bağlama yazma ve ekranın kayması riski sürüyor.

**Öneri:** Rotaları `/babies/:babyId/{book,film,archive}` biçimine taşımak; form ekranlarında bebeği ilk açılışta sabitlemek (`initState` içinde yakalanan `babyId`); kitap ve üye mutation'larına `.eq('baby_id', …)` eklemek.

### Y-5 — Kitap finalize akışında kurtarılamayan hata penceresi  `YÜKSEK · Codex CXR-04 doğrulandı · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi.
> - **Edge:** [book-artifact-finalize](supabase/functions/book-artifact-finalize/index.ts) artık tekrar çağrılabilir. `finalizeAction` her kayıt durumu için tek bir davranış tanımlıyor:
>   - `staging`: doğrula → taşı → yayınla.
>   - `verified`: final nesne varsa (yoksa staging) yeniden hash'lenip doğrulanan SHA ile karşılaştırılıyor, gerekirse taşınıyor, yayınlanıyor.
>   - `ready`: iş sahibi doğrulanıyor ve yayınlanmış sürüm tekrar dönüyor.
>   - Eşzamanlı bir tekrar deneme önce yayınlarsa da başarı döner.
>   - Karantinadaki veya iptal edilmiş kayıt reddedilir.
> - **İstemci:** [book_publisher.dart](lib/features/book/data/book_publisher.dart) `retryTransient` ile ağ hatası veya 5xx sonrası aynı dosya için en çok 3 deneme yapıyor; 4xx kesin ret sayılıyor. Böylece hazırlanmış bir kitap çöpe gitmiyor ve kiralık iş yeni denemeyi dakikalarca bloklamıyor.
> - **Testler:** `finalizeAction` Edge birim testi; [book_publisher_retry_test.dart](test/book/book_publisher_retry_test.dart) 3 test.
> - **Doğrulama:** Edge `deno check` ve `deno fmt` temiz, lint temiz (bkz. not), `deno test` **16/16**; `flutter test` **175/175**, `flutter analyze` temiz.
> - **Not:**
>   - Gerçek Storage taşıma/yayın kesintisini uçtan uca canlandıran bir entegrasyon testi yok (Supabase Storage gerektirir); karar mantığı ve istemci tekrarı birim testleriyle doğrulandı.
>   - Deno 2.9.7'nin yeni `no-import-prefix` lint kuralı, HEAD'deki tüm Edge fonksiyonlarındaki `npm:` import'una da uyarı veriyor; bu değişiklikten bağımsız.

[book-artifact-finalize/index.ts:98-103](supabase/functions/book-artifact-finalize/index.ts#L98-L103) yalnız `status === "staging"` durumunu kabul ediyor. Akış şöyle: `verify` → DB `verified`, ardından Storage `move` ([L153](supabase/functions/book-artifact-finalize/index.ts#L153)), ardından `book_artifact_publish` ([L166](supabase/functions/book-artifact-finalize/index.ts#L166)). Move başarılı olup publish başarısız olursa artifact `verified` durumunda, dosya final yolda kalır ve yeniden deneme `artifact_not_staging` ile reddedilir. Bunu kapsayan bir test yok.

**Öneri:** `verified` durumundan idempotent devam etmek: final nesne varsa yeniden hash'leyip publish etmek, `ready` ise aynı yanıtı dönmek. Move-başarılı/publish-başarısız entegrasyon testi eklemek.

### Y-6 — Genel veri dışa aktarımı yok; abonelik kapısı okumayı da kapatıyor  `YÜKSEK → karar sonrası: export yapılmayacak, abonelik kapısı salt okunur olmalı · Codex CXR-05 · SALT OKUNUR KISMI DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02): P-2 (salt okunur) uygulandı; ayrı commit olarak işlendi.**
> - **Sunucu:** [20261002000400_subscription_read_only.sql](supabase/migrations/20261002000400_subscription_read_only.sql)
>   - `has_baby_permission` içinde `view_memories` ve `view_album` artık abonelik istemiyor.
>   - Yükleyicinin kendi medyasını görmesi üyeliğe bağlandı.
>   - `can_read_baby_object` imzalı URL'leri yeniden açıyor.
>   - Kapalı kalanlar: yazma koruyucusu, Storage yükleme/silme, premium satın alma/üretim/indirme ve kitap yapılandırması (`book_config_access`).
>   - [95_store_billing_access_gate_test.sql](supabase/tests/95_store_billing_access_gate_test.sql) karara göre güncellendi: okuma açık, ekleme/düzenleme/yükleme kapalı.
> - **Flutter:**
>   - Zorunlu ödeme sayfası yönlendirmesi ve `allowedWithoutSubscription` kaldırıldı.
>   - `babySubscriptionReadOnlyProvider` eklendi. Erişim modeli abonelik pasifken yazmayı kapatıyor (LOCKED ile aynı salt okunur deneyim, `+` gizli).
>   - `LifecycleWriteGuard` form rotalarını kapatıyor.
>   - Kabukta `SubscriptionReadOnlyBanner` var ve ödeme sayfasına götürüyor. Ödeme ekranında geri düğmesi ve salt okunur metinler var.
>   - Yeni testler: erişim modeli, uyarı bandı ve form koruması.
> - **Doküman:** ADR 0002 karar güncellemesi, [store-billing-setup.md](docs/operations/store-billing-setup.md), [support-texts.md](docs/support/support-texts.md), [client-rpc-contracts.md](docs/api/client-rpc-contracts.md).
> - **Doğrulama:** SQL **1075 doğrulama geçti**, `flutter test` **172/172**, `flutter analyze` ve `dart format` temiz.
> - **Kapsam dışı:** Genel export yapılmıyor (P-7).

- [privacy-actions/index.ts](supabase/functions/privacy-actions/index.ts) yalnız `delete_account` ve `delete_baby` işlemlerini destekliyor. Genel bir export yok.
- [release-runbook.md:104](docs/operations/release-runbook.md#L104) Offline HTML'i ve "Super Admin araçlarıyla dışa aktarma"yı KVKK export'u olarak gösteriyor. Offline HTML ücretli, yalnız LOCKED bebekte ve aktif abonelikle alınabiliyor; Super Admin export RPC'si ise bulunamadı.
- **Yeni boyut:** `subscription_enforcement` açıldığında abonelik pasif olan aile kendi arşivini **okuyamıyor** bile ([paywall_screen.dart:23-29](lib/features/subscription/presentation/paywall_screen.dart#L23-L29) yalnız ayarlar, plan ve ödeme sayfalarına izin veriyor). Sonuçta kullanıcının kendi verisine ödeme yapmadan erişmesinin hiçbir yolu kalmıyor; yalnız silme mümkün. Bu, KVKK md. 11 kapsamındaki bilgi talep etme ve erişim hakları açısından hukuki risk taşıyor.

**Karar (P-4/P-7, 2026-10-02 — son hâli): Genel bir veri dışa aktarımı olmayacak.** Bebeğin verisi yalnız resmî çıktılar olarak alınır: **Film (MP4), Offline HTML (ZIP) ve Dijital Kitap (PDF)**. Bu çıktıların kuralları zaten belli: LOCKED profil, aktif aile aboneliği, ürün entitlement'ı, ebeveyn üretir, Family Member yalnız izinli indirir.

**Sonuçları:**
- **Yeni yapılacak bir şey yok:** Ayrı bir export uç noktası **yapılmayacak**. Önceki "export uç noktası kur" önerisi geçersiz.
- **Doküman düzeltmesi:** [release-runbook.md:104](docs/operations/release-runbook.md#L104) "Super Admin araçlarıyla aile verisini dışa aktarma" diyor; böyle bir araç yok ve olmayacak. Metin karara göre düzeltilmeli. GELISTIRME.MD Faz 13'teki "privacy export" maddesi de karar kaydıyla güncellenmeli.
- **Kişi isimleri:** Kişi isimleriyle ilgili kural (P-11) artık doğrudan bu üç çıktıya uygulanıyor; bkz. Y-10.
- **Hukuki değerlendirme (kullanıcı gerekçesi, P-12):**
  - Kişi kendi verisini yalnız bir ürün olarak alır. Uygulama veriyi üçüncü kişilere hiçbir şekilde dağıtmaz.
  - İndirilen Film, Kitap veya HTML'i üçüncü kişilerle paylaşmak, indiren ebeveynin kendi tercihidir.
  - Bebeğin yasal temsilcileri ve varisleri ebeveynler olduğu için indirme hakkı yalnız ebeveynlere aittir.
  - Abonelik bittiğinde görüntüleme erişimi salt okunur olarak sürer (P-2).
  - Rapor önerisi: Bu gerekçenin aydınlatma metnine ve gizlilik politikasına aynı biçimde yazılması ve yayından önce hukuk ekibince teyit edilmesi.

**P-2 kararının etkisi (abonelik bitince salt okunur):** Mevcut davranış bu kararla çelişiyor ve değişmeli:
- **RLS/Storage:** Abonelik kapısı okuma (SELECT ve Storage okuma) politikalarından kaldırılmalı, yalnız yazma yollarında (INSERT/UPDATE/DELETE, Storage yazma, upload başlatma) kalmalı.
- **Flutter:** [router.dart:337-340](lib/app/router.dart#L337-L340) ve [paywall_screen.dart:23-29](lib/features/subscription/presentation/paywall_screen.dart#L23-L29) uygulamayı ödeme sayfasına kilitlememeli. Arşiv, takvim, arama ve detaylar açık kalmalı. Ekle/düzenle/sil aksiyonları, LOCKED deneyimindeki gibi gizlenmeli ve "aboneliği yenile" yolu gösterilmeli.
- **Değişmeyenler:** Lifecycle değişmez: ACTIVE bebek ACTIVE kalır, ama abonelik yokken yazılamaz. §2.7 gereği premium satın alma, render ve indirme kapalı kalır; entitlement ve artifact'lar korunur.
- **KVKK:** Salt okunur erişim, arşivin görüntülenmesine ilişkin riski büyük ölçüde azaltır. Taşınabilir kopya yalnız resmî çıktılarla alınır (P-4/P-7); hukuk onayı notu yukarıda.
- **Testler:** "Abonelik pasif → SELECT başarılı, INSERT/UPDATE/DELETE ve Storage yazma reddedilir" SQL/RLS testleri ve router widget testleri eklenmeli. Faz 6 testlerinin okumanın reddedildiğini bekleyen bölümleri güncellenmeli.

### Y-7 — Faz 13 go-live kapıları kapanmadı  `YÜKSEK (release blocker) · Codex CXR-01 doğrulandı`

[PHASE_13_REPORT.md](docs/implementation/reports/PHASE_13_REPORT.md) açıkça listeliyor: staging rollout ve cohort, gerçek veri mutabakatı, mağaza sandbox ve webhook kanıtı, kill-switch tatbikatı, yedek/geri yükleme ve felaket kurtarma, bağımsız pentest, OSV/bağımlılık taraması. Bunlar kapanmadan production migration'ı, bayrak açılışı ve gerçek ödeme kabulü yapılmamalı.

---

### Y-8 — Hesap silmede ebeveyn olmayan üye otomatik olarak yönetici yapılıyor  `YÜKSEK · Yeni (P-5 kararı sonrası) · DÜZELTİLDİ (ayrı commit; bkz. Y-2 durum notu)`

**Kod:** [20260926000600_views_rpc.sql:131-160](supabase/migrations/20260926000600_views_rpc.sql#L131-L160). `prepare_account_deletion`, silinen kullanıcı bebeğin son yöneticisiyse bir halef seçip `is_admin = true` yapıyor. Sıralama önce anne/baba'yı tercih ediyor (`order by (relation in ('anne','baba')) desc, joined_at`). Ama başka ebeveyn yoksa **en eski ebeveyn olmayan üye** (ör. babaanne) yönetici oluyor.

**Etki:** Tek ebeveynli bir ailede ebeveyn hesabını sildiğinde bir akraba yönetici olur. Bundan sonra bebeği silebilir, ebeveyn yetkilerini kullanabilir ve premium çıktıları yönetebilir. Bu, "yönetici yalnız anne ve baba" kararına (P-5) doğrudan aykırı.

**P-8 kararı (2026-10-02):** Ebeveynlerden biri hesabını silerse diğer ebeveyn **tek yönetici** olarak kalır. Silinen ebeveyn başka bir hesapla geri dönmek isterse, ailede kalan yönetici ebeveynin **onayıyla** sisteme dahil edilir.

**Gerekli düzeltme:**
- **Halef:** Halef yalnız diğer ebeveyn olabilir. Kalan ebeveyn zaten yöneticiyse (P-5 gereği öyle olmalı) hiçbir yükseltme yapılmaz. Ebeveyn olmayan üyeye asla yöneticilik verilmez.
- **Koltuk:** Silinen ebeveynin `family_account_members` kaydı `removed` olur ve ikinci ebeveyn koltuğu boşalır.
- **Geri dönüş:** Yeni hesap, yalnız kalan ebeveynin oluşturduğu veya onayladığı `anne`/`baba` davetiyle girebilir (bkz. Y-9).
- **Eski içerik:** Yeni hesap, eski hesabın yazdığı içeriğin sahipliğini otomatik almaz. Eski içerik, hesap silmede seçilen seçeneğe göre (`p_delete_content`) silinir ya da yazar bağlantısı kaldırılmış olarak kalır.
- **Testler:** "Anne hesabını siler → baba tek yönetici", "ebeveyn olmayan üye yönetici yapılmaz", "eski anne yeni hesapla yalnız babanın davetiyle girer" senaryoları eklenmeli. [60_account_notifications_test.sql:70](supabase/tests/60_account_notifications_test.sql#L70) buna göre güncellenmeli.
- **P-10 kararı (2026-10-02):** Ailede **tek ebeveyn** varsa bu ebeveyn hesabını **silemez**. Önce mevcut bebekleri silmesi gerekir.
  - **Bugünkü kod:** `prepare_account_deletion`, kullanıcının tek üye olduğu bebekleri **otomatik siliyor**, başka üye varsa halef yükseltiyor ([20260926000600_views_rpc.sql:131-160](supabase/migrations/20260926000600_views_rpc.sql#L131-L160)). İki davranış da karara aykırı.
  - **Gerekli değişiklik:** Kullanıcının **tek aktif ebeveyn** olduğu herhangi bir bebek varsa hesap silme `delete_babies_first` gibi bir ipucuyla reddedilmeli. Bebekler otomatik silinmemeli. Diğer ebeveynin bulunduğu bebeklerde ise P-8 geçerli: diğer ebeveyn tek yönetici kalır.
  - **Arayüz:** [Hesap silme ekranı](lib/features/settings/presentation/settings_screens.dart) önce silinmesi gereken bebekleri listelemeli ve bebek silme akışına yönlendirmeli. Kullanıcıya önce aksiyon verip sonra hata göstermemeli (§2.3 ilkesi).
  - **Testler:**
    - "Tek ebeveyn, bebek varken hesabını silemez."
    - "Bebekleri sildikten sonra hesabını silebilir."
    - "İki ebeveynli bebekte biri silebilir, diğeri tek yönetici kalır."

### Y-9 — Bir ebeveyn diğerini çıkarabiliyor; ebeveyn daveti ebeveyn onayına bağlı değil  `YÜKSEK · Yeni (P-8/P-9 kararları sonrası) · DÜZELTİLDİ (ayrı commit; bkz. Y-2 durum notu)`

**Kod:**
- [family_members_guard](supabase/migrations/20260926000200_babies_family.sql#L182-L265) yalnız "en az bir yönetici kalsın" ve "yönetici olmayan, yöneticiyi çıkaramaz" kurallarını uyguluyor. Bu yüzden **bir yönetici ebeveyn, diğer ebeveyni aileden çıkarabiliyor** (DELETE) veya **yöneticiliğini alabiliyor** (`is_admin` → `false` UPDATE). Silme politikası: `user_id = auth.uid() or has_baby_permission(baby_id, 'manage_members')` ([L401-402](supabase/migrations/20260926000200_babies_family.sql#L401-L402)). Uygulama tarafında `removeMember(memberId)` bunu doğrudan çağırıyor ([family_repository.dart:56](lib/features/family/data/family_repository.dart#L56)).
- [family_invitations_guard](supabase/migrations/20260926000200_babies_family.sql#L329-L366) `invite_members` iznine sahip **ebeveyn olmayan** bir üyenin de `relation = 'anne'` veya `'baba'` davet oluşturmasına izin veriyor (yalnız `is_admin=true` engelleniyor). Bu kişi ebeveyn koltuğuna sayılmasa da "anne/baba" ilişkisiyle aileye giriyor; sonra bir yönetici bu kişiyi yönetici yapabiliyor.

**Sözleşme:**
- **P-9:** Hiçbir ebeveyn diğer ebeveyni aileden çıkaramaz.
- **P-8:** Geri dönen ebeveyn yalnız kalan ebeveynin onayıyla girer.
- **P-5:** İki ebeveyn eşit yetkilidir.

**Gerekli düzeltme:**
- **Çıkarma/düşürme yasağı:** Ebeveyn (anne/baba) üyeliği yalnız kişinin kendisi tarafından (ayrılma veya hesap silme) ya da audited Super Admin/destek süreciyle sonlanabilmeli. Başka bir ebeveynin DELETE isteği ve `is_admin`'i düşüren UPDATE isteği tetikleyicide reddedilmeli. Aynı kural `family_account_members` ebeveyn kaydı için de geçerli olmalı.
- **Davet kuralı:** `anne`/`baba` ilişkili davetleri yalnız aktif ebeveyn oluşturabilmeli. Böylece "kalan ebeveynin onayı" sunucuda zorunlu olur. Ebeveyn koltuğu kontrolü (en fazla 2) korunmalı.
- **Uygulama arayüzü:** Üye ekranında diğer ebeveyn için "çıkar" ve "yöneticiliği kaldır" aksiyonları gösterilmemeli.
- **Testler:** "Anne babayı çıkaramaz", "anne babanın yöneticiliğini kaldıramaz", "baba kendi isteğiyle ayrılabilir", "ebeveyn olmayan üye anne/baba daveti oluşturamaz", "üçüncü ebeveyn eklenemez".

### Y-10 — Çıktılarda kişi isimleri kararlaştırılan biçimde değil  `YÜKSEK · Yeni (P-11 kararı sonrası) · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi. Üç üründe tek kural uygulanıyor: yakınlık kelimesi = özel etiket, yoksa bilinen ilişkinin iyelik hali; sonuç "Ad + yakınlık" ("Esra Teyzesi", "Elif Annesi"); ad yoksa yalnız yakınlık.
> - **Film:** [20261002000700_output_person_names.sql](supabase/migrations/20261002000700_output_person_names.sql) ile `output_person_name(jsonb)`; mektup alt başlıkları bunu kullanıyor.
> - **Kitap:** `outputPersonName`, `FamilyMember.outputName` ve `Letter.outputSignature`; `BookRenderResolver` bunları kullanıyor. Uygulama içi metinler ("Teyzesi Zeynep yeni bir anı ekledi") değişmedi.
> - **HTML:** worker'daki `personLabel`.
> - **Ortak test örnekleri:** [99n_output_person_names_test.sql](supabase/tests/99n_output_person_names_test.sql), [output_person_name_test.dart](test/book/output_person_name_test.dart) ve `workers/output/tests/html_unit.test.ts` aynı 6 örneği doğruluyor. Kitap snapshot testi ve worker HTML testi yeni biçime güncellendi.
> - **Mühürlü çıktılar:** Daha önce mühürlenmiş manifest'ler ve artifact'lar değişmez; yeni sürümler yeni biçimle üretilir.
> - **Doğrulama:** SQL **1077 geçti**, `flutter test` **175/175**; worker `deno check`, `deno fmt`, `deno lint` temiz ve birim testleri **12/12**. ffmpeg/Chrome gerektiren worker entegrasyon testleri bu ortamda çalıştırılmadı; CI'daki `output-worker` job'ında koşar.

**Karar (P-11):** Film, HTML ve Kitap'ta adı geçen her kişi **"Ad + yakınlık"** biçiminde gösterilir: "Esra Teyzesi", "Ahmet Amcası". Kural mektuplar, yorumlar, anılar ve ilkler dahil tüm içerik için geçerli.

**Kod (bugün):**
- **HTML:** [site.ts:167-172](workers/output/src/html/site.ts#L167-L172) `personLabel` → `"Teyzesi Esra"` (yakınlık önce).
- **Kitap:** [family_member.dart:60-64](lib/features/family/domain/family_member.dart#L60-L64) `introduction` ve [letter.dart:46-49](lib/features/letters/domain/letter.dart#L46-L49) `signature` → `"Teyzesi Esra"` (yakınlık önce).
- **Film:** [film_artifacts.sql:205-206](supabase/migrations/20261001000200_film_artifacts.sql#L205-L206) mektup alt başlığı yalnız ad (`"Esra"`); ad yoksa yalnız `relation_label`. Yakınlık eki hiç yok.

**Etki:** Üç ürün aynı kişiyi üç farklı biçimde yazıyor ve hiçbiri karara uymuyor. Ücretli çıktılar immutable olduğu için yanlış biçimle üretilmiş bir artifact sonradan değişmez; yeni sürüm gerekir (§2.8). Bu yüzden düzeltme, **ürün satışları açılmadan önce** yapılmalı.

**Gerekli düzeltme:**
- Tek bir ortak biçim fonksiyonu tanımlamak ("Ad + yakınlık eki"; özel `relation_label` varsa o; ad yoksa yalnız yakınlık, ör. "Teyzesi"). Bu fonksiyon SQL (film sahne planı), worker (HTML) ve Dart (Kitap) tarafında aynı sonucu vermeli; ortak test vektörleriyle doğrulanmalı.
- Snapshot zaten ad ve yakınlığı ayrı tutuyor, şema değişikliği gerekmiyor. Biçim, render manifest'inin bir parçası olduğundan yeni manifest/şema sürümüyle yayınlanmalı.
- `relation = 'diger'` ve etiketsiz kişiler için "Esra Bir yakını" gibi bozuk sonuç çıkmamalı (öneri: yalnız ad).

**Yorum notu:** Kural ebeveynler için de geçerli kabul edildi: "Elif Annesi", "Mert Babası". Uygulama içi ekranlardaki gösterim (bildirim, aktivite, liste) bu kararın kapsamında değil; tutarlılık için aynı fonksiyon kullanılabilir.

### Y-11 — Aile üyeleri çıktı indirebiliyor ve orijinal medyayı paylaşabiliyor  `YÜKSEK · Yeni (P-12 kararı sonrası) · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** P-13 planı uygulandı; ayrı commit olarak işlendi.
> - **Migration:** [20261002000600_parent_only_downloads.sql](supabase/migrations/20261002000600_parent_only_downloads.sql)
>   - Mevcut paylaşımlar silinmeden `parents_only_decision` ile iptal edildi; `member_downloads` bayrağı kapatıldı.
>   - `output_artifact_download_block` ebeveyn olmayan herkese başka kontrolden önce `not_parent` döndürüyor; aile üyesi kapasite/paylaşım dalı kaldırıldı.
>   - `set_artifact_download_permission(..., true)` `member_downloads_disabled` ile reddediliyor; iptal hâlâ çalışıyor.
>   - `book_versions`, `film_state` ve `html_state` aile üyesinden çıktıları tamamen gizliyor.
> - **Edge:** `not_parent` → 403 "yalnızca Anne veya Baba indirebilir".
> - **Flutter:**
>   - Paylaşım ekranı, rotası, sağlayıcısı, depo metotları ve modeli kaldırıldı; eski rota mağazaya yönleniyor.
>   - Kitap, Film ve Arşiv modellerinde aile üyesi görünümü kaldırıldı; kapılar "Yalnızca Anne ve Baba" mesajı gösteriyor.
>   - Medya görüntüleyicide "Paylaş / kaydet" yalnız ebeveyne görünüyor.
> - **Testler:**
>   - Aile üyesi indirmesini doğrulayan SQL testleri (98, 99, 99f, 99h, 99m) ve Flutter testleri (arşiv, kitap kapısı, film, mağaza) karara göre güncellendi; paylaşım ekranı testi kaldırıldı.
>   - Yeni kontroller: aile üyesi her üründe `not_parent` alıyor, kayıt dışı kalmış bir paylaşım satırı da indirme açmıyor, denetimde aile üyesi indirmesi yok.
> - **Belgeler:** [artifact-download-policy.md](docs/operations/artifact-download-policy.md), destek metni, API sözleşmesi.
> - **Doğrulama:** SQL tam paket geçti; Edge `deno test` **16/16**; `flutter test` geçti.
> - **Not:** Medya paylaşım düğmesinin yalnız ebeveyne görünmesi için ayrı bir widget testi yazılmadı (ekran çok sağlayıcı gerektiriyor); `flutter analyze` ve mevcut testler geçti.

**Karar (P-12):** Film, Kitap ve HTML'i **yalnız ebeveynler** indirebilir; aile üyeleri hiçbir koşulda indiremez. Uygulama veriyi üçüncü kişilere dağıtmaz.

**Kod (bugün):** Faz 12 bunun tersini kuruyor.
- **İzin tablosu ve indirme:** [20261001000400_member_artifact_downloads.sql](supabase/migrations/20261001000400_member_artifact_downloads.sql), ebeveyn izniyle aile üyesine indirme açan `artifact_download_permissions` tablosunu, `set_artifact_download_permission` RPC'sini ve [`output_artifact_download_block`](supabase/migrations/20261001000400_member_artifact_downloads.sql#L130-L197) içindeki aile üyesi dalını içeriyor. Bu dal bir bayrağa bağlı ve varsayılanı **açık**: `member_downloads = true` ([L25-27](supabase/migrations/20261001000400_member_artifact_downloads.sql#L25-L27)).
- **Uygulama:**
  - [download_permissions_screen.dart](lib/features/premium/presentation/download_permissions_screen.dart) ebeveynin izin verdiği ekran.
  - Kitap, Film ve Arşiv modellerindeki `isFamilyMemberView` aile üyesine çıktı ekranını açıyor ([book_gate.dart:42](lib/features/book/presentation/book_gate.dart#L42)).
- **Medya paylaşımı:** [media_viewer_screen.dart:166-176](lib/features/media/presentation/media_viewer_screen.dart#L166-L176). "Paylaş / kaydet" düğmesi, arşivi görebilen **herkesin** (aile üyeleri dahil) orijinal fotoğraf ve videoyu cihaza indirip sistem paylaşım menüsüyle üçüncü kişilere göndermesine izin veriyor. Bu, "veri yalnız ürün olarak ve yalnız ebeveyne çıkar" kararıyla çelişiyor.

**Etki:** Kod bugün çalışsa, ebeveyn izni olan aile üyeleri ücretli çıktıları indirebilir; herhangi bir aile üyesi de kaynak medyayı uygulama dışına çıkarabilir.

**Gerekli düzeltme:**
- **Hemen:** `member_downloads` bayrağını tüm ortamlarda `false` yapmak. Bu, aile üyesi indirmesini kod değişikliği olmadan kapatır; ebeveynleri etkilemez.
- **İndirme yolunu kalıcı kapatmak:** Yeni ileri migration ile `output_artifact_download_block` ebeveyn olmayan herkes için koşulsuz `not_parent` dönmeli. `set_artifact_download_permission` devre dışı kalmalı. Mevcut izinler silinmeden audit ile `revoked` yapılmalı (§5 rollback ilkesi: tarihsel migration düzenlenmez, veri silinmez).
- **Uygulama:** İzin ekranı ve rotası kaldırılmalı. `isFamilyMemberView` dalları kapatılmalı; aile üyesine Kitap, Film ve Arşiv girişleri hiç gösterilmemeli.
- **Medya paylaşımı (P-13, onaylandı):** "Paylaş / kaydet" düğmesi **yalnız ebeveynlere** gösterilmeli; aile üyelerinde görünmemeli. Arka planda da aile üyesinin orijinal dosyayı tam çözünürlükte indirebildiği yollar gözden geçirilmeli. Ekranda görüntüleme için önbellek kaçınılmazdır; ekran görüntüsü teknik olarak engellenemez ve bu kararın kapsamı dışındadır.
- **Testler:** "Aile üyesi, izin olsa bile indiremez", "ebeveyn indirebilir", "aile üyesi çıktı ekranına giremez", "aile üyesine paylaşım düğmesi görünmez".
- **Doküman:** GELISTIRME.MD §2.7, §3.1.1 (karar matrisinin son satırı), Faz 12 ve §6/§8'deki aile üyesi indirme maddeleri karar kaydıyla güncellenmeli. [artifact-download-policy.md](docs/operations/artifact-download-policy.md) de güncellenmeli.

### O-1 — `media.taken_on` için tarih guard'ı yok  `ORTA · Yeni · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi.
> - **Migration:** [20261002000500_media_date_guard.sql](supabase/migrations/20261002000500_media_date_guard.sql)
>   - **Önce rapor:** `admin_media_date_report()` (Super Admin) geçersiz tarihli eski medyayı sayıyor, nedene göre ayırıyor ve örnek veriyor.
>   - **Sonra kural:** `content_date_guard` medyayı da kapsıyor (`media_date_guard`, yalnız `taken_on` yazılırken): doğum − 310 gün ile bugün + 1 arası.
>   - Eski kayıtlar değişmiyor ve silinmiyor; durum güncellemeleri çalışmaya devam ediyor.
> - **İstemci etkisi yok:** Uygulama çekim tarihini EXIF'ten değil, bağlı içeriğin (zaten kontrollü) tarihinden veya doğum − 300 ile bugün arasıyla sınırlı tarih seçiciden alıyor. Hata ipuçlarının Türkçe metinleri zaten vardı.
> - **Test:** [16_media_date_guard_test.sql](supabase/tests/16_media_date_guard_test.sql), 8 doğrulama.
> - **Doğrulama:** Tam SQL paketi **1083 doğrulama geçti**.
> - **Belgeler:** Runbook rollout raporlarına `admin_parent_authority_report()` ve `admin_media_date_report()` eklendi; API sözleşmesi güncellendi.

Anı, ilk ve mektuplar `content_date_guard` ile korunuyor: doğumdan en fazla 310 gün önce, bugünden en fazla 1 gün sonra ([20260926000300_content.sql:243-278](supabase/migrations/20260926000300_content.sql#L243-L278)). `media.taken_on` ise yalnız `not null` ([L143](supabase/migrations/20260926000300_content.sql#L143)) ve istemci güncelleyebiliyor ([media_repository.dart:113](lib/features/media/data/media_repository.dart#L105-L114)). Saati yanlış bir kameranın EXIF tarihi (ör. 2035) fotoğrafı resmî snapshot'tan sessizce düşürebilir (`taken_on <= cutoff`). Ayrıca legacy rollout raporundaki `post_cutoff_content` sayısını şişirir ve Film bölüm atamasını bozar. **Öneri:** Aynı guard'ı `media` tablosuna uygulamak (önce mevcut veriyi dry-run ile raporlamak).

### O-2 — Snapshot cutoff efektif kapanış yerine +405 kullanıyor  `ORTA → karar sonrası kesin ihlal · Codex CXR-02 · DÜZELTİLDİ (ayrı commit; bkz. Y-1 durum notu)`

[release_hardening.sql:158](supabase/migrations/20261001000500_release_hardening.sql#L158) `birth_date + 405` kullanıyor; Codex bunu doğru tespit etmiş. Ancak:

- Faz 13 metni bu davranışı **literal olarak** istiyor (P-1).
- `content_date_guard` gelecek tarihli içeriği engellediği için ACTIVE dönemde oluşan içerik zaten efektif kapanıştan önceki (en geç +1 gün tolerans) tarihlerde kalıyor. Pratik etki **legacy (lifecycle öncesi) veri** ve O-1'deki medya ile sınırlı.
- Sorun testte de kalıcı hale gelmiş (`99r_release_hardening_test.sql` +405'i dahil bekliyor).

**Karar (P-1, 2026-10-02):** Resmî çıktı = 375 gün + varsa onaylı uzatma; mutlak tavan 405. Bu nedenle bulgu artık **kesin bir sözleşme ihlali**.

**Gerekli düzeltme:**
- Cutoff'u bebeğin gerçek `effective_close_date` değerine bağlamak, yarı açık aralıkla: `content_date < birth_date + 375 + approved_days`. Uzatma yoksa son dahil gün `+374`, 30 gün uzatmada `+404`.
- Değişecek yerler:
  - [release_hardening.sql:158](supabase/migrations/20261001000500_release_hardening.sql#L158) (yeni ileri migration ile),
  - `admin_legacy_rollout_report` içindeki `+405` sayımları ([L255-258](supabase/migrations/20261001000500_release_hardening.sql#L255-L258)),
  - `99r_release_hardening_test.sql`'deki +405 beklentisi.
- Yeni testler: uzatmasız bebekte 375. gün içeriği hariç; 30 gün uzatmada 404. gün dahil, 405. gün hariç.
- Super Admin grandfather kararı yalnız efektif kapanış dışındaki legacy içerik için istisna olarak kalır.
- Y-1 (kitap penceresi) de aynı sınıra hizalanmalı.

### O-3 — CI, Edge Function testlerini ve tip kontrolünü çalıştırmıyor  `ORTA · Yeni · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** [ci.yml](.github/workflows/ci.yml) yeni bir `edge-functions` job'ı içeriyor: tüm fonksiyonlar için `deno check */index.ts` ve `deno test` (yerelde 7/7 tip kontrolü ve 16/16 test geçti).
> - **Kapsam dışı bırakılan:** `deno fmt --check` CI'a eklenmedi. HEAD'deki 10 Edge dosyasında (faturalama yardımcıları, `deno.json` vb.) bu değişikliklerden bağımsız biçim farkları var.
> - **Lint:** Yeni Deno'nun `no-import-prefix` kuralı tüm fonksiyonlardaki `npm:` import'larına uyarı verdiği için lint de eklenmedi.
> - **Öneri:** İkisi için ayrı, yalnız biçim/import düzenlemesi içeren bir commit.

[ci.yml](.github/workflows/ci.yml) içinde yalnız `flutter`, `database`, `output-worker`, `android` ve `ios` job'ları var. `supabase/functions` için `deno check` / `deno test` adımı yok. Faz raporlarındaki "15 Edge testi geçti" beyanı yerel çalıştırmaya dayanıyor ve regresyonlar CI'da yakalanmıyor. `book-artifact-finalize`, `output-download` ve `billing-*` güvenlik açısından kritik fonksiyonlar. **Öneri:** Edge Function job'ı eklemek.

### O-4 — Bilinen şifreli demo hesapları ve barındırılan proje  `ORTA · Yeni · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi.
> - [20261002000800_release_health_demo_accounts.sql](supabase/migrations/20261002000800_release_health_demo_accounts.sql): `admin_release_health()` yeni bir `demo_accounts` kontrolü içeriyor. Seed'deki 4 demo kullanıcı kimlik veya e-postayla bulunursa `critical`.
> - [99r](supabase/tests/99r_release_hardening_test.sql): 10 kontrol; seed'li test veritabanında `critical:4` bekleniyor. SQL tam paketi **1078 doğrulama geçti**.
> - Runbook go-live kapılarına eklenenler: production'da `demo_accounts = ok`, seed production'a uygulanmaz, mağaza sürümleri `DEMO_MODE` kapalı derlenir (`env/example.json` zaten `false`).

[seed.sql:7](supabase/seed.sql#L7) dört demo hesabı tanımlıyor (`Demo1234!`). Giriş ekranı `DEMO_MODE` açıkken bu şifreyi otomatik dolduruyor ([auth_screens.dart:218-240](lib/features/auth/presentation/auth_screens.dart#L218-L240)). Yerel `env/dev.json` barındırılan bir Supabase projesini ve `DEMO_MODE: true` değerini içeriyor. Runbook'ta "seed production'a uygulanmamalı / demo kullanıcılar silinmeli" gibi bir go-live kontrolü yok. **Öneri:** Production'da `auth.users` içinde `@example.com` hesabı bulunmadığını doğrulayan bir sağlık kontrolü ve runbook maddesi eklemek; release build'lerde `DEMO_MODE`'un kapalı olduğunu CI'da doğrulamak.

### O-5 — Worker Docker imajı lock dosyasını kullanmıyor; Deno sürümleri farklı  `ORTA · Codex CXR-06 doğrulandı · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi.
> - [Dockerfile](workers/output/Dockerfile) `denoland/deno:alpine-2.9.7` kullanıyor (Docker Hub'da var), `deno.lock`'u kopyalıyor ve `deno cache --frozen` çalıştırıyor.
> - CI'da `DENO_VERSION: v2.9.7` hem worker hem Edge job'ında kullanılıyor.
> - Yerelde Deno 2.9.7 ile `deno cache --frozen src/main.ts` başarılı; kilit dosyası değişmedi.
> - **Doğrulanmadı:** Docker imajının kendisi derlenmedi (bu ortamda Docker yok); CI'da veya dağıtım ortamında bir kez derlenmeli.

[Dockerfile:4-12](workers/output/Dockerfile#L4-L12) `deno.lock` dosyasını kopyalamıyor; importlar `@2` / `@23` gibi geniş aralıklarda. İmaj Deno `2.1.4`, CI ise `v2.x` kullanıyor. **Öneri:** Lock dosyasını imaja kopyalamak, `deno cache --frozen` kullanmak ve sürümü her yerde aynı patch'e sabitlemek.

**Ek kanıt (2026-10-02):** Depodaki `deno.lock` dosyaları (`supabase/functions` ve `workers/output`) **lockfile sürüm 5** biçiminde. Deno `2.1.4` bunları okuyamıyor ("Unsupported lockfile version '5'"); yerelde denendi. Lock dosyası imaja kopyalanırsa mevcut `denoland/deno:alpine-2.1.4` imajı build sırasında hata verir. Bu yüzden Docker imajının Deno sürümü, lockfile v5'i destekleyen bir sürüme yükseltilmeli ve CI ile aynı sürüme sabitlenmeli (doğrulamada Deno 2.9.7 kullanıldı).

### O-6 — Resmî kitap PDF'inin içeriği sunucuda doğrulanmıyor  `ORTA · Yeni (kabul edilmiş tasarım riski)`

Sunucu PDF başlığı/EOF, boyut ve SHA-256 kontrolü yapıyor. PDF'in mühürlü manifest'le **içerik olarak** uyuştuğunu doğrulamıyor; render istemcide yapılıyor. Değiştirilmiş bir istemci keyfî bir PDF'i "resmî" artifact olarak yayınlayabilir. Zarar görecek olan esas olarak bunu yapan aile olsa da, §2.8'deki "resmî artifact" garantisi zayıflıyor. Faz 9 bu protokole izin veriyor; risk ADR'ye yazılmalı. İleride sunucu tarafı render veya örnekleme doğrulaması düşünülebilir.

### O-7 — Doküman ve durum kaydı tutarsızlıkları  `ORTA · Codex CXR-08 doğrulandı ve genişletildi · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** Düzeltildi; ayrı commit olarak işlendi.
> - ADR 0004 artık `workers/output` diyor ve genelleştirmeyi açıklıyor.
> - Faz 6 ve Faz 10 raporlarına geçersiz bölümleri belirten notlar eklendi; tarihsel metin korundu.
> - Runbook §8 Faz 13 silme davranışını (`babies_erase_outputs`), P-3/P-10 ve P-7/P-12'yi doğru anlatıyor.
> - ERD'de paylaşım tablosu "tarihsel" olarak işaretlendi.
> - `PHASE_STATUS.md` commit sütunları düzeltildi: Faz 1–2 `c36c37e`, Faz 6–7 `f6a4fa9`, Faz 13 `be4c1c1`. P-2 ve P-12 değişiklikleri işlendi.
> - Faz 13 raporuna "İnceleme sonrası düzeltmeler (2026-10-02)" eki eklendi.
> - `first_year.dart`'taki "arşiv hiç kapanmaz" yorumu 3. adımda düzeltilmişti; GELISTIRME.MD karar kaydı ilk adımda eklenmişti.

- [ADR 0004:18](docs/implementation/ADR/0004-film-render-infrastructure.md#L18) ve [PHASE_10_REPORT](docs/implementation/reports/PHASE_10_REPORT.md) `workers/film` diyor; gerçek dizin `workers/output`.
- [release-runbook.md:103](docs/operations/release-runbook.md#L103) "artifact'lar `on delete restrict` ile korunur" diyor. Faz 13 bunları siliyor ve yalnız sipariş/entitlement kayıtlarını bebek bağı olmadan saklıyor.
- [PHASE_STATUS.md](PHASE_STATUS.md): Faz 1 ve 2 için "Commit oluşturulmadı" yazıyor, oysa kod `c36c37e` commit'inde. Faz 13 commit sütununda hash yerine commit mesajı var (`be4c1c1` olmalı).
- [first_year.dart:6](lib/core/utils/first_year.dart#L6) yorumunda "The archive itself never closes" yazıyor; lifecycle'dan önce kalmış ve artık yanlış.
- GELISTIRME.MD, P-2 kararını içermiyor.

### O-8 — Faz 0 kanıt zinciri eksik ve fazlar birleşik commit'lerde  `ORTA · Codex CXR-09 doğrulandı · KISMEN DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):**
> - [PHASE_00_REPORT.md](docs/implementation/reports/PHASE_00_REPORT.md) geriye dönük yazıldı. Baseline (`0b33687`) git'ten yeniden doğrulandı: 7 migration, 165 SQL doğrulaması (önceki analizle aynı), 58 statik Flutter test çağrısı (önceki analizde 54; fark raporda açıklandı).
> - Riskli legacy veri sınıfları ve önerilen işlemler yazıldı. Adetler üretim verisi gerektirdiği için Faz 13 veri mutabakatı kapısına bağlandı.
> - Birleşik faz commit'leri (4+5, 6+7, 11+12) geçmişte kaldığı için değiştirilmedi. İnceleme düzeltmeleri ise ayrı commit'ler olarak planlandı.

`PHASE_00_REPORT.md` yok. Faz 4+5, 6+7 ve 11+12 tek commit'lerde (`3b20837`, `f6a4fa9`, `fd45571`). Bu tek başına fonksiyonel bir hata değil, ama faz bazında rollback ve denetim izini zayıflatıyor.

### O-9 — Gerçek cihaz ve mağaza doğrulamaları eksik  `ORTA · Codex CXR-10 doğrulandı`

Yapılmamış olanlar: App Store / Google Play sandbox satın alma ve restore, gerçek webhook payload'ları, cold-start deep link, gerçek cihazda film oynatma ve HTML ZIP'in iOS/Android'de açılması. Mağaza ürün ID'leri placeholder ([store_billing_access_gate.sql:16-28](supabase/migrations/20260929000400_store_billing_access_gate.sql#L16-L28)). Premium ürünlerin "consumable" olarak tanımlanması, Apple restore akışında görünmez; sunucu hakkı korunsa da restore UX'i test edilmeli.

---

### D-1 — `s.extra!` ile açılan rotalar restore/deep link'te çöker  `DÜŞÜK · Yeni · DÜZELTİLDİ (Y-4 ile, ayrı commit)`

> **Durum (2026-10-02):** Kitap ve film görüntüleyicisi `extra` yoksa kendi bebeğinin kitap/film sayfasına, medya görüntüleyicisi albüme yönleniyor; artık çökmüyor.

[router.dart:143](lib/app/router.dart#L143) (`MediaViewerArgs`), [L219](lib/app/router.dart#L219) ve [L238](lib/app/router.dart#L238) (`File`) `extra` yoksa null-check hatası verir. Durum geri yükleme veya harici link bu rotaları açarsa uygulama çöker. **Öneri:** `extra` null ise güvenli geri yönlendirme yapmak.

### D-2 — Kota yarışı pratikte büyük ölçüde mevcut değil  `DÜŞÜK · Codex CXR-07 yeniden değerlendirildi`

Dört job oluşturma yolu da (`request_output_job`, kitap, film ve HTML RPC'leri) insert'ten önce `output_projects` satırını `FOR UPDATE` ile kilitliyor ([output_pipeline.sql:693-697](supabase/migrations/20260929000600_output_pipeline.sql#L693-L697) ve benzerleri). READ COMMITTED altında ikinci işlem kilidi aldıktan sonra yeni snapshot ile sayım yapıyor. Bu yüzden aynı bebek+ürün için yarış oluşmuyor. Kalan küçük boşluk: kota `baby_id` ile, kilit `family_account_id` ile hesaplanıyor. Bebek aile hesabı değiştirirse teorik bir pencere oluşur. Yarış testi eklemek yine de iyi olur.

### D-3 — `legal_erasure` bayrağı oturumdan ayarlanabilen özel bir GUC  `DÜŞÜK · Yeni (savunma derinliği) · DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** [20261002000900_small_hardening.sql](supabase/migrations/20261002000900_small_hardening.sql) ile `legal_erasure_active()` yalnız güvenilir bağlamda (definer RPC, `service_role`) true dönüyor. `authenticated` / `anon` rolü ayarı kendisi açsa bile false.
> - Yasal silme testleri (satın alınmış bebeği silme) değişmeden geçiyor.
> - Yeni test: [99t_small_hardening_test.sql](supabase/tests/99t_small_hardening_test.sql).

[release_hardening.sql:483-490](supabase/migrations/20261001000500_release_hardening.sql#L483-L490): immutability tetikleyicileri `current_setting('bebegimin.legal_erasure')` ile atlanıyor. Bu ayar `set_config` ile herhangi bir oturumdan değiştirilebilir. Bugün istismar için ilgili tablolarda DELETE yetkisi de gerekiyor (API rolleri için yok), dolayısıyla risk düşük. Yine de bayrak `babies_erase_outputs` içinde `is_local = true` ile **işlemin sonuna kadar** açık kalıyor. Aynı işlemde sonradan yapılan diğer silmeler de guard'ı atlar. **Öneri:** Bayrağı, silme bitince sıfırlanan ve yalnız definer bağlamında kontrol edilen bir mekanizmayla değiştirmek.

### D-4 — `run_daily_jobs` UTC `current_date` kullanıyor; aynı gün iki bildirim  `DÜŞÜK · Yeni · TARİH KISMI DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):** `run_daily_jobs` varsayılan günü artık `business_date_istanbul()`; test 99t'de.
> - **İki bildirim bilinçli olarak bırakıldı.** `profile_locked` tüm aileye "arşiv salt okunur" der. `book_ready` yalnız kitap oluşturabilenlere (ebeveynler) "dijital ürünler hazırlanabilir" der. Ebeveynler kilit gününde iki farklı içerikte bildirim alır. Tek bildirimde birleştirmek bir ürün kararıdır.

[release_hardening.sql:357](supabase/migrations/20261001000500_release_hardening.sql#L357) varsayılan olarak `current_date` kullanıyor, `business_date_istanbul()` kullanmıyor. 06:00 UTC cron'unda tarih İstanbul'la aynı olduğu için bugün güvenli, ama elle çalıştırmada ve saat kaymasında kırılgan. Kilit gününde hem `profile_locked` (lifecycle job) hem `book_ready` bildirimi gidiyor.

### D-5 — Privacy fonksiyonunda küçük sorunlar  `DÜŞÜK · Yeni · KISMEN DÜZELTİLDİ (ayrı commit)`

> **Durum (2026-10-02):**
> - `delete_baby` hatasında ham veritabanı mesajı yerine sabit Türkçe metin dönüyor; yalnız hata kodu loglanıyor.
> - **Değiştirilmeyenler:** Hesap silmenin çok adımlı yapısı (veritabanı → Storage → auth) ve yeniden kimlik doğrulama istenmemesi değişmedi. Birincisi tekrar çalıştırılabilir; ikincisi bir ürün kararıdır.

- `delete_baby` hata yolunda ham `error.message` istemciye dönüyor ([privacy-actions/index.ts:60-70](supabase/functions/privacy-actions/index.ts#L60-L70)).
- Hesap silme atomik değil: önce DB hazırlığı, sonra Storage, sonra `auth.deleteUser`. Son adım başarısız olursa kısmi durum kalıyor. Yeniden çalıştırılabilirliği test edilmeli.
- Hesap silme için yeniden kimlik doğrulama (şifre) istenmiyor.

### D-6 — Çalışma ağacında artık dosya  `DÜŞÜK · DÜZELTİLDİ (kullanıcı onayıyla, 2026-10-02)`

> **Durum (2026-10-02):** Takip edilmeyen `x` dosyası (eski test çalıştırma logu) kullanıcı onayıyla silindi.

Untracked `x` dosyası (migration çıktı logu) temizlenmeli veya gitignore'a eklenmeli. `android/hs_err_pid*.log` dosyaları `*.log` ile zaten yok sayılıyor.

---

## 5. Codex raporuyla çapraz doğrulama

| Codex | Konu | Claude sonucu |
|---|---|---|
| CXR-01 | Go-live kapıları | **Doğrulandı** (Y-7) |
| CXR-02 | Snapshot cutoff +405 | **Kısmen doğrulandı:** kod doğru tespit edildi; ancak Faz 13 metni bunu istiyor (plan çelişkisi) ve pratik etki legacy veri ile guard'sız medya tarihleriyle sınırlı (O-2, P-1) |
| CXR-03 | Premium rotalarında babyId yok | **Doğrulandı ve genişletildi** (Y-4: formlar, üye ekranı) |
| CXR-04 | Finalize kurtarma açığı | **Doğrulandı** (Y-5) |
| CXR-05 | Export yok | **Doğrulandı ve genişletildi** (Y-6: abonelik kapısı okumayı da kapatıyor) |
| CXR-06 | Docker lock | **Doğrulandı** (O-5) |
| CXR-07 | Kota yarışı | **Büyük ölçüde geçersiz:** proje satırı kilidi isteği sıralıyor (D-2) |
| CXR-08 | Doküman çelişkileri | **Doğrulandı ve genişletildi** (O-7) |
| CXR-09 | Faz 0 raporu | **Doğrulandı** (O-8) |
| CXR-10 | Cihaz/mağaza testleri | **Doğrulandı** (O-9) |
| — | Kitap uzatma içeriğini dışlıyor | **Yeni** (Y-1) |
| — | Ebeveyn olmayan yönetici bebeği silebiliyor | **Yeni** (Y-2) |
| — | Her üye uzatma hakkını tüketebiliyor | **Yeni** (Y-3) |
| — | `media.taken_on` guard'sız, CI'da Edge testi yok, demo hesaplar, PDF içerik doğrulaması, `extra!` çökmesi, erasure GUC, privacy detayları | **Yeni** (O-1, O-3, O-4, O-6, D-1, D-3, D-5) |

---

## 6. Güçlü ve korunması gereken yönler

- **Lifecycle çekirdeği örnek niteliğinde.** Tarih `timezone('Europe/Istanbul', statement_timestamp())` ile hesaplanıyor; kapanış yarı açık aralıkla uygulanıyor; `UNIQUE (baby_id)` tek talep sağlıyor; pending talep base close'ta expire oluyor; karar alanları tetikleyiciyle değişmez kılınmış; abonelik ve entitlement lifecycle'a hiç karışmıyor.
- **Faz 3 kilidi katmanlı.** `lifecycle_source_guard` tetikleyicisi definer RPC'leri de kapsıyor. Yabancı bebek için hata vermeyerek varlık sızdırmıyor. Doğum tarihi yalnız audited RPC ile değişiyor; ebeveyn düzeltmesi yalnız içerik yokken ve ACTIVE iken mümkün; LOCKED profili yeniden açmak açık onay ve güvenlik olayı gerektiriyor.
- **Fiyatlar tek kaynakta.** Plan ve premium fiyatları seed'de doğru (`29900/36900/46900`, `322920/398520/506520`, `34900/44900/54900`); Flutter'da hard-code TL fiyatı yok.
- **Çıktı hattı.** Mühürlü snapshot ve manifest; idempotency key ve proje satırı kilidi; lease/heartbeat/poison; staging → verify → final → publish; 60 sn signed URL; her indirmede yeniden yetkilendirme, denetim ve hız sınırı.
- **Offline HTML.** `default-src 'none'` CSP, tüm kullanıcı metni `esc()` ile kaçışlanıyor, göreli yollar, deterministik ZIP, ağ kapalı headless Chrome testi.
- **Film.** Süre bütçesi sunucuda; 600 sn üst sınır, dolgu yok; uzatma içeriği 14. bölümde.
- **Kalıcı güvenlik denetimi.** `99z_security_audit_test.sql` public şemadaki grant/RPC yüzeyini CI'da denetliyor; CI'da secret/service-role taraması var.
- **Repository disiplini.** İçerik repository'lerinde (anı, mektup, medya, ilk) mutation'lar `baby_id` + `id` ile sınırlandırılmış.

---

## 7. §8 Son değişmez kontrol listesi

| Madde | Durum | Not |
|---|---|---|
| 375 gün, tek uzatma 1–30 gün, tavan 405 | ✅ | Uzatmayı yalnız ebeveyn açabilmeli (P-6); şu an her üye açabiliyor (Y-3) |
| Europe/Istanbul server tarihi | ✅ | `run_daily_jobs` UTC (D-4, düşük) |
| ACTIVE iken Book/Film/HTML tüm katmanlarda kapalı | ✅ | Kapılar sunucu özetine bağlı |
| LOCKED iken kaynak mutation tüm katmanlarda kapalı | ✅ | |
| Uzatma dönemindeki içerik çıktılara dahil | ✅ (2026-10-02 düzeltmesiyle) | Kitap, Film ve HTML aynı efektif kapanış sınırını kullanıyor (Y-1, O-2) |
| Her route/sorgu/cache `(babyId, contentId)` | ✅ (2026-10-02, liste görünümleri hariç) | İçerik detayı, premium, form ve üye rotaları/işlemleri bebek kimliği taşıyor (Y-4); salt okuma liste ekranları seçili bebeği gösteriyor |
| Anne+Baba iki login, eşit hak, tek `family_account` aboneliği | ⚠️ | Abonelik ✅; "baby admin" kavramı ebeveyn dışına taşıyor (Y-2) |
| Plan fiyatları katalogdan, yıllık = aylık × 12 × 0,9 | ✅ | |
| Çoklu bebek fiyatı artırmıyor | ✅ | (statik) |
| Family Member kapasitesi server-side, ayrı abonelik yok | ✅ | Faz raporlarında yarış testleri var |
| Family Member yalnız izinli indirme | ✅ (P-12 ile değişti; 2026-10-02 uygulandı) | Aile üyeleri hiç indiremez ve çıktı ekranlarını görmez (Y-11) |
| 349/449/549 TL, ayrı entitlement | ✅ | |
| Fiziksel kitap ayrı ve sabit fiyatsız | ✅ | |
| Dört eksen ayrı | ✅ | |
| Re-download entitlement'ı silmiyor | ✅ | Bebek silinirse artifact silinir (Y-2) |
| BookComposer ve PDF yetenekleri korunmuş | ✅ | Tarih penceresi hariç |
| Film en fazla 10 dk, server doğrulamalı | ✅ | |
| HTML gerçekten offline | ✅ | Gerçek cihaz testi bekliyor |
| RLS + trigger/RPC + Storage guard birlikte | ✅ | |
| Super Admin ayrı ve audited | ✅ | |
| Legacy veri silinmeden raporlanıp karantinaya alınmış | ✅ | Cutoff kararı açık (P-1) |
| Migration/rollback/checkpoint/faz raporu hazır | ⚠️ | Faz 0 raporu yok, durum tablosunda hatalar var |
| Kardeş çıktı birleştirme kapsam dışı | ✅ | |

**Sonuç:** Bir madde ❌ (kritik) ve birkaç madde ⚠️. Plan §8'e göre sistem "tamamlanmış" sayılamaz.

---

## 8. Ürün kararları

### 8.1 Verilen kararlar (kullanıcı, 2026-10-02)

| No | Karar | Uygulamaya etkisi | Etkilenen bulgular |
|---|---|---|---|
| P-1 | **Resmî çıktı 375 gün; istenirse en fazla 30 gün uzatma ile en çok 405 gün.** Çıktı sınırı, her bebeğin kendi efektif kapanış tarihidir. | Snapshot cutoff `birth + 375 + approved_days` (yarı açık) olmalı; düz +405 hatalı. Kitap penceresi de aynı sınıra hizalanmalı. | O-2, Y-1 |
| P-2 | **Abonelik bittiğinde arşiv salt okunur olur.** | Okuma açık, yazma kapalı. Mevcut "tüm uygulama ödeme sayfasına kilitlenir" davranışı değişmeli. Premium satın alma, render ve indirme §2.7 gereği kapalı kalır. Lifecycle değişmez. | Y-6, P-2 |
| P-3 | **İki ebeveynin her biri bebeği silebilir.** | Silme yetkisi yalnız anne/baba (aktif parent). Her biri tek başına silebilir, ikinci onay aranmaz. | Y-2 |
| P-4 | **Verileri yalnız ebeveynler dışa aktarabilir** (P-7 ile netleşti: dışa aktarım = resmî çıktılar). | Çıktıları zaten yalnız ebeveyn üretir; ek iş yok. | Y-6 |
| P-5 | **Yönetici yalnız anne ve babadır; ikisi eşit hak ve yetkiye sahiptir.** | Ebeveyn olmayan yönetici kavramı kaldırılır: veritabanı kuralı, davet/kabul/kardeşten ekleme yolları, UI anahtarı ve mevcut verinin raporlanıp indirilmesi. Hesap silmede akrabaya yöneticilik verilmez. | Y-2, Y-8 |
| P-6 | **Uzatma talebini yalnız ebeveynler açabilir.** | `request_baby_extension` ve `can_request_extension` ebeveyne bağlanır; ret hak tüketmeden yapılır. | Y-3 |
| P-7 | **Genel bir dışa aktarım yoktur. Veri yalnız bebeğin Film, HTML ve Kitap çıktısı olarak alınır; bunların kuralları zaten bellidir. Aile üyelerinin mektupları bu çıktılara dahildir.** | Ayrı export uç noktası yapılmaz. Runbook ve GELISTIRME.MD'deki export ifadeleri düzeltilir. KVKK erişim talebi süreci hukukça onaylanmalı. | Y-6 |
| P-8 | **Bir ebeveyn hesabını silerse diğeri tek yönetici kalır. Silinen ebeveyn başka hesapla dönmek isterse yalnız kalan ebeveynin onayıyla girer.** | Halef yalnız diğer ebeveyn; ebeveyn koltuğu boşalır; anne/baba davetini yalnız ebeveyn oluşturabilir. | Y-8, Y-9 |
| P-9 | **Hiçbir ebeveyn diğer ebeveyni aileden çıkaramaz.** | Ebeveyn üyeliği ve yöneticiliği başka bir ebeveyn tarafından silinemez veya düşürülemez; yalnız kişinin kendisi veya audited destek süreci sonlandırabilir. | Y-9 |
| P-10 | **Ailede tek ebeveyn varsa bu ebeveyn hesabını silemez; önce mevcut bebekleri silmelidir.** | `prepare_account_deletion` otomatik bebek silmeyi ve halef yükseltmeyi bırakır; tek ebeveynli bebek varsa reddeder. Arayüz önce bebek silmeye yönlendirir. | Y-8 |
| P-11 | **Çıktılarda adı geçen her kişi aynı biçimde yazılır: "Esra Teyzesi", "Ahmet Amcası".** | HTML, Kitap ve Film için tek ortak "Ad + yakınlık" biçimi; ürün satışı açılmadan önce. | Y-10 |
| P-12 | **Film, Kitap ve HTML'i yalnız ebeveynler indirebilir; aile üyeleri indiremez. Uygulama veriyi üçüncü kişilere dağıtmaz; ebeveyn indirdiği çıktıyı isterse kendisi paylaşır.** Gerekçe: bebeğin yasal temsilcileri ve varisleri ebeveynlerdir. | Faz 12'nin aile üyesi indirme özelliği ve izin ekranı kaldırılır. Plan §2.7 ve Faz 12'nin aile üyesi maddeleri geçersizleşir. | Y-11 |
| P-13 | **Y-11 çözüm planı onaylandı:** (1) `member_downloads` bayrağı hemen kapatılır; (2) aile üyesi indirme yolu ileri migration ile kalıcı kapatılır, mevcut izinler silinmeden audit ile iptal edilir; (3) izin ekranı ve aile üyesi çıktı görünümü kaldırılır; (4) medyadaki "Paylaş / kaydet" düğmesi yalnız ebeveynlere açık kalır. | Uygulama, kullanıcı kod değişikliğine açıkça izin verdiğinde ayrı, tek amaçlı commit'lerle yapılır. | Y-11 |

**Yorum notu:** Kararlar aşağıdaki gibi yorumlandı. Farklı bir niyet varsa düzeltilmeli.
- P-1: "en fazla 405", yalnız 30 gün uzatma onaylanmış bebek için geçerlidir. Uzatmasız bebekte resmî çıktı 375. günün başlangıcında biter.
- P-2: Salt okunur kural Family Member'lar dahil tüm aile için geçerlidir. Plan §2.5.2, Family Member erişimini aktif aboneliğe bağlıyor; bu karar o maddeyi okuma için gevşetiyor.
- P-3 + P-5: "Ebeveyn" = bebeğe `anne` veya `baba` ilişkisiyle bağlı, en fazla iki aktif kişi. Bu iki kişi dışında hiç kimse yönetici değildir.
- P-10: "Tek ebeveyn", ilgili bebekte başka aktif anne/baba bulunmaması demektir. İki ebeveynli bebeklerde hesap silme P-8'e göre serbesttir.
- P-11: Kural ebeveynler dahil herkese uygulanır ("Elif Annesi", "Mert Babası").
- P-12: Aile üyeleri çıktı ekranlarına (Kitap, Film, Arşiv) hiç erişmez. Uygulama içinde görüntüleme de dosyanın cihaza indirilmesini gerektirdiği için kapsam dışıdır.
- P-5: Mevcut ebeveyn olmayan yöneticiler (varsa) audit kaydıyla normal üyeye indirilir. Bu, plan §2.5.3'teki "permission'lar sessizce değiştirilmez" ilkesine uygun olarak raporlanarak ve bildirimle yapılmalıdır.

**Doküman:** Plan §0'a göre bu kararlar GELISTIRME.MD'deki eski metnin önüne geçer: Faz 13 legacy politikasındaki "405 gün sonrası", §2.3, §2.7 ve §3.6. Tutarlılık için GELISTIRME.MD'ye bir "Karar kaydı (2026-10-02)" bölümü eklenmesi önerilir. Bu inceleme kapsamında GELISTIRME.MD değiştirilmedi.

### 8.2 Açık kalanlar

Bu raporun sorduğu tüm ürün kararları verildi (son olarak P-13). Kalanlar yalnız onay ve doküman işleri:
1. **Hukuk teyidi:** P-12 gerekçesinin aydınlatma metnine yazılması ve silinen bebekte sipariş kayıtlarının saklama süresi.
2. ~~**GELISTIRME.MD karar kaydı**~~ **Yapıldı (2026-10-02):** P-1…P-13, GELISTIRME.MD'de "Karar kaydı (2026-10-02)" bölümünde.

---

## 9. Önerilen düzeltme sırası

1. ~~**Y-3 (P-6 kararı)** Uzatma talebini yalnız ebeveyne açmak.~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).**
2. ~~**Y-2 + Y-8 + Y-9 (P-3/P-5/P-8/P-9/P-10 kararları)** Ebeveyn yetki modelini tek pakette düzeltmek.~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).** Kapsam:
   - **Yönetici kuralı:** Yöneticiliği yalnız anne/baba'ya sınırlamak. Önce mevcut veriyi dry-run ile raporlamak, ebeveyn olmayan yöneticileri audit kaydıyla indirmek, sonra veritabanı kuralı eklemek.
   - **Çıkarma yasağı:** Bir ebeveynin diğerini çıkarmasını veya yöneticiliğini düşürmesini yasaklamak.
   - **Ebeveyn daveti:** `anne`/`baba` davetini yalnız ebeveyne açmak.
   - **Hesap silme:** Halef yalnız diğer ebeveyn olsun; ebeveyn koltuğu boşalsın. Tek ebeveyn, bebekleri silmeden hesabını silemesin (P-10); bebekler otomatik silinmesin.
   - **Bebek silme:** Her ebeveynin tek başına yapabileceği şekilde ebeveyne bağlamak.
   - **Arayüz:** Yönetici ve çıkarma aksiyonlarını kısıtlamak.
3. ~~**O-2 + Y-1 (P-1 kararı)** Snapshot cutoff'u ve kitap aday penceresini aynı efektif kapanış sınırına (`birth + 375 + approved_days`, yarı açık) bağlamak; rollout raporu ve 99r testini güncellemek.~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).**
4. ~~**Y-6 (P-2 kararı)** Abonelik kapısını okumadan çıkarıp yalnız yazmaya uygulamak; router/paywall'u salt okunur deneyime çevirmek; RLS ve widget testleri.~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).**
5. ~~**Y-5** Finalize akışını `verified` durumundan idempotent devam edecek hale getirmek.~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).**
6. ~~**O-1** Medya tarih guard'ı (önce dry-run raporu).~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).**
7. ~~**Y-4** Premium rotalarına `babyId`; formlarda bebeği sabitlemek; kitap ve üye mutation'larına `baby_id` filtresi.~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).**
8. ~~**Y-11 (P-12/P-13, onaylı plan)**~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).** Hemen: tüm ortamlarda `member_downloads` bayrağını kapatmak (kod gerektirmez). Ardından ileri migration ile aile üyesi indirme yolunu kalıcı olarak kapatmak (izinler audit ile iptal), izin ekranını ve aile üyesi çıktı görünümünü kaldırmak, "Paylaş / kaydet" düğmesini yalnız ebeveynlere göstermek.
9. ~~**Y-10 (P-11 kararı)**~~ **Yapıldı ve doğrulandı (2026-10-02, ayrı commit).** HTML, Kitap ve Film için ortak "Ad + yakınlık" biçimi ve test vektörleri. Satış açılmadan önce yapılmalı. **Y-6 (P-7):** export yapılmaz; runbook ve GELISTIRME.MD metinleri düzeltilir.
10. ~~**O-3** CI'a Edge job'ı; **O-5** Docker lock ve Deno sürüm sabitleme; **O-4** demo hesap ve seed go-live kontrolü.~~ **Yapıldı (2026-10-02, ayrı commit olarak işlendi; Docker imaj derlemesi ortamda doğrulanmalı).**
11. ~~**O-7/O-8** Dokümanları, `PHASE_STATUS.md`'yi ve GELISTIRME.MD'yi eşitlemek (2026-10-02 karar kaydı dahil); geriye dönük Faz 0 raporu.~~ **Yapıldı (2026-10-02, ayrı commit).**
12. ~~**D-1, D-3, D-4, D-5, D-6** küçük sağlamlaştırmalar.~~ **D-1, D-3, D-4 (tarih), D-5 (hata metni) yapıldı (2026-10-02, ayrı commit); D-6 (`x` dosyası) kullanıcı onayıyla silindi.**
13. **Y-7/O-9** Staging rollout, sandbox ödeme, gerçek cihaz testleri, yedek/geri yükleme, kill switch, pentest, OSV.
14. Tüm kanıtlar kaydedildikten sonra Faz 13 → `COMPLETE` ve `first-year-lifecycle-v1` etiketi.

Plan §5 kuralı gereği, Y-1/Y-2/Y-3 düzeltmeleri tamamlanmış fazlara dokunduğu için her biri **ayrı, tek amaçlı commit** ve yeni ileri migration olarak yapılmalı; tarihsel migration'lar düzenlenmemeli.

---

## 10. Sonuç

Mimari ve backend güvenliği, sıradan bir prototipin belirgin şekilde üzerinde. Lifecycle çekirdeği, RLS/Storage kilidi, fiyat kataloğu ve çıktı hattı master planla büyük ölçüde örtüşüyor. Buna karşılık **kitap tarih penceresi**, **ebeveyn dışı yöneticinin silme yetkisi** ve **uzatma hakkının herhangi bir üyece tüketilebilmesi**, testlerin yakalamadığı ama doğrudan para ve geri dönüşsüz veri ile ilgili sözleşme ihlalleri. Bunlar ve Faz 13 ortam kapıları kapanmadan üretime çıkılmamalı.

> **Doğru statü:** Repo içi uygulamanın büyük bölümü tamamlanmış, ancak üç yüksek önemli sözleşme ihlali, açık ürün kararları ve ortam go-live kapıları nedeniyle üretime hazır olmayan bir release adayı.

---

*Claude notu: 2026-10-01 incelemesi salt okunurdu; bu dosya kullanıcının açık talebiyle oluşturuldu. 2026-10-02'deki düzeltmeler kullanıcının açık onayıyla yapıldı ve ayrı commit'ler olarak işlendi.*
