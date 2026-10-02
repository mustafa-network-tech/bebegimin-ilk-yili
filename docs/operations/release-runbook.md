# Üretim açılışı runbook'u (Faz 13)

Bu belge yeni yaşam döngüsü ve premium çıktı modelinin **mevcut veriyi kaybetmeden**, metriklerle ve geri dönülebilir biçimde açılmasını anlatır. Repo içindeki tüm kontroller hazırdır. Aşağıdaki adımlar staging ve production ortamında, yetkili bir operatör tarafından uygulanır.

İlgili belgeler: [output-pipeline-setup.md](output-pipeline-setup.md), [output-worker-setup.md](output-worker-setup.md), [book-artifacts-setup.md](book-artifacts-setup.md), [artifact-download-policy.md](artifact-download-policy.md), [store-billing-setup.md](store-billing-setup.md), [super-admin-roles.md](super-admin-roles.md).

## 0. Ön koşullar

- [ ] Staging projesi production'a benzer veri hacmiyle hazır (production'ın anonimleştirilmiş kopyası veya `supabase/tests/perf/volume_check.sql` hacmi).
- [ ] App Store ve Google Play sandbox ürünleri tanımlı (abonelik + üç premium ürün; bkz. store-billing-setup).
- [ ] Çıktı worker'ı (`workers/output`) staging'de çalışıyor.
- [ ] En az iki Super Admin hesabı var (bkz. super-admin-roles).
- [ ] Yedekleme (PITR) açık; son yedeğin zamanı biliniyor.

## 1. Açılış öncesi kill switch durumu

Migration'lar uygulanırken satış ve yeni üretim kapalı tutulur:

```sql
update public.platform_flags set enabled = false, note = 'rollout: kapalı başlangıç'
 where key in ('premium_storefront', 'book_renderer', 'film_renderer', 'html_renderer', 'member_downloads');
```

`output_worker` açık kalabilir; kuyrukta iş yoktur.

## 2. Migration ve shadow (salt okuma) hesaplama

1. Migration'ları sırayla uygulayın (`supabase db push`). Tarihsel migration'lar değiştirilmez.
2. Super Admin olarak salt okuma raporlarını alın ve kaydedin:
   ```sql
   select public.admin_legacy_rollout_report();   -- LOCKED olan bebekler, kapanış tarihi sonrası içerik (karar P-1), legacy kitap, orphan dosya, eşleşmeyen bebek
   select * from public.admin_legacy_book_report(); -- karantinadaki eski kitap proje / export'ları
   select public.admin_parent_authority_report(); -- ebeveyn olmayan yönetici kalan bebekler, yöneticisiz Anne/Baba (karar P-5)
   select public.admin_media_date_report();       -- çekim tarihi geçersiz eski medya (doğum - 310 gün öncesi / gelecek); yalnız raporlanır
   select * from public.admin_release_health();     -- tüm kontroller "ok" olmalı
   ```
3. **Mutabakat:** `babies_total`, staging'deki bebek sayısıyla birebir tutmalı. `unmapped_babies` ve `users_parent_in_several_accounts` listeleri **otomatik birleştirilmez**. Her biri destek ekibiyle tek tek çözülür veya onaylı istisna listesine yazılır.
4. **Orphan dosyalar** (`orphan_media_sample`) silinmez. Örnekler elle doğrulanır; gerçekten sahipsiz olduğu kanıtlanan dosyalar ayrı bir değişiklik kaydıyla temizlenir.
5. **405 gün sonrası legacy içerik** (`post_cutoff_content`) silinmez ve resmî çıktılara girmez. Aile talep ederse Super Admin gerekçeli karar kaydeder:
   ```sql
   select public.admin_set_legacy_grandfather('<baby_id>', true, 'Destek talebi #… : gerekçe');
   ```
   Karar `legacy_grandfather_decisions` ve `activity_logs` içinde denetim kaydı bırakır; geri almak için `false` ile yeni karar yazılır.

Backfill gerekmez: lifecycle her istekte hesaplanır. 375 günü geçmiş bebekler migration anında otomatik LOCKED olur ve raporda listelenir.

## 3. Kademeli açılış

