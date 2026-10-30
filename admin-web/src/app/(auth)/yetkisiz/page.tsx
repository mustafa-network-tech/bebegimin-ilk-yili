import Link from "next/link";

export default function UnauthorizedPage() {
  return <><section className="auth-intro"><div className="brand"><span className="brand-mark">B</span><span><strong>Bebeğimin İlk Yılı</strong><small>Platform Yönetimi</small></span></div><div><p className="eyebrow">Erişim engellendi</p><h1>Bu alan yalnızca platform yöneticilerine açık.</h1><p>Aile yöneticiliği platform yönetimi yetkisi vermez.</p></div></section><section className="auth-panel"><div className="auth-card"><div className="notice danger-notice">Hesabınızda etkin bir <code>super_admin</code> rolü bulunamadı.</div><p><Link className="button secondary" href="/giris">Giriş ekranına dön</Link></p></div></section></>;
}
