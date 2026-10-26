import { Badge, EmptyState, PageHeader, Pagination } from "@/components/ui";
import { getAuditLog, getPlatformAuditLog } from "@/lib/admin/queries";
import { dateTime, statusLabel } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const v = (x: string | string[] | undefined) => typeof x === "string" ? x : "";
const detailText = (details: Record<string, unknown>) => Object.entries(details).map(([key, value]) => `${key}: ${String(value)}`).join(" · ");

export default async function AuditPage({ searchParams }: Props) {
  const p = await searchParams;
  const offset = Math.max(0, Number(v(p.offset)) || 0);
  const platformOffset = Math.max(0, Number(v(p.platformOffset)) || 0);
  const [lifecycle, platform] = await Promise.all([getAuditLog(null, offset), getPlatformAuditLog("all", platformOffset)]);
  const total = lifecycle[0]?.total_count ?? 0;
  const platformTotal = platform[0]?.total_count ?? 0;
  return <><PageHeader eyebrow="İzlenebilirlik" title="Denetim ve işlem geçmişi" description="Lifecycle kararları, rol değişiklikleri, platform bayrakları ve Google Play katalog kontrolleri değiştirilemez kayıtlardan okunur." /><section><h2>Lifecycle ve destek işlemleri</h2>{lifecycle.length === 0 ? <EmptyState title="Denetim kaydı yok" text="Henüz lifecycle yönetim işlemi oluşmadı." /> : <><div className="table-wrap"><table><thead><tr><th>Zaman</th><th>İşlem</th><th>Bebek</th><th>İşlemi yapan</th><th>Ayrıntı</th></tr></thead><tbody>{lifecycle.map((row) => <tr key={row.id}><td>{dateTime(row.created_at)}</td><td><Badge>{statusLabel(row.action)}</Badge></td><td><strong>{row.baby_first_name}</strong><small className="code">{row.baby_id}</small></td><td>{row.actor_name}</td><td><p className="audit-details">{detailText(row.details) || "—"}</p></td></tr>)}</tbody></table></div><Pagination offset={offset} count={lifecycle.length} total={total} href={(next) => `/denetim?offset=${next}&platformOffset=${platformOffset}`} /></>}</section><section className="section"><h2>Platform güvenlik kayıtları</h2>{platform.length === 0 ? <EmptyState title="Platform kaydı yok" text="Rol, güvenlik bayrağı veya katalog kontrolü bulunamadı." /> : <><div className="table-wrap"><table><thead><tr><th>Zaman</th><th>Kaynak</th><th>İşlem</th><th>Hedef</th><th>Aktör</th><th>Ayrıntı</th></tr></thead><tbody>{platform.map((row) => <tr key={`${row.source}-${row.event_id}`}><td>{dateTime(row.created_at)}</td><td><Badge tone={row.source === "role" ? "warn" : row.source === "google_play" ? "good" : "neutral"}>{row.source === "role" ? "Rol" : row.source === "google_play" ? "Google Play" : "Bayrak"}</Badge></td><td>{row.action}</td><td className="code">{row.target}</td><td>{row.actor}</td><td><p className="audit-details">{detailText(row.details)}</p></td></tr>)}</tbody></table></div><Pagination offset={platformOffset} count={platform.length} total={platformTotal} href={(next) => `/denetim?offset=${offset}&platformOffset=${next}`} /></>}</section></>;
}
