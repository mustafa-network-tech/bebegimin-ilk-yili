# Bebeğimin İlk Yılı — Platform Yönetimi

Bağımsız Next.js yönetim paneli. Mobil uygulamayla aynı Supabase Auth hesabını,
`platform_user_roles` rolünü ve `admin_*` RPC güvenlik sınırını kullanır.

## Yerel çalıştırma

1. `.env.example` dosyasını `.env.local` olarak kopyalayın.
2. Aynı Supabase projesinin URL'sini ve `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
   veya `NEXT_PUBLIC_SUPABASE_ANON_KEY` değişkenlerinden birini girin. İkisi de
   varsa publishable anahtar tercih edilir.
3. `npm install`, ardından `npm run dev` çalıştırın.

Supabase `service_role` ve webhook secret'ları bu uygulamanın ortamına hiçbir
zaman eklenmemelidir. Google Play katalog kontrolü için servis hesabı JSON'u
yalnızca sunucu tarafındaki `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` değişkenine,
paket adı da `GOOGLE_PLAY_PACKAGE_NAME` değişkenine yazılır. Bu değişkenlerde
`NEXT_PUBLIC_` öneki kullanılmaz; değerler kaynak koda veya Git'e eklenmez.