| Aşama | Ne açılır | Süre / çıkış ölçütü |
|---|---|---|
| A. Internal | Ekip hesaplarıyla sandbox satın alma, üç ürün üretimi, indirme, paylaşım | Tüm akışlar başarılı; `admin_release_health` = ok |
| B. Küçük cohort | Seçili aileler (TestFlight / dahili test kanalı) | 7 gün; poison iş ≤ 3/gün, checksum hatası 0, webhook reddi ≤ 5/gün |
| C. Kademeli | Mağaza aşamalı yayın %5 → %25 → %50 → %100 | Her adımda 48 saat metrik izleme |

Her aşamada açılış sırası: `premium_storefront` → `book_renderer` → `film_renderer` → `html_renderer` → `member_downloads`. Sorun görülürse ilgili bayrak hemen kapatılır (veri kaybı yok).

## 4. Metrikler ve alarmlar

`admin_release_health()` en az 5 dakikada bir izlenir. Önerilen alarmlar:

| Kontrol | Uyarı | Kritik | İlk müdahale |
|---|---|---|---|
| `lifecycle_mismatch` | — | > 0 | Satışı kapat, veriyi incele (normal API ile oluşamaz) |
| `output_queue_age_minutes` | > 30 | > 120 | Worker'ın çalıştığını ve `output_worker` bayrağını kontrol et |
| `output_jobs_poison_24h` | > 3 | > 10 | `admin_output_metrics()` hata kodlarına bak |
| `artifact_checksum_failures_24h` | > 0 | > 5 | Worker / Storage bütünlüğü; ilgili ürün bayrağını kapat |
| `download_denials_1h` | > 100 | > 500 | `admin_download_audit()` nedenleri; olası kötüye kullanım |
| `payment_webhook_rejections_24h` | > 5 | > 20 | Mağaza imza / ürün eşlemesi; `billing_events.error` |
| `payment_webhook_silence_hours` | > 48 (aktif ücretli abonelik varken) | — | Mağaza bildirim URL'leri ve secret'lar |
| `storage_cleanup_backlog` | > 1000 | — | `storage-cleanup` zamanlamasını kontrol et |
| `subscriptions_over_capacity` | > 0 | — | Destek: aileye üye düzenlemesi önerilir |

**Reddedilen yazmalar** (LOCKED arşive yazma denemeleri) veritabanına kaydedilmez, çünkü reddedilen işlem geri alınır. Bunlar PostgREST / API loglarında `hint = lifecycle_locked` ile sayılır. Loglama platformunda bu hint için bir sayaç tanımlayın; ani artış eski bir istemci sürümüne işaret eder (bkz. §7).

## 5. Kill switch tatbikatı (go-live kapısı)

Staging'de, her bayrak için:

1. Bayrağı kapatın, ilgili isteğin beklenen hint ile reddedildiğini doğrulayın (`book_renderer_disabled`, `film_renderer_disabled`, `html_renderer_disabled`, `member_downloads_disabled`, `storefront_closed`).
2. Mevcut hazır dosyaların ebeveyn tarafından indirilebildiğini doğrulayın (veri kaybı yok).
3. Bayrağı açın, akışın kaldığı yerden sürdüğünü doğrulayın.
4. `output_worker` kapalıyken kuyruğun beklediğini, açılınca işlendiğini doğrulayın.

Sonuçları tarih ve operatör adıyla bu belgenin sonuna ekleyin.

## 6. Yedek, geri yükleme ve felaket kurtarma

- **Tatbikat (go-live kapısı):** Staging yedeğini yeni bir projeye geri yükleyin. Ardından `run_db_tests.sh` kabul paketinin şema ile uyumlu olduğunu ve `admin_legacy_rollout_report()` sayılarının kaynakla aynı olduğunu doğrulayın.
- **Storage:** Bucket'lar ayrı yedeklenmelidir (Supabase veritabanı yedeği Storage nesnelerini içermez). Çıktı dosyaları yeniden üretilebilir; kaynak medya (`baby-media`) üretilemez ve öncelikli yedektir.
- **RPO / RTO hedefi:** veritabanı için PITR ile ≤ 5 dk veri kaybı, ≤ 4 saat geri dönüş. Hedefler işletme tarafından onaylanmalıdır.
- **Felaket sırasında:** tüm üretim bayraklarını kapatın (§1), uygulamaya bakım mesajı göstermek gerekirse `client_min_build` geçici olarak yükseltilebilir (§7).

