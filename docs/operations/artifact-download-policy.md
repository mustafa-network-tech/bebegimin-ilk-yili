# Dijital ürün indirme ve yeniden indirme politikası

Bu belge Faz 12'de uygulanan kuralları anlatır. Kurallar Dijital Kitap (PDF), İlk Yıl Filmi (MP4) ve Offline HTML arşivi (ZIP) için **aynıdır**. Ortak çıktı hattı için bkz. [output-pipeline-setup.md](output-pipeline-setup.md).

## Kim indirebilir?

Her indirme isteğinde (`output-download` → `authorize_artifact_download` → `output_artifact_download_block`) aşağıdaki koşullar baştan denetlenir:

| # | Koşul | Anne / Baba | Family Member |
|---|---|---|---|
| 1 | Bebeğin ailesinde ve aynı aile hesabında aktif üyelik | ✓ | ✓ |
| 2 | Bebek `LOCKED` | ✓ | ✓ |
| 3 | Aile hesabının aboneliği erişim veriyor (ayrı üye aboneliği aranmaz) | ✓ | ✓ |
| 4 | Bu bebek + ürün için aktif satın alma hakkı | ✓ | ✓ |
| 5 | Aktif Family Member sayısı plan kapasitesini aşmıyor | — | ✓ |
| 6 | Bir ebeveyn bu bebeğin **bu ürününü** bu kişiyle paylaşmış | — | ✓ |
| — | Artifact `ready` | ✓ | ✓ |

- Albüm görme izni (`view_album`) indirme kararında artık kullanılmaz.
- Kitap izni Film veya HTML açmaz; her ürün ayrı paylaşılır.
- Paylaşımı yalnız aktif ebeveyn verir veya kaldırır (`set_artifact_download_permission`). Family Member satın alma, düzenleme, seçim, render ve yeniden üretim uçlarına erişemez (sunucuda `not_parent`).
- Family Member, ekranlarda yalnız indirebileceği hazır dosyayı görür. Film ve arşiv durumu üyeler için maskelenir; üretim işleri gösterilmez.

## İndirme bağlantısı

- Sunucu her istekte yeni, **60 saniyelik** imzalı bir bağlantı üretir. Bağlantı loglanmaz ve yanıt `Cache-Control: no-store` taşır.
- İmzalı Storage bağlantısı bir taşıyıcı (bearer) bağlantıdır; kullanıcıya kriptografik olarak bağlanamaz. Bu yüzden ömrü kısadır ve her yeni bağlantı yukarıdaki tüm koşulları yeniden geçmek zorundadır.
- Hız sınırı: aynı kullanıcı aynı dosya için 10 dakikada en çok 10, toplamda en çok 30 bağlantı alır (`rate_limited`, HTTP 429).
- Denetim: verilen her bağlantı `output_artifact_downloads` tablosuna (kullanıcı, dosya, rol, ürün, zaman), her ret `output_download_denials` tablosuna (kullanıcı, dosya, neden, zaman) yazılır. Super Admin özeti `admin_download_audit(gün)` ile görür.

## Durum değişiklikleri

| Olay | Hazır dosya | Yeni bağlantı | Daha önce verilmiş bağlantı |
|---|---|---|---|
| Ebeveyn paylaşımı kaldırır | Korunur | Family Member alamaz (`permission_denied`) | En fazla 60 sn geçerli kalır |
| Family Member bebekten / aile hesabından çıkar | Korunur | Alamaz | En fazla 60 sn |
| Çıkan üye geri döner | Korunur | Paylaşım **otomatik geri gelmez**; ebeveyn yeniden paylaşmalı | — |
| Abonelik pasif olur | Korunur, satın alma korunur | Kimse alamaz (`subscription_required`) | En fazla 60 sn |
| Abonelik yeniden etkin olur | Aynı dosya | Yeniden alınır; **yeni satın alma gerekmez** | — |
| Plan küçülür, üye sayısı kapasiteyi aşar | Korunur | Ebeveynler alır; Family Member'lar kapasite uygun olana kadar alamaz (`capacity_exceeded`) | En fazla 60 sn |
| İade / chargeback (satın alma hakkı iptal) | Korunur (silinmez) | Kimse alamaz (`entitlement_required`) | En fazla 60 sn |
| Arşiv uzatmayla yeniden açılır | Korunur | Kimse alamaz (`premium_requires_locked`) | En fazla 60 sn |

Paylaşım kayıtları silinmez: kaldırılan ve otomatik iptal edilen paylaşımlar kimin, ne zaman ve neden (`parent_revoked` / `membership_ended`) iptal ettiğiyle birlikte saklanır.

## Kill switch

```sql
-- Family Member indirmelerini kapat (ebeveyn indirmeleri etkilenmez)
update public.platform_flags set enabled = false, note = '<gerekçe>' where key = 'member_downloads';
```
