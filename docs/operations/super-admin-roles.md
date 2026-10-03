# Super Admin rol yönetimi (operasyon süreci)

Platform Super Admin rolü, bir bebeğin aile yöneticisi (`family_members.is_admin`) rolünden tamamen ayrıdır. Aile yöneticiliği hiçbir zaman platform yetkisi vermez.

Rol atama ve kaldırma için uygulama içinde arayüz **yoktur**. İşlemler yalnızca aşağıdaki kontrollü süreçle, service role veya veritabanı sahibi olarak yapılır.

## Kurallar

- Talep yazılı olmalıdır: kim, neden, ne kadar süreyle. Talebi en az bir başka platform sorumlusu onaylamalıdır.
- Rol kişiye özeldir; ortak hesap kullanılmaz.
- Rol kaldırılırken satır silinmez; `revoked_at` doldurulur. Geçmiş ve denetim korunur.
- Her değişiklik `platform_role_events` tablosuna otomatik yazılır (trigger). İstemciler bu tabloyu okuyamaz.

## Rol verme

```sql
-- service role / SQL editor
insert into public.platform_user_roles (user_id, role, granted_by)
values ('<kullanıcı-uuid>', 'super_admin', '<onaylayan-uuid>');
```

## Rolü kaldırma

```sql
update public.platform_user_roles
   set revoked_at = now()
 where user_id = '<kullanıcı-uuid>' and role = 'super_admin' and revoked_at is null;
```

Kaldırma anında etkilidir: Her konsol RPC'si rolü veritabanından yeniden kontrol eder.

## Yeniden verme

```sql
update public.platform_user_roles
   set revoked_at = null, granted_by = '<onaylayan-uuid>', granted_at = now()
 where user_id = '<kullanıcı-uuid>' and role = 'super_admin';
```

## Denetim

```sql
select * from public.platform_role_events order by changed_at desc;
```

## Konsolu geçici kapatma (kill switch)

```sql
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'admin_console';
-- yeniden açmak için enabled = true
```

- Değişiklik `platform_flag_events` tablosuna yazılır.
- Kapalıyken konsol ekranları ve konsol RPC'leri (`admin_*`) reddedilir.
- Arşiv kilidi ve lifecycle etkilenmez.

## Hız sınırı

Her Super Admin için dakikada en fazla:

- 120 okuma: kuyruk, arama, önizleme, denetim
- 30 yazma: karar, doğum tarihi düzeltmesi

Aşımda `rate_limited` hatası döner.
