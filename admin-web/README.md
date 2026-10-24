# Bebeğimin İlk Yılı — Platform Yönetimi

Bağımsız Next.js yönetim paneli. Mobil uygulamayla aynı Supabase Auth hesabını,
`platform_user_roles` rolünü ve `admin_*` RPC güvenlik sınırını kullanır.

## Yerel çalıştırma

1. `.env.example` dosyasını `.env.local` olarak kopyalayın.
2. Aynı Supabase projesinin URL ve publishable/anon anahtarını girin.
3. `npm install`, ardından `npm run dev` çalıştırın.

`service_role`, Google Play servis hesabı ve webhook secret'ları bu uygulamanın
ortamına hiçbir zaman eklenmemelidir.
