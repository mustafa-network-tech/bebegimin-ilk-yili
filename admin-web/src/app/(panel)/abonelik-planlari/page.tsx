import { Badge, PageHeader } from "@/components/ui";
import { getPlans } from "@/lib/admin/queries";
import { money, planName } from "@/lib/format";

export default async function PlansPage() {
  const plans = await getPlans();
  return <><PageHeader eyebrow="Katalog" title="Abonelik planları" description="Sunucu katalog fiyatları ve Google Play ürün eşlemeleri. Google Play fiyatları bu panelden değiştirilmez." /><div className="notice">Buradaki tutarlar sunucu kataloğudur. Gerçek mağaza fiyatı Play Console’da ayrıca doğrulanmalı ve yönetilmelidir.</div><section className="section"><div className="table-wrap"><table><thead><tr><th>Paket</th><th>Dönem / fiyat</th><th>Kapasite</th><th>Google Play</th><th>Durum</th><th>Abonelikler</th></tr></thead><tbody>{plans.map((plan) => <tr key={plan.plan_id}><td><strong>{planName(plan.plan_code)}</strong><small>Sürüm {plan.version}</small></td><td><strong>{plan.billing_period === "monthly" ? "Aylık" : "Yıllık"}</strong><small>{money(plan.price_minor, plan.currency)}</small></td><td>2 ebeveyn + {plan.max_family_members} aile üyesi</td><td><strong className="code">{plan.google_product_id || "Eşleme yok"}</strong><small className="code">base plan: {plan.google_base_plan_id || "—"}</small></td><td><Badge tone={plan.catalog_active ? "good" : "neutral"}>{plan.catalog_active ? "Katalogda aktif" : "Pasif"}</Badge><small>Play durumu doğrulanmadı</small></td><td><strong>{plan.access_granting_subscriptions} erişim veren</strong><small>{plan.subscriptions_total} toplam kayıt</small></td></tr>)}</tbody></table></div></section></>;
}