## 7. Eski istemci sürümleri

- Sunucu her kuralı kendisi uygular; eski sürümler yeni politikayı aşamaz, yalnızca anlaşılır hata alır (ör. eski kitap yayını `book_export_requires_artifact`).
- Zorunlu güncelleme: sürüm yayınlanırken `--dart-define=APP_BUILD=<build>` verilir. Gerekirse:
  ```sql
  update public.platform_settings set value = '<min build>', updated_at = now() where key = 'client_min_build';
  ```
  Altındaki sürümler güvenli "Güncelleme gerekiyor" ekranı gösterir (çevrimdışıyken uygulama kilitlenmez).

## 8. Gizlilik

- Hesap ve bebek silme `privacy-actions` Edge Function'ı ile, normal kullanıcı yetkisinden ayrı, servis yolu üzerinden yapılır. Kaynak medya, legacy kitap dosyaları ve profil dosyaları silinir.
- Çıktı artifact'ları, siparişler ve ödeme olayları yasal saklama gereği `on delete restrict` ile korunur. Bebek silme talebinde bu kayıtlar için ayrı bir **saklama / anonimleştirme kararı** alınmalıdır (hukuk onayı gerekir; bkz. bilinen riskler).
- KVKK veri dışa aktarımı: Offline HTML arşivi kullanıcıya verinin taşınabilir kopyasını sağlar; ayrıca destek ekibi Super Admin araçlarıyla aile verisini dışa aktarabilir.

## 9. Kotalar ve maliyet

- Çıktı işleri: bebek + ürün başına 24 saatte Kitap 30, Film 12, HTML 6 (`platform_settings.output_daily_quota`). Aşımda `quota_exceeded`.
- İndirme: dosya başına 10 dakikada 10, kullanıcı başına 30 bağlantı.
- Storage: `baby-media` ve `output-artifacts` bucket dosya boyutu sınırları; arşiv paketi en çok 2 GB.
- Worker: konteyner başına bir iş; kapasite konteyner sayısıyla ölçeklenir.

## 10. Go-live kapıları

- [ ] Kritik / yüksek güvenlik bulgusu yok (repo içi denetim `99z_security_audit_test.sql` + bağımsız saldırı testi raporu).
- [ ] Veri mutabakatı %100 veya onaylı istisna listesi (§2).
- [ ] Ödeme webhook / makbuz idempotency'si sandbox'ta kanıtlı (aynı olayın iki kez gelmesi tek etki).
- [ ] Kill switch tatbikatı başarılı (§5).
- [ ] Yedek / geri yükleme tatbikatı başarılı (§6).
- [ ] Destek / admin runbook'u ve destek metinleri hazır ([../support/support-texts.md](../support/support-texts.md)).
- [ ] Fiyat ve lifecycle semantiği kullanıcı onayı olmadan değişmedi (katalog: 34900 / 44900 / 54900; planlar 29900 / 36900 / 46900 aylık).
- [ ] Production veritabanında `admin_release_health()` → `demo_accounts` = `ok` (0). `supabase/seed.sql` production'a hiçbir zaman uygulanmaz; demo hesaplarının şifresi açıktır.
- [ ] Mağaza sürümleri `DEMO_MODE` kapalı derlenir (`--dart-define-from-file` ile verilen dosyada `DEMO_MODE` yok veya `false`).
- [ ] Output worker imajı `deno.lock` ile ve CI'daki Deno sürümüyle (`DENO_VERSION`) derlendi (`deno cache --frozen`).

Hepsi işaretlenince `PHASE_STATUS.md` içinde Faz 13 `COMPLETE` yapılır ve `first-year-lifecycle-v1` etiketi atılır.

## Tatbikat kayıtları

| Tarih | Ortam | Tatbikat | Sonuç | Operatör |
|---|---|---|---|---|
| | | | | |
