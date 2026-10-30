# Google Play abonelik yenileme ve iade kontrolü (RTDN olmadan)

Bu belge `billing-reconcile` Edge Function'ının kurulumunu, açılışını ve geri alınmasını anlatır.
RTDN / Pub/Sub kurulu değilken yenileme, iptal, askıya alma, süre dolması ve iadeleri sunucu
tarafında zamanlanmış kontrolle yakalar. RTDN ileride eklenirse bu sistem **yedek doğrulama**
olarak çalışmaya devam eder (aynı `billing_apply_event` / `premium_apply_event` RPC'leri kullanılır).

> **Hiçbir adım otomatik değildir.** Migration, secret, deploy ve zamanlayıcı ayrı ayrı, bu
> sırayla ve onayla yapılır. Zamanlayıcı kurulana ve bayrak açılana kadar sistem hiçbir şey yapmaz.

## 1. Ne yapar?

| Akış | Kaynak | Sonuç |
|---|---|---|
| Abonelik durumu | `purchases.subscriptionsv2.get` (vadesi gelen abonelikler) | `billing_apply_event` |
| Sunucu tarafı onay (acknowledge) | `purchases.subscriptions.acknowledge` | `billing_reconcile_state.ack_*` |
| İade / geri alma | `purchases.voidedpurchases.list` (saatte bir) | `billing_apply_event` / `premium_apply_event` |

Kurallar:

- Yalnızca Google'ın **açık** durumu erişim kapatabilir (`EXPIRED`, `ON_HOLD`, `PAUSED`). API
  hatası (401/403/404/410/429/5xx, zaman aşımı), bilinmeyen durum veya eksik alan **hiçbir şeyi
  değiştirmez**; yalnızca yeniden deneme ertelenir (15 dk → 1 sa → 4 sa → en çok 24 sa).
- Erişimin kapanması (“downgrade”) devre kesiciden geçer (bkz. 5).
- Play üzerinden plan değişimi (`replacementCancellation`) süre dolması sayılmaz; yeni jeton
  uygulamanın otomatik geri yüklemesiyle bağlanır (`previous_provider_subscription_id`).
- Onay (acknowledge) yalnızca sunucuda hak kayıtlıyken ve çalışan bir abonelik için yapılır;
  uygulama önce davranabilsin diye ilk görüşten **15 dk** sonra. Onay sonucu hak verme sonucundan
  ayrı izlenir. Tek seferlik ürünlerde mevcut onay/consume davranışı (Flutter) değişmedi.
- 2 gün erişim toleransı: yalnızca `trialing`/`active` durumunda ve dönem sonundan sonra
  (`subscription_grants_access`). `past_due` (askı/duraklatma), `expired` (iade, geri alma,
  bitiş) ve `canceled` hiçbir tolerans almaz.

## 2. Hazırlık (sırayla; her adım ayrı onay)

1. **Migration** `supabase/migrations/20261029000100_billing_reconcile.sql`
   (rollback: `supabase/rollbacks/20261029000100_billing_reconcile.down.sql`).
   Önce `20261028000100_billing_event_retry.sql` uygulanmış olmalıdır. Migration yalnızca tablo,
   fonksiyon ve iki bayrak ekler (`billing_reconcile` **kapalı**, `billing_reconcile_dry_run`
   **açık**) ve erişim toleransını 1 günden 2 güne çıkarır. Abonelik/ödeme satırlarına dokunmaz.
2. **Secret'lar** (Supabase → Edge Functions → Secrets; değerleri kimseye göstermeyin):
   - `BILLING_RECONCILE_SECRET` — yeni, uzun rastgele bir değer.
   - Zaten var olanlar: `GOOGLE_PLAY_PACKAGE_NAME`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`.
   - İsteğe bağlı ayarlar (varsayılanlar parantezde): `RECONCILE_MAX_CHECKS` (40),
     `RECONCILE_MAX_DOWNGRADES_PER_RUN` (10), `RECONCILE_MAX_DOWNGRADE_RATIO` (0.2),
     `RECONCILE_RATIO_MIN_CHECKED` (20), `RECONCILE_MAX_DOWNGRADES_PER_HOUR` (20).
3. **Google tarafı**: servis hesabında Play Console'da “Siparişleri ve abonelikleri yönet” ve
   “Finansal verileri görüntüle” izinleri olmalı (voided purchases için gerekli); Google Cloud'da
   *Google Play Android Developer API* etkin olmalı. Play Console ayarlarını bu belge değiştirmez.
4. **Edge Function deploy** (jetonsuz çağrılır, secret ile korunur):
   `supabase functions deploy billing-reconcile --no-verify-jwt`
   (`supabase/config.toml` içinde `verify_jwt = false` tanımlıdır).
5. **Vault'a secret** (zamanlayıcı başlığı için; SQL Editor'da, değeri kendiniz yazın):
   ```sql
   select vault.create_secret('<BILLING_RECONCILE_SECRET ile aynı değer>', 'billing_reconcile_secret');
   ```

## 3. Önce deneme (dry-run), sonra canlı

Zamanlayıcı **migration'a konmaz** (CI'daki PostgreSQL'de `pg_cron` yok). SQL Editor'da elle:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'billing-reconcile',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://<PROJE-REF>.supabase.co/functions/v1/billing-reconcile',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-reconcile-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'billing_reconcile_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 110000
  );
  $$
);
```

1. Bayrağı aç, dry-run **açık kalsın** (varsayılan): sistem okur, hesaplar, sayaç yazar; hak değiştirmez.
   ```sql
   update public.platform_flags set enabled = true where key = 'billing_reconcile';
   ```
2. En az bir gün izleyin: `select public.billing_reconcile_health();` ve son çalışma
   (`billing_reconcile_runs`). Dry-run'da `codes` içinde `would_change` / `would_downgrade` /
   `would_refund` sayıları görünür; gerçek durumla uyuştuğundan emin olun.
3. Canlıya geçiş: `update public.platform_flags set enabled = false where key = 'billing_reconcile_dry_run';`

## 4. İzleme

`select public.billing_reconcile_health();` (yalnızca service role; jeton/kullanıcı verisi içermez):

| Alan | Anlamı | Aksiyon |
|---|---|---|
| `overdue_1h` | Kontrol zamanı 1 saatten fazla geçmiş abonelik | Zamanlayıcı/Function çalışmıyor |
| `failing` | Art arda hata alan abonelik | `last_error_code` (`google_401/403/404`, `temporary_error`…) |
| `ack_pending`, `ack_failed` | Onaylanmamış/başarısız | `ack_at_risk_24h` > 0 ise acil: Google 3 gün sonra iade eder |
| `last_run` | Son çalışmanın sayaçları | `blocked: true` = devre kesici devrede |

Önemli `codes`: `circuit_per_run|ratio|per_hour` (devre kesici), `downgrade_blocked`,
`replaced` (plan değişimi bekliyor), `voided_gap` (iade imleci 29 günden eski: kayıt kaçmış
olabilir), `voided_truncated` (10 sayfadan fazla), `voided_unknown` (bizim doğrulamadığımız
satın alma, yok sayıldı), `ack_google_403` (servis hesabı onay izni yok).

## 5. Devre kesici

Bir çalışmada kapatılacak (erişim kaybedecek) abonelik sayısı `RECONCILE_MAX_DOWNGRADES_PER_RUN`'u
aşarsa, parti ≥ 20 abonelikse oranı (`…_RATIO`) aşarsa veya son 60 dakikadaki uygulanmış kapatmalarla
birlikte `…_PER_HOUR`'u aşarsa, **o çalışmadaki hiçbir kapatma uygulanmaz** (yenilemeler ve diğer
güncellemeler uygulanır). Kayıtlar 15 dk sonra yeniden denenir. Tetiklenirse önce nedeni inceleyin
(Google hatası mı, gerçek toplu iade mi); gerçek ise ilgili eşiği geçici yükseltin.

