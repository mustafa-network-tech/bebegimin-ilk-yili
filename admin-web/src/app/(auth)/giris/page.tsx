import { redirect } from "next/navigation";

import { loginAction } from "@/app/actions/auth";
import { AuthForm } from "@/components/auth-form";
import { getAdminSession } from "@/lib/admin/auth";

export const dynamic = "force-dynamic";

export default async function LoginPage() {
  const { user, admin } = await getAdminSession();
  if (user && admin?.is_super_admin) redirect(admin.console_enabled ? "/dashboard" : "/panel-kapali");
  return (
    <>
      <section className="auth-intro">
        <div className="brand"><span className="brand-mark">B</span><span><strong>Bebeğimin İlk Yılı</strong><small>Platform Yönetimi</small></span></div>
        <div><p className="eyebrow">Güvenli yönetim alanı</p><h1>Ailelerin anılarını güvenle yönetin.</h1><p>Abonelikler, dijital ürünler ve destek işlemleri aynı Supabase güvenlik altyapısı üzerinden yönetilir.</p></div>
        <small>Yalnızca yetkili platform yöneticileri içindir.</small>
      </section>
      <section className="auth-panel"><div className="auth-card"><p className="eyebrow">Yönetici girişi</p><h1>Tekrar hoş geldiniz</h1><p>Mobil uygulamadaki platform yöneticisi hesabınızla giriş yapın.</p><AuthForm action={loginAction} kind="login" /></div></section>
    </>
  );
}
