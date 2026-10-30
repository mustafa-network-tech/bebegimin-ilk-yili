import Link from "next/link";

import { EmptyState, FilterBar, PageHeader, Pagination } from "@/components/ui";
import { getUsersFamilies } from "@/lib/admin/queries";
import { date } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const value = (v: string | string[] | undefined) => typeof v === "string" ? v : "";

export default async function UsersPage({ searchParams }: Props) {
  const params = await searchParams;
  const q = value(params.q).slice(0, 60);
  const status = ["all", "with_family", "without_family"].includes(value(params.status)) ? value(params.status) : "all";
  const offset = Math.max(0, Number(value(params.offset)) || 0);
  const rows = await getUsersFamilies(q || null, status, offset);
  const total = rows[0]?.total_count ?? 0;
  const href = (next: number) => `/kullanicilar?${new URLSearchParams({ ...(q ? { q } : {}), status, offset: String(next) })}`;
  return <><PageHeader eyebrow="Hesaplar" title="Kullanıcılar ve aileler" description="Kullanıcıların bağlı olduğu aile hesaplarını, rollerini ve bebek sayılarını görüntüleyin." /><FilterBar><input name="q" defaultValue={q} maxLength={60} placeholder="E-posta, ad veya kullanıcı UUID" /><select name="status" defaultValue={status}><option value="all">Tüm kullanıcılar</option><option value="with_family">Ailesi olanlar</option><option value="without_family">Ailesi olmayanlar</option></select></FilterBar>{rows.length === 0 ? <EmptyState title="Kayıt bulunamadı" text="Arama ve filtre ölçütlerini değiştirin." /> : <><div className="table-wrap"><table><thead><tr><th>Kullanıcı</th><th>Aile hesapları</th><th>Kayıt tarihi</th><th /></tr></thead><tbody>{rows.map((row) => <tr key={row.user_id}><td><strong>{row.display_name || "İsimsiz kullanıcı"}</strong><small>{row.email || "E-posta yok"}</small><small className="code">{row.user_id}</small></td><td>{row.families.length === 0 ? <span className="badge warn">Aile hesabı yok</span> : row.families.map((family) => <div key={family.id}><strong>{family.display_name}</strong><small>{family.member_role === "parent" ? "Ebeveyn" : "Aile üyesi"} · {family.baby_count} bebek · {family.member_status}</small></div>)}</td><td>{date(row.user_created_at)}</td><td><Link className="button secondary" href={`/kullanicilar/${row.user_id}`}>Hareket geçmişi</Link></td></tr>)}</tbody></table></div><Pagination offset={offset} count={rows.length} total={total} href={href} /></>}</>;
}
