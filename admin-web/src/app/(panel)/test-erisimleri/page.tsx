import { setTestAccessAction } from "@/app/actions/admin";
import { TestAccessActionForm } from "@/components/admin-action-form";
import { Badge, EmptyState, FilterBar, PageHeader, Pagination } from "@/components/ui";
import { getTestAccessEvents, getTestAccessUsers } from "@/lib/admin/queries";
import { dateTime } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const value = (v: string | string[] | undefined) => typeof v === "string" ? v : "";

export default async function TestAccessPage({ searchParams }: Props) {
  const params = await searchParams;
  const q = value(params.q).slice(0, 60);
  const status = ["all", "active", "inactive"].includes(value(params.status)) ? value(params.status) : "all";
  const offset = Math.max(0, Number(value(params.offset)) || 0);
  const eventOffset = Math.max(0, Number(value(params.eventOffset)) || 0);
  const [users, events] = await Promise.all([
    getTestAccessUsers(q || null, status, offset),
    getTestAccessEvents(eventOffset),
  ]);
  const total = users[0]?.total_count ?? 0;
  const eventTotal = events[0]?.total_count ?? 0;
  const userHref = (next: number) => `/test-erisimleri?${new URLSearchParams({
    ...(q ? { q } : {}), status, offset: String(next), eventOffset: String(eventOffset),
  })}`;
  const eventHref = (next: number) => `/test-erisimleri?${new URLSearchParams({
    ...(q ? { q } : {}), status, offset: String(offset), eventOffset: String(next),
  })}`;

  return <>
    <PageHeader
      eyebrow="İç test"
      title="Sınırsız test erişimleri"
      description="UUID tabanlı test erişimi; gerçek abonelik, satın alma, ödeme veya ciro kaydı oluşturmaz. Erişim yalnız kullanıcının ebeveyn olduğu ailelerde geçerlidir."
    />
    <div className="notice">Bu yetki süresizdir. İptal edildiğinde aile yeniden normal ücretli kurallara döner; önceki işlemler denetim geçmişinde kalır.</div>
    <section className="section">
      <h2>Kullanıcılar</h2>
      <FilterBar>
        <input name="q" defaultValue={q} maxLength={60} placeholder="E-posta, ad veya kullanıcı UUID" />
        <select name="status" defaultValue={status}>
          <option value="all">Tüm kullanıcılar</option>
          <option value="active">Erişimi olanlar</option>
          <option value="inactive">Erişimi olmayanlar</option>
        </select>
      </FilterBar>
      {users.length === 0 ? <EmptyState title="Kullanıcı bulunamadı" text="Arama veya filtre ölçütlerini değiştirin." /> : <>
        <div className="table-wrap"><table><thead><tr><th>Kullanıcı</th><th>Aileler</th><th>Test erişimi</th><th>İşlem</th></tr></thead><tbody>
          {users.map((row) => <tr key={row.user_id}>
            <td><strong>{row.display_name || "İsimsiz kullanıcı"}</strong><small>{row.email || "E-posta yok"}</small><small className="code">{row.user_id}</small></td>
            <td>{row.families.length === 0 ? <Badge tone="warn">Aile hesabı yok</Badge> : row.families.map((family) => <div key={family.id}><strong>{family.display_name}</strong><small>{family.member_role === "parent" ? "Ebeveyn" : "Aile üyesi"} · {family.baby_count} bebek · {family.member_status}</small></div>)}</td>
            <td><Badge tone={row.access_enabled ? "good" : "neutral"}>{row.access_enabled ? "Süresiz aktif" : "Kapalı"}</Badge>{row.granted_at && <small>Verildi: {dateTime(row.granted_at)}</small>}{row.revoked_at && <small>İptal: {dateTime(row.revoked_at)}</small>}</td>
            <td><TestAccessActionForm action={setTestAccessAction} userId={row.user_id} enabled={row.access_enabled} /></td>
          </tr>)}
        </tbody></table></div>
        <Pagination offset={offset} count={users.length} total={total} href={userHref} />
      </>}
    </section>
    <section className="section">
      <h2>Yetkilendirme geçmişi</h2>
      {events.length === 0 ? <EmptyState title="Geçmiş kaydı yok" text="Henüz test erişimi verilmedi veya iptal edilmedi." /> : <>
        <div className="table-wrap"><table><thead><tr><th>Zaman</th><th>Kullanıcı</th><th>İşlem</th><th>Yönetici</th><th>Gerekçe</th></tr></thead><tbody>
          {events.map((event) => <tr key={event.event_id}>
            <td>{dateTime(event.created_at)}</td>
            <td><strong>{event.display_name || event.email || "Silinmiş kullanıcı"}</strong><small>{event.email}</small><small className="code">{event.user_id}</small></td>
            <td><Badge tone={event.action === "granted" ? "good" : "warn"}>{event.action === "granted" ? "Verildi" : "İptal edildi"}</Badge></td>
            <td><strong>{event.actor_name}</strong>{event.actor_id && <small className="code">{event.actor_id}</small>}</td>
            <td><p className="audit-details">{event.reason}</p></td>
          </tr>)}
        </tbody></table></div>
        <Pagination offset={eventOffset} count={events.length} total={eventTotal} href={eventHref} />
      </>}
    </section>
  </>;
}
