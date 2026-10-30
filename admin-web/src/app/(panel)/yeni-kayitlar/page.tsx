import Link from "next/link";

import { grantTrialAction } from "@/app/actions/signups";
import { markEmailSentAction } from "@/app/actions/signups";
import { CopyButton, GrantTrialForm, MarkSentForm } from "@/components/signup-forms";
import { Badge, EmptyState, PageHeader, Pagination } from "@/components/ui";
import { getEmailTemplates, getNewSignups } from "@/lib/admin/queries";
import { mailtoHref, renderTemplate } from "@/lib/email-template";
import { dateTime } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const value = (v: string | string[] | undefined) => (typeof v === "string" ? v : "");
const FILTERS = [["pending", "Bekleyenler"], ["sent", "Gönderilenler"], ["all", "Tümü"]] as const;

export default async function NewSignupsPage({ searchParams }: Props) {
  const params = await searchParams;
  const status = ["pending", "sent", "all"].includes(value(params.status)) ? value(params.status) : "pending";
  const offset = Math.max(0, Number(value(params.offset)) || 0);
  const [rows, templates] = await Promise.all([getNewSignups(status, offset), getEmailTemplates()]);
  const total = rows[0]?.total_count ?? 0;
  const welcome = templates.find((t) => t.kind === "welcome");
  const trialMail = templates.find((t) => t.kind === "trial_activated");

  return <>
    <PageHeader
      eyebrow="Karşılama"
      title="Yeni kayıtlar"
      description="Kayıt olan kullanıcılar otomatik olarak bekleyen listesine girer. E-postayı sistem göndermez: metni kopyalayıp kendi e-posta hesabınızdan gönderir, ardından burada işaretlersiniz."
      actions={<Link className="button secondary" href="/e-posta-sablonlari">E-posta şablonları</Link>}
    />
    <nav className="filter-bar" aria-label="Durum">
      {FILTERS.map(([key, label]) => (
        <Link key={key} className={`button ${key === status ? "primary" : "secondary"}`} href={`/yeni-kayitlar?status=${key}`}>{label}</Link>
      ))}
    </nav>
    {rows.length === 0 ? (
      <EmptyState title={status === "pending" ? "Bekleyen kayıt yok" : "Kayıt bulunamadı"} text="Bu liste yalnızca özelliğin devreye girdiği tarihten sonra kayıt olan kullanıcıları içerir; eski kullanıcılar yeni kayıt olarak görünmez." />
    ) : <>
      {rows.map((row) => {
        const vars = { ad: row.display_name || "", deneme_bitis: row.trial_ends_at ? dateTime(row.trial_ends_at) : "" };
        const welcomeSubject = renderTemplate(welcome?.subject ?? "", vars);
        const welcomeBody = renderTemplate(welcome?.body ?? "", vars);
        const trialSubject = renderTemplate(trialMail?.subject ?? "", vars);
        const trialBody = renderTemplate(trialMail?.body ?? "", vars);
        const welcomeMailto = mailtoHref(row.email, welcomeSubject, welcomeBody);
        const trialMailto = mailtoHref(row.email, trialSubject, trialBody);
        return (
          <article className="card section" key={row.user_id}>
            <div className="section-head">
              <div>
                <h2>{row.display_name || "İsimsiz kullanıcı"}</h2>
                <p>{row.email ?? "E-posta yok"} · <span className="code">{row.user_id}</span></p>
              </div>
              <div className="button-row">
                <Badge tone={row.email_verified_at ? "good" : "warn"}>{row.email_verified_at ? "E-posta doğrulandı" : "E-posta doğrulanmadı"}</Badge>
                <Badge tone={row.welcome_marked_at ? "good" : "warn"}>{row.welcome_marked_at ? `Hoş geldin gönderildi · ${dateTime(row.welcome_marked_at)}` : "Hoş geldin bekliyor"}</Badge>
                <Badge tone={row.trial_status === "live" ? "good" : "neutral"}>
                  {row.trial_status === "none" ? "Deneme yok" : row.trial_status === "live" ? `Deneme · ${dateTime(row.trial_ends_at)} bitiş` : row.trial_status === "revoked" ? "Deneme sonlandırıldı" : "Deneme bitti"}
                </Badge>
              </div>
            </div>
            <p><small>Kayıt: {dateTime(row.signed_up_at)}{row.welcome_marked_by_name ? ` · işaretleyen: ${row.welcome_marked_by_name}` : ""}</small></p>

            <details>
              <summary>Hoş geldin e-postası hazırla</summary>
              {!welcomeBody && !welcomeSubject && <div className="notice">Şablon henüz boş. <Link href="/e-posta-sablonlari">Şablonu yazın</Link>.</div>}
              <p><strong>Konu:</strong> {welcomeSubject || "—"}</p>
              <pre className="mail-preview">{welcomeBody || "—"}</pre>
              <div className="button-row">
                <CopyButton text={row.email ?? ""} label="Adresi kopyala" />
                <CopyButton text={welcomeSubject} label="Konuyu kopyala" />
                <CopyButton text={welcomeBody} label="Metni kopyala" />
                {welcomeMailto && <a className="button secondary" href={welcomeMailto}>E-posta uygulamasında aç</a>}
              </div>
              {!row.welcome_marked_at && <MarkSentForm action={markEmailSentAction} userId={row.user_id} template="welcome" label="Gönderildi olarak işaretle" />}
            </details>

            {row.trial_status === "live" && row.trial_id && (
              <details>
                <summary>Deneme e-postası hazırla</summary>
                <p><strong>Konu:</strong> {trialSubject || "—"}</p>
                <pre className="mail-preview">{trialBody || "—"}</pre>
                <div className="button-row">
                  <CopyButton text={trialSubject} label="Konuyu kopyala" />
                  <CopyButton text={trialBody} label="Metni kopyala" />
                  {trialMailto && <a className="button secondary" href={trialMailto}>E-posta uygulamasında aç</a>}
                </div>
                {row.trial_email_marked_at
                  ? <p><small>Gönderildi olarak işaretlendi · {dateTime(row.trial_email_marked_at)}</small></p>
                  : <MarkSentForm action={markEmailSentAction} userId={row.user_id} template="trial_activated" trialId={row.trial_id} label="Deneme e-postası gönderildi" />}
              </details>
            )}

            {row.trial_status !== "live" && (
              <details>
                <summary>72 saatlik deneme ver</summary>
                <GrantTrialForm action={grantTrialAction} userId={row.user_id} hadTrial={row.trial_status !== "none"} />
              </details>
            )}
            <p><Link href={`/kullanicilar/${row.user_id}`}>Hareket geçmişi</Link></p>
          </article>
        );
      })}
      <Pagination offset={offset} count={rows.length} total={total} href={(next) => `/yeni-kayitlar?${new URLSearchParams({ status, offset: String(next) })}`} />
    </>}
  </>;
}
