# 72 saatlik deneme, tam kilit ve Yeni Kayıtlar

Migration'lar: `20261030000200_access_trials_and_full_lock.sql`, `20261030000300_signup_followups_email_templates.sql`
Rollback: `supabase/rollbacks/` altındaki `.down.sql` dosyaları (önce 0300, sonra 0200).

## Erişim modeli

| Durum | Ana sayfa / okuma | Yazma (anı, fotoğraf, mektup, kapsül, bebek düzenleme) | Davet | Dijital ürünler |
|---|---|---|---|---|
| Aktif abonelik | ✓ | ✓ | ✓ (plan kapasitesi) | paket + hak |
| 72 saatlik deneme | ✓ | ✓ | ✓ (en küçük planın kapasitesi) | ✗ |
| Süresiz test erişimi | ✓ | ✓ | ✓ | ✓ |
| Paketsiz / deneme bitti / abonelik bitti | **✗ (tam kilit)** | ✗ | ✗ | ✗ |

- Kilitte yalnızca **bebek profil fotoğrafı** okunabilir (plan ekranı bebeği gösterebilsin) ve **üye çıkarma** açık kalır. Hiçbir veri silinmez.
- İlk kurulumda aile ve **ilk bebek** her zaman oluşturulabilir. Başka bir bebek için hak gerekir.
- Kural, tek yerden (`baby_subscription_ok` → `family_account_access_ok`) RLS, tetikleyici ve Storage'a işler.

## Karar P-2 geri alındı

Önceki karar ("biten abonelikte arşiv salt okunur") yerine **tam kilit** geldi. `plan_exempt` sütunu artık kapı tarafından kullanılmaz (sütun silinmedi).

## ⚠️ `subscription_enforcement` bayrağı

Bu migration'lar bayrağı **açmaz**. Canlıda bayrak kapalıyken (`enabled = false`) hiçbir kural çalışmaz ve herkes eskisi gibi tam erişimlidir. Bayrağı açmadan önce:

1. Yeni Flutter sürümü (deneme bilgisi ve tam kilit ekranı) yayınlanmış ve kullanıcıların çoğu güncellemiş olmalı. Eski uygulama kilitli aileyi "salt okunur arşiv" sanır ve hata gösterir.
2. Bugünkü aileler (8 aile, hiçbirinin aboneliği yok) açıldığı anda kilitlenir. Kalmasını istediğiniz her aile için önce **süresiz test erişimi** (`/test-erisimleri`) veya **deneme** (`/kullanicilar/<id>`) verin.
3. Ödeme akışı (Google Play) gerçek bir test satın almasıyla doğrulanmış olmalı.

Açmak için (hazır olunca, ayrı onayla):
```sql
update public.platform_flags set enabled = true, note = 'Üyelik kilidi açık' where key = 'subscription_enforcement';
```

## Deneme (yalnızca yönetici, elle)

- Admin: `/kullanicilar/<id>` sayfasında "72 saatlik deneme ver". Gerekçe zorunlu.
- Başlangıç ve bitiş sunucuda atanır (tam 72 saat); süre dolumu için zamanlanmış iş yoktur.
- Aynı anda tek deneme; eşzamanlı iki admin işleminde yalnızca biri geçer (kullanıcı satırı kilidi + yarış testi).
- Daha önce deneme almış kullanıcıya yeniden vermek için "bilinçli yenileme" kutusu gerekir (`repeat_grant = true` olarak denetlenir).
- Deneme abonelik/satın alma kaydı değildir; ciro veya ödeme istatistiğine girmez. Deneme sırasında gerçek paket satın alınabilir.
- Denetim: `access_trials` (kim, ne zaman, neden) ve değiştirilemez `trial_events`.
- Deneme, kullanıcının ebeveyn olduğu **tüm ailelerde** geçerlidir (süresiz test erişimiyle aynı model).

## Yeni Kayıtlar ve e-posta (elle)

- **Sistem e-posta göndermez.** Admin metni kopyalayıp kendi e-posta hesabından gönderir, sonra "Gönderildi olarak işaretle" der.
- Bekleyen liste `auth.users` kaydından **türetilir** (kopya yok): yalnızca migration'ın çalıştığı andan (`signup_queue_started`) sonra kayıt olanlar, platform yöneticileri hariç. Eski kullanıcılar listede görünmez.
- İşaretleme tek kaydın benzersiz indeksiyle idempotenttir; çift tıklama veya iki yönetici tek kayıt üretir. Kullanıcı hiçbir zaman silinmez.
- Menüdeki sayaç ayrı bir hız sınırı kovasını (`badge`) kullanır; hata verirse rozet gizlenir, sayfa bozulmaz.
- Şablonlar (`/e-posta-sablonlari`): hoş geldin ve deneme-aktif. Düz metin, sürümlü ve denetlenebilir. İzinli yer tutucular yalnızca `{{ad}}` ve `{{deneme_bitis}}`; başkası kaydedilmez.
- "Teslim edildi" bilgisi yoktur: gönderim sistem dışında yapıldığı için yalnızca "gönderildi (elle işaretlendi)" tutulur.
- KVKK/ETK: karşılama e-postası işlemsel bilgilendirme olarak kalmalı; tanıtım içeriği eklenirse ticari ileti onayı gerekir.

## Canlıya alma sırası (her biri ayrı onay)

1. Migration 0200, sonra 0300'ü Supabase'e uygula. Bayrak kapalı olduğu sürece kullanıcı davranışı değişmez.
2. Admin panelini Vercel'e dağıt (`/yeni-kayitlar`, `/e-posta-sablonlari`, deneme formu).
3. Şablon metinlerini yaz ve kaydet.
4. Flutter güncellemesi + yeni AAB (Faz C).
5. Yukarıdaki kontrol listesi tamamlanınca bayrağı aç.
