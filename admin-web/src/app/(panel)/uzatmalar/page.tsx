import { decideExtensionAction } from "@/app/actions/admin";
import { ExtensionActionForm } from "@/components/admin-action-form";
import { Badge, EmptyState, FilterBar, PageHeader, Pagination } from "@/components/ui";
import { getExtensions } from "@/lib/admin/queries";
import { date, dateTime, statusLabel } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const v = (x: string | string[] | undefined) => typeof x === "string" ? x : "";

export default async function ExtensionsPage({ searchParams }: Props) {
  const p = await searchParams;
  const status = ["pending", "decided", "expired", "all"].includes(v(p.status)) ? v(p.status) : "pending";
  const q = v(p.q).slice(0, 60);
  const offset = Math.max(0, Number(v(p.offset)) || 0);
  const rows = await getExtensions(status, q || null, offset);
  const total = rows[0]?.total_count ?? 0;
  const href = (next: number) => `/uzatmalar?${new URLSearchParams({ status, ...(q ? { q } : {}), offset: String(next) })}`;
  return <><PageHeader eyebrow="Destek işlemleri" title="Uzatma talepleri" description="Bekleyen talepleri kapanış tarihine göre önceliklendirin. Kararlar kesindir ve mevcut denetim akışına kaydedilir." /><FilterBar><input name="q" defaultValue={q} maxLength={60} placeholder="Bebek adı, bebek veya talep UUID" /><select name="status" defaultValue={status}><option value="pending">Bekleyen</option><option value="decided">Karara bağlanan</option><option value="expired">Süresi dolan</option><option value="all">Tümü</option></select></FilterBar>{rows.length === 0 ? <EmptyState title="Talep bulunamadı" text="Bu filtrelerde uzatma talebi yok." /> : <><div className="table-wrap"><table><thead><tr><th>Talep</th><th>Süre ve kapanış</th><th>Durum</th><th>Karar</th></tr></thead><tbody>{rows.map((row) => <tr key={row.request_id}><td><strong>{row.baby_first_name}</strong><small>{row.requested_by_name} · {dateTime(row.requested_at)}</small><small className="code">{row.request_id}</small></td><td><strong>{row.requested_days} gün</strong><small>Standart kapanış: {date(row.base_close_date)}</small>{row.status === "pending" && <small>{row.days_until_base_close <= 0 ? "Bugün kapanıyor" : `${row.days_until_base_close} gün kaldı`}</small>}</td><td><Badge tone={row.status === "pending" ? row.sla === "urgent" ? "bad" : "warn" : row.status === "approved" ? "good" : "neutral"}>{statusLabel(row.status)}</Badge>{row.decision_note && <small>{row.decision_note}</small>}</td><td>{row.status === "pending" ? <ExtensionActionForm action={decideExtensionAction} requestId={row.request_id} /> : <><strong>{row.decided_by_name || "Sistem"}</strong><small>{dateTime(row.decided_at)}</small></>}</td></tr>)}</tbody></table></div><Pagination offset={offset} count={rows.length} total={total} href={href} /></>}</>;
}
