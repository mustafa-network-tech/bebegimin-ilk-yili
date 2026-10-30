# Kullanıcı hareketi ve abonelik dönüşüm izleme

Operasyonel amaçlıdır (ödeme sorunlarını çözmek, hizmet güvenliği, dönüşüm sayıları). Reklam, profilleme veya üçüncü taraf paylaşımı için kullanılmaz.

Migration: `supabase/migrations/20261030000100_user_event_tracking.sql`
Rollback: `supabase/rollbacks/20261030000100_user_event_tracking.down.sql` (yalnızca izleme nesnelerini siler).

## Ne kaydedilir

`public.user_events`: olay türü, kullanıcı UUID veya aile hesabı UUID, zaman, platform, paket kodu, ürün türü, durum ve güvenli hata kodu. Serbest metin, JSON, token, makbuz, e-posta, bebek veya içerik verisi **yoktur**; sütunlar CHECK listeleriyle sınırlıdır.

## Yazma yolları (kullanıcı kimliği sorunu)

| Kaynak | Yol | Kullanıcı kimliği |
|---|---|---|
| Kayıt, e-posta doğrulama, ilk giriş, aile, bebek bağlantısı | Veritabanı tetikleyicileri → dahili `user_events_write` | Satırın kendisinden (`new.id`, `created_by`) |
| Abonelik etkinleşme / iptal / süre dolumu | Tetikleyici (`subscriptions`) | **Aile hesabı** kapsamlı (kullanıcı bilinmez) |
| Ödeme doğrulama aşamaları | `billing-verify-purchase` → `record_server_user_event` (yalnız `service_role`) | Doğrulanmış JWT'den gelen kullanıcı, açıkça iletilir |
| Flutter olayları | **Henüz yok** (2. aşama) | `auth.uid()` ile ayrı bir RPC olacak |

`auth.uid()` service role altında yoktur; bu yüzden sunucu olayları ayrı, yalnızca `service_role`'ün çağırabileceği bir RPC ile yazılır. Hiçbir API rolü (`anon`, `authenticated`) tabloyu okuyamaz veya yazamaz; okuma yalnızca Super Admin RPC'leri iledir.

## Ödeme hatası kaydı: güvenilirlik

`_shared/user_events.ts` içindeki `recordUserEvent`:
- Yanıt dönmeden önce **beklenir** (fire-and-forget değildir).
- Hiçbir koşulda **fırlatmaz**; RPC hatası, istisna ve 2 sn zaman aşımı yutulur, yalnızca güvenli kod loglanır.
- Satın alma kararını **değiştirmez**.
- Tetikleyiciler de hata yutar: kayıt/giriş/satın alma hiçbir zaman izleme yüzünden engellenmez.

## İki ayrı sorun durumu

| Durum | Anlamı |
|---|---|
| `paid_not_activated` | Mağazanın kendisi ödemeyi onayladı (`payment_verified`), ancak aile hesabında erişim/hak yok ve sonradan `activation_granted` kaydı yok. |
| `verification_failed` | Mağaza sorgulanamadı veya reddetti (`store_verification_failed`). Ödemenin alınıp alınmadığı **bilinmez**. Sonraki başarılı doğrulama ile kapanır. |

## Geçmiş veriler

Migration anında `user_event_meta.tracking_started` yazılır. Bu tarihten önceki hareketler yalnızca mevcut tablolardan (kayıt tarihi, aile, bebek bağlantısı, ödeme niyeti, abonelik) ve "Mevcut kayıttan" etiketiyle gösterilir. Paket görüntüleme, ilk giriş, vazgeçme ve RPC'ye ulaşmayan doğrulama hataları geçmiş için **üretilmez**. Eski reddedilen `billing_events` satırları aile hesabına bağlı olmadığı için kullanıcıya atfedilemez.

## Saklama

Tasarım hedefi **13 ay** (KVKK değerlendirmesi ve saklama politikası onayı sonrası kesinleşir). `public.purge_user_events(interval '13 months')` yalnızca `service_role` ile çalışır ve **zamanlanmamıştır**. Zamanlama onaydan sonra, billing-reconcile ile aynı yöntemle elle kurulur:

```sql
-- Supabase SQL editor (onaydan sonra); haftalık
select cron.schedule('purge-user-events', '17 3 * * 1', $$select public.purge_user_events(interval '13 months')$$);
```

Hesap silinince (`auth.users`) kullanıcıya bağlı olaylar `ON DELETE CASCADE` ile silinir. Aile kapsamlı abonelik olayları kullanıcı kimliği taşımaz; saklama süresi sonunda silinir.

## Canlıya alma sırası (onaya bağlı)

1. Yerel/staging: tüm DB testleri, Deno testleri, admin-web typecheck (hazır).
2. Migration'ı canlıya uygula (**ayrı onay**).
3. `billing-verify-purchase` fonksiyonunu dağıt (**ayrı onay**).
4. Admin paneli Vercel dağıtımı (**ayrı onay**).
5. Flutter olayları ve yeni AAB: 2. aşama.
