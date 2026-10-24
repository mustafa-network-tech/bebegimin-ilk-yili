import Link from "next/link";
import type { ReactNode } from "react";

export function PageHeader({ eyebrow, title, description, actions }: { eyebrow?: string; title: string; description: string; actions?: ReactNode }) {
  return (
    <header className="page-header">
      <div>
        {eyebrow && <p className="eyebrow">{eyebrow}</p>}
        <h1>{title}</h1>
        <p>{description}</p>
      </div>
      {actions && <div className="page-actions">{actions}</div>}
    </header>
  );
}

export function Badge({ children, tone = "neutral" }: { children: ReactNode; tone?: "good" | "warn" | "bad" | "neutral" }) {
  return <span className={`badge ${tone}`}>{children}</span>;
}

export function EmptyState({ title, text }: { title: string; text: string }) {
  return <div className="empty"><strong>{title}</strong><p>{text}</p></div>;
}

export function Pagination({ offset, count, total, href }: { offset: number; count: number; total: number; href: (offset: number) => string }) {
  if (offset === 0 && count >= total) return null;
  return (
    <nav className="pagination" aria-label="Sayfalama">
      {offset > 0 ? <Link className="button secondary" href={href(Math.max(0, offset - 50))}>Önceki</Link> : <span />}
      <span>{total === 0 ? 0 : offset + 1}–{Math.min(offset + count, total)} / {total}</span>
      {offset + count < total ? <Link className="button secondary" href={href(offset + 50)}>Sonraki</Link> : <span />}
    </nav>
  );
}

export function StatCard({ label, value, detail, tone }: { label: string; value: number | string; detail?: string; tone?: string }) {
  return <article className={`stat-card ${tone ?? ""}`}><span>{label}</span><strong>{value}</strong>{detail && <small>{detail}</small>}</article>;
}

export function FilterBar({ children }: { children: ReactNode }) {
  return <form className="filter-bar" method="get">{children}<button className="button primary" type="submit">Uygula</button></form>;
}