## 6. Kapatma ve geri alma

Hızlı kapatma (veri değişmez):
```sql
update public.platform_flags set enabled = false where key = 'billing_reconcile';
select cron.unschedule('billing-reconcile');
```
Tam geri alma: yukarıdakiler → Function'ı silin → `supabase/rollbacks/20261029000100_billing_reconcile.down.sql`.
Geri alma toleransı 1 güne döndürür; abonelik, ödeme ve sipariş kayıtlarına dokunmaz.

## 7. Bilinen sınırlar

- Play içinden plan değişiminde yeni jetonu sunucu kendi başına bulamaz (Google eskiden yeniye işaret
  etmez); uygulamanın otomatik geri yüklemesi (açılış / ön plana gelme, 6 saatte en çok bir kez,
  yalnızca ebeveyn) yeni jetonu doğrulatır.
- Voided purchases yalnızca ~30 gün saklanır; zamanlayıcı bundan uzun durursa kaçan iadeler
  görünmez (`voided_gap`).
- Tek seferlik ürünlerin satın alma jetonu saklanmadığından onayları sunucuda değil, uygulamada yapılır.
- Yönetim paneli sayaçları (`admin_*`) hâlâ 1 günlük toleransı sayar; yalnızca raporlamayı etkiler,
  erişim kararı `subscription_grants_access` ile verilir.
