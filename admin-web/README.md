# Bebeğimin İlk Yılı — Platform Yönetimi

Bağımsız Next.js yönetim paneli. Mobil uygulamayla aynı Supabase Auth hesabını,
`platform_user_roles` rolünü ve `admin_*` RPC güvenlik sınırını kullanır.

## Yerel çalıştırma

1. `.env.example` dosyasını `.env.local` olarak kopyalayın.
2. Aynı Supabase projesinin URL'sini ve `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
   veya `NEXT_PUBLIC_SUPABASE_ANON_KEY` değişkenlerinden birini girin. İkisi de
   varsa publishable anahtar tercih edilir.
3. `npm install`, ardından `npm run dev` çalıştırın.

`service_role`, Google Play servis hesabı ve webhook secret'ları bu uygulamanın
ortamına hiçbir zaman eklenmemelidir.
