import { logoutAction } from "@/app/actions/auth";
import { requireSuperAdmin } from "@/lib/admin/auth";

export const dynamic = "force-dynamic";

export default async function DisabledPage() {
  await requireSuperAdmin({ requireConsole: false });
  return <><section className="auth-intro"><div className="brand"><span className="brand-mark">B</span><span><strong>Bebeğimin İlk Yılı</strong><small>Platform Yönetimi</small></span></div><div><p className="eyebrow">Kill switch etkin</p><h1>Yönetim paneli geçici olarak kapalı.</h1><p>Rolünüz geçerli, ancak <code>admin_console</code> güvenlik bayrağı panel erişimini durdurdu.</p></div></section><section className="auth-panel"><div className="auth-card"><div className="notice">Panel yeniden açılana kadar hiçbir yönetim verisi veya işlemi kullanılamaz.</div><form action={logoutAction}><button className="button secondary" type="submit">Çıkış yap</button></form></div></section></>;
}
