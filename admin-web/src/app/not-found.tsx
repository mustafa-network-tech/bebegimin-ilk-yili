import Link from "next/link";

export default function NotFound() {
  return <main className="auth-panel" style={{ minHeight: "100vh" }}><div className="auth-card"><p className="eyebrow">404</p><h1>Sayfa bulunamadı</h1><p>Aradığınız yönetim sayfası mevcut değil.</p><Link className="button primary" href="/dashboard">Dashboard’a dön</Link></div></main>;
}
