import { saveEmailTemplateAction } from "@/app/actions/signups";
import { TemplateForm } from "@/components/signup-forms";
import { PageHeader } from "@/components/ui";
import { getEmailTemplates } from "@/lib/admin/queries";
import { dateTime } from "@/lib/format";

const TITLES: Record<string, readonly [string, string]> = {
  welcome: ["Hoş geldin e-postası", "Yeni kayıt olan kullanıcıya gönderdiğiniz karşılama metni."],
  trial_activated: ["Deneme erişimi aktif edildi e-postası", "72 saatlik deneme tanımladığınız kullanıcıya gönderdiğiniz metin."],
} as const;

export default async function EmailTemplatesPage() {
  const templates = await getEmailTemplates();
  return <>
    <PageHeader
      eyebrow="Karşılama"
      title="E-posta şablonları"
      description="Metinleri siz yazar ve düzenlersiniz. Düz metindir (HTML yorumlanmaz). Kullanabileceğiniz yer tutucular: {{ad}} ve {{deneme_bitis}}. Sistem e-posta göndermez; metin Yeni kayıtlar sayfasında kopyalanıp elle gönderilir."
    />
    {templates.map((t) => (
      <section className="card section" key={t.kind}>
        <div className="section-head">
          <div><h2>{TITLES[t.kind][0]}</h2><p>{TITLES[t.kind][1]}</p></div>
          <span className="badge neutral">{t.version === 0 ? "Henüz kaydedilmedi" : `Sürüm ${t.version} · ${dateTime(t.updated_at)}${t.updated_by_name ? ` · ${t.updated_by_name}` : ""}`}</span>
        </div>
        <TemplateForm action={saveEmailTemplateAction} kind={t.kind} subject={t.subject} body={t.body} />
      </section>
    ))}
  </>;
}
