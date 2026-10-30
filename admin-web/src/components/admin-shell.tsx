import Link from "next/link";
import type { ReactNode } from "react";

import { logoutAction } from "@/app/actions/auth";

const nav = [
  ["/dashboard", "Genel bakış", "⌂"],
  ["/yeni-kayitlar", "Yeni kayıtlar", "✚"],
  ["/e-posta-sablonlari", "E-posta şablonları", "✉"],
  ["/kullanicilar", "Kullanıcılar ve aileler", "◎"],
  ["/donusum", "Abonelik dönüşümü", "▽"],
  ["/abonelik-planlari", "Abonelik planları", "◫"],
  ["/abonelikler", "Aktif abonelikler", "↻"],
  ["/urunler", "Dijital ürünler", "◇"],
  ["/test-erisimleri", "Test erişimleri", "∞"],
  ["/odemeler", "Satın alma ve ödemeler", "₺"],
  ["/uzatmalar", "Uzatma talepleri", "+"],
  ["/dogum-tarihi", "Doğum tarihi", "◷"],
  ["/denetim", "Denetim kayıtları", "≡"],
] as const;

export function AdminShell({ children, email, pendingSignups = 0 }: { children: ReactNode; email?: string; pendingSignups?: number }) {
  return (
    <div className="admin-shell">
      <aside className="sidebar">
        <Link href="/dashboard" className="brand">
          <span className="brand-mark">B</span>
          <span><strong>Bebeğimin İlk Yılı</strong><small>Platform Yönetimi</small></span>
        </Link>
        <nav className="side-nav">
          {nav.map(([href, label, icon]) => <Link key={href} href={href}><span aria-hidden>{icon}</span>{label}{href === "/yeni-kayitlar" && pendingSignups > 0 && <span className="nav-badge" aria-label={`${pendingSignups} bekleyen kayıt`}>{pendingSignups}</span>}</Link>)}
        </nav>
        <div className="admin-account">
          <small>Platform yöneticisi</small>
          <strong>{email ?? "Yönetici"}</strong>
          <form action={logoutAction}><button className="button secondary" type="submit">Çıkış yap</button></form>
        </div>
      </aside>
      <main className="content">{children}</main>
    </div>
  );
}
