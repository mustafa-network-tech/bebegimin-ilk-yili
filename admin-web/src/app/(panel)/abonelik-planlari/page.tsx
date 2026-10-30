import { checkGooglePlayCatalogAction } from "@/app/actions/admin";
import { GooglePlayCatalogCheckForm } from "@/components/admin-action-form";
import {
  findGooglePlayItem,
  GooglePlayCheckSummary,
  GooglePlayItemStatus,
} from "@/components/google-play-status";
import { Badge, PageHeader } from "@/components/ui";
import { getGooglePlayCatalogLatest, getPlans } from "@/lib/admin/queries";
import { money, planName } from "@/lib/format";

export default async function PlansPage() {
  const [plans, check] = await Promise.all([getPlans(), getGooglePlayCatalogLatest()]);
  return <>
    <PageHeader
      eyebrow="Katalog"
      title="Abonelik planları"
      description="Sunucu katalog fiyatları ile Google Play ürün ve temel planlarının son doğrulama sonucu. Bu panel Google Play verilerini değiştirmez."
      actions={<GooglePlayCatalogCheckForm action={checkGooglePlayCatalogAction} />}
    />
    <GooglePlayCheckSummary check={check} />
    <section className="section">
      <div className="table-wrap"><table><thead><tr><th>Paket</th><th>Dönem / fiyat</th><th>Kapasite</th><th>Google Play</th><th>Yerel durum</th><th>Google doğrulama</th><th>Abonelikler</th></tr></thead><tbody>
        {plans.map((plan) => {
          const item = findGooglePlayItem(check, "subscription", plan.google_product_id, plan.google_base_plan_id);
          return <tr key={plan.plan_id}>
            <td><strong>{planName(plan.plan_code)}</strong><small>Sürüm {plan.version}</small></td>
            <td><strong>{plan.billing_period === "monthly" ? "Aylık" : "Yıllık"}</strong><small>{money(plan.price_minor, plan.currency)}</small></td>
            <td>2 ebeveyn + {plan.max_family_members} aile üyesi</td>
            <td><strong className="code">{plan.google_product_id || "Eşleme yok"}</strong><small className="code">base plan: {plan.google_base_plan_id || "—"}</small></td>
            <td><Badge tone={plan.catalog_active ? "good" : "neutral"}>{plan.catalog_active ? "Katalogda aktif" : "Pasif"}</Badge></td>
            <td><GooglePlayItemStatus item={item} /></td>
            <td><strong>{plan.access_granting_subscriptions} erişim veren</strong><small>{plan.subscriptions_total} toplam kayıt</small></td>
          </tr>;
        })}
      </tbody></table></div>
    </section>
  </>;
}
