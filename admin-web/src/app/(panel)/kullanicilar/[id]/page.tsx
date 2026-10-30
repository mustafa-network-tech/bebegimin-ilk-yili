import Link from "next/link";
import { notFound } from "next/navigation";

import { Badge, EmptyState, PageHeader, Pagination, StatCard } from "@/components/ui";
import { getUserActivity, getUserActivitySummary, getUsersFamilies } from "@/lib/admin/queries";
import { dateTime, errorCodeLabel, eventLabel, paymentProblemLabel, planName, platformLabel, statusLabel } from "@/lib/format";

type Props = {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function UserActivityPage({ params, searchParams }: Props) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const sp = await searchParams;
  const offset = Math.max(0, Number(typeof sp.offset === "string" ? sp.offset : 0) || 0);
  const [summary, events, users] = await Promise.all([
    getUserActivitySummary(id).catch(() => null),
    getUserActivity(id, offset).catch(() => null),
    getUsersFamilies(id, "all", 0),
  ]);
  if (!summary || !events) notFound();
  const user = users[0];
  const total = events[0]?.total_count ?? 0;
  const journey: Array<[string, string | null, string?]> = [
    ["Kayıt", summary.registered_at],
    ["E-posta doğrulama", summary.email_verified_at],
    ["Aile hesabı", summary.family_created_at],
    ["Bebek profili", summary.baby_added_at],
    ["Paketler görüntülendi", summary.plans_viewed_at, "Uygulama güncellemesinden sonra izlenir"],
    ["Paket seçimi", summary.plan_selected_at, "Uygulama güncellemesinden sonra izlenir"],
    ["Ödeme başlatma", summary.checkout_started_at],
    ["Ödeme doğrulandı", summary.payment_verified_at],
    ["Abonelik etkinleşti", summary.activated_at],
  ];
  return <>
    <PageHeader eyebrow="Hareket geçmişi" title={user?.display_name || "İsimsiz kullanıcı"} description={`${user?.email ?? "E-posta yok"} · ${id}`} actions={<Link className="button secondary" href="/kullanicilar">Kullanıcılara dön</Link>} />
    {summary.payment_problem && <div className="notice"><strong>{paymentProblemLabel(summary.payment_problem)}</strong><br />{summary.payment_problem === "paid_not_activated" ? "Mağaza ödemeyi onayladı ancak aile hesabında erişim açılmadı. Mağaza satın almayı yeniden teslim ettikçe doğrulama tekrarlanır; sürerse nedeni aşağıdaki hata kodundan inceleyin." : "Mağaza ile bağlantı kurulamadı veya satın alma sorgulanamadı. Bu kayıt tek başına ödeme yapıldığı anlamına gelmez."}</div>}
    <div className="stats-grid">
      <StatCard label="Son etkinlik" value={dateTime(summary.last_activity_at)} />
      <StatCard label="Abonelik durumu" value={summary.subscription_status ? statusLabel(summary.subscription_status) : "Abonelik yok"} detail={summary.subscription_plan_code ? planName(summary.subscription_plan_code) : undefined} />
      <StatCard label="Ödeme denemesi" value={summary.has_payment_attempt ? "Var" : "Yok"} />
      <StatCard label="Başarılı / başarısız ödeme" value={`${summary.payment_success_count} / ${summary.payment_failure_count}`} detail="Başarısız sayısı yalnız izleme başladıktan sonrakileri kapsar" tone={summary.payment_failure_count ? "warn" : ""} />
    </div>
    <section className="section"><div className="section-head"><h2>Abonelik yolculuğu</h2></div>
      <div className="table-wrap"><table><thead><tr><th>Aşama</th><th>Tarih</th></tr></thead><tbody>{journey.map(([label, at, note]) => <tr key={label}><td>{label}</td><td>{at ? dateTime(at) : <small>{note ?? "Kayıt yok"}</small>}</td></tr>)}</tbody></table></div>
    </section>
    <section className="section"><div className="section-head"><div><h2>Hareketler</h2><p>İzleme {dateTime(summary.tracking_started_at)} tarihinde başladı. Öncesi yalnızca mevcut kayıtlardan doğrulanabilen olaylardır; geçmiş için tahmin üretilmez.</p></div></div>
      {events.length === 0 ? <EmptyState title="Hareket yok" text="Bu kullanıcı için kayıtlı olay bulunamadı." /> : <><div className="table-wrap"><table><thead><tr><th>Olay</th><th>Zaman</th><th>Platform</th><th>Paket</th><th>Durum</th><th>Kaynak</th></tr></thead><tbody>{events.map((e, i) => <tr key={`${e.event_type}-${e.occurred_at}-${i}`}><td><strong>{eventLabel(e.event_type)}</strong>{e.error_code && <small>{errorCodeLabel(e.error_code)} <span className="code">({e.error_code})</span></small>}{e.scope === "family" && <small>Aile hesabı olayı</small>}</td><td>{dateTime(e.occurred_at)}</td><td>{platformLabel(e.platform)}</td><td>{e.plan_code ? planName(e.plan_code) : "—"}</td><td><Badge tone={e.status === "failed" ? "bad" : e.status === "pending" ? "warn" : "good"}>{e.status === "failed" ? "Başarısız" : e.status === "pending" ? "Bekliyor" : "Tamam"}</Badge></td><td>{e.source === "recorded" ? "İzleme kaydı" : "Mevcut kayıttan"}</td></tr>)}</tbody></table></div><Pagination offset={offset} count={events.length} total={total} href={(next) => `/kullanicilar/${id}?offset=${next}`} /></>}
    </section>
  </>;
}
