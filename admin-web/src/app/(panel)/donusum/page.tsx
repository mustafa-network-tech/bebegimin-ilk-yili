import Link from "next/link";

import { Badge, EmptyState, PageHeader, Pagination, StatCard } from "@/components/ui";
import { getConversionFunnel, getPaymentProblems } from "@/lib/admin/queries";
import { dateTime, errorCodeLabel, paymentProblemLabel, planName } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const PERIODS = [7, 30, 90] as const;

export default async function ConversionPage({ searchParams }: Props) {
  const sp = await searchParams;
  const raw = Number(typeof sp.days === "string" ? sp.days : 30);
  const days = (PERIODS as readonly number[]).includes(raw) ? raw : 30;
  const offset = Math.max(0, Number(typeof sp.offset === "string" ? sp.offset : 0) || 0);
  const [funnel, problems] = await Promise.all([getConversionFunnel(days), getPaymentProblems(offset)]);
  if (!funnel) return <EmptyState title="Veri alınamadı" text="Dönüşüm özeti hesaplanamadı." />;
  const total = problems[0]?.total_count ?? 0;
  const steps: Array<[string, number, string?]> = [
    ["Kayıt olan", funnel.registered],
    ["E-postasını doğrulayan", funnel.email_verified],
    ["Aile hesabı oluşturan", funnel.family_created],
    ["Paketleri görüntüleyen", funnel.plans_viewed, funnel.plans_viewed_available ? undefined : "Uygulama güncellemesi yayınlanınca izlenmeye başlar"],
    ["Ödeme başlatan", funnel.checkout_started, "Ödeme niyeti açan kullanıcılar"],
    ["Ödemesi mağazada onaylanan", funnel.payment_verified, `${dateTime(funnel.tracking_started_at)} sonrası izlenir`],
    ["Aboneliği etkinleşen", funnel.activated_users, `${funnel.activated_families} aile hesabı`],
  ];
  return <>
    <PageHeader eyebrow="Büyüme" title="Abonelik dönüşüm analizi" description="Kayıttan aboneliğe kullanıcı sayıları. Sayılar yalnızca toplamlardır; kişisel veri göstermez." />
    <nav className="filter-bar" aria-label="Dönem">{PERIODS.map((p) => <Link key={p} className={`button ${p === days ? "primary" : "secondary"}`} href={`/donusum?days=${p}`}>Son {p} gün</Link>)}</nav>
    <div className="stats-grid">{steps.map(([label, value, detail]) => <StatCard key={label} label={label} value={value} detail={detail} />)}</div>
    <div className="stats-grid" style={{ marginTop: 14 }}>
      <StatCard label="Ödeme onaylandı, abonelik etkinleşmedi" value={funnel.open_paid_not_activated} tone={funnel.open_paid_not_activated ? "bad" : ""} detail="Açık sorun" />
      <StatCard label="Mağaza doğrulaması başarısız" value={funnel.open_verification_failed} tone={funnel.open_verification_failed ? "warn" : ""} detail="Ödeme durumu bilinmiyor" />
    </div>
    <section className="section"><div className="section-head"><div><h2>Sorunlu ödemeler</h2><p>Son 90 gün. İki durum bilerek ayrı gösterilir.</p></div></div>
      {problems.length === 0 ? <EmptyState title="Açık sorun yok" text="Etkinleşmeyen onaylı ödeme veya çözülmemiş doğrulama hatası bulunmuyor." /> : <><div className="table-wrap"><table><thead><tr><th>Durum</th><th>Kullanıcı</th><th>Paket</th><th>Son hata</th><th>Son olay</th></tr></thead><tbody>{problems.map((p) => <tr key={p.user_id}><td><Badge tone={p.problem === "paid_not_activated" ? "bad" : "warn"}>{paymentProblemLabel(p.problem)}</Badge></td><td><Link href={`/kullanicilar/${p.user_id}`} className="code">{p.user_id}</Link></td><td>{p.plan_code ? planName(p.plan_code) : "—"}</td><td>{errorCodeLabel(p.error_code) ?? "—"}</td><td>{dateTime(p.last_event_at)}</td></tr>)}</tbody></table></div><Pagination offset={offset} count={problems.length} total={total} href={(next) => `/donusum?days=${days}&offset=${next}`} /></>}
    </section>
  </>;
}
