import { Badge, EmptyState, FilterBar, PageHeader, Pagination } from "@/components/ui";
import { getSubscriptions } from "@/lib/admin/queries";
import { dateTime, planName, statusLabel } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const v = (x: string | string[] | undefined) => typeof x === "string" ? x : "";

export default async function SubscriptionsPage({ searchParams }: Props) {
  const p = await searchParams;
  const allowed = ["access_granting", "all", "trialing", "active", "grace", "past_due", "canceled", "expired"];
  const status = allowed.includes(v(p.status)) ? v(p.status) : "access_granting";
  const plan = ["small_family", "normal_family", "large_family"].includes(v(p.plan)) ? v(p.plan) : "";
  const q = v(p.q).slice(0, 60);
  const offset = Math.max(0, Number(v(p.offset)) || 0);
  const rows = await getSubscriptions(status, plan || null, q || null, offset);
  const total = rows[0]?.total_count ?? 0;
  const href = (next: number) => `/abonelikler?${new URLSearchParams({ status, ...(plan ? { plan } : {}), ...(q ? { q } : {}), offset: String(next) })}`;
  return <><PageHeader eyebrow="Abonelikler" title="Aile abonelikleri" description="Doğrulanmış mağaza olaylarından oluşan abonelik durumları, yenileme tarihleri ve kapasite kullanımı." /><FilterBar><input name="q" defaultValue={q} maxLength={60} placeholder="Aile adı, hesap veya abonelik UUID" /><select name="status" defaultValue={status}><option value="access_granting">Erişim verenler</option><option value="all">Tüm durumlar</option><option value="active">Aktif</option><option value="trialing">Deneme</option><option value="grace">Ek süre</option><option value="past_due">Ödeme sorunu</option><option value="canceled">İptal</option><option value="expired">Süresi doldu</option></select><select name="plan" defaultValue={plan}><option value="">Tüm paketler</option><option value="small_family">Small Family</option><option value="normal_family">Normal Family</option><option value="large_family">Large Family</option></select></FilterBar>{rows.length === 0 ? <EmptyState title="Abonelik bulunamadı" text="Bu filtrelerde doğrulanmış abonelik kaydı yok." /> : <><div className="table-wrap"><table><thead><tr><th>Aile</th><th>Paket</th><th>Durum</th><th>Kapasite</th><th>Sağlayıcı</th><th>Yenileme / bitiş</th></tr></thead><tbody>{rows.map((row) => <tr key={row.subscription_id}><td><strong>{row.family_name}</strong><small className="code">{row.family_account_id}</small><small>{row.baby_count} bebek</small></td><td><strong>{planName(row.plan_code)}</strong><small>{row.billing_period === "monthly" ? "Aylık" : "Yıllık"}</small></td><td><Badge tone={["active", "trialing", "grace"].includes(row.status) ? "good" : row.status === "past_due" ? "bad" : "neutral"}>{statusLabel(row.status)}</Badge>{row.cancel_at_period_end && <small>Dönem sonunda iptal</small>}</td><td><strong>{row.parent_count} ebeveyn · {row.family_member_count} üye</strong>{row.over_capacity && <small><Badge tone="bad">Kapasite aşıldı</Badge></small>}</td><td><strong>{row.provider}</strong><small className="code">{row.provider_reference_masked}</small></td><td>{dateTime(row.current_period_end)}</td></tr>)}</tbody></table></div><Pagination offset={offset} count={rows.length} total={total} href={href} /></>}</>;
}
