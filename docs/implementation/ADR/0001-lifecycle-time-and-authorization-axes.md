# ADR 0001 — Lifecycle tarih semantiği ve yetki eksenleri

- Durum: Kabul edildi
- Tarih: 2026-09-27
- Kaynak: `GELISTIRME.MD` değiştirilemez iş kuralları

## Karar

- İş takvimi `Europe/Istanbul` bölgesindeki takvim tarihidir; istemci saati yetkili değildir.
- Standart kapanış tarihi `birth_date + 375`, mutlak kapanış tarihi en fazla `birth_date + 405` gündür.
- Aralık yarı-açıktır: iş tarihi etkin kapanış tarihinden küçükse `ACTIVE`, aksi halde `LOCKED`.
- İlk doğum günü ve sonraki on günlük final dönem standart 375 güne dahildir.
- Lifecycle durumu saklanan, elle değiştirilen bir boolean/enum değil; sunucu tarihinden türetilen sonuçtur.
- Yetkilendirme dört ayrı eksende değerlendirilir: aile üyeliği/rolü, lifecycle, abonelik ve ürün entitlement'ı. Bir eksen diğerinin yerine geçmez.
- Faz 2 yalnız lifecycle ve Super Admin çekirdeğini kurar; abonelik ve entitlement bu karara dahil değildir.

## Sonuçlar

- Lifecycle kararları veritabanı fonksiyonları/RPC üzerinden üretilir.
- Flutter istemcisi sunucu özetini tüketir; yerel saat lifecycle yetkisi vermez.
- İçerik mutation kilitlerinin tamamı Faz 3 kapsamındadır.
