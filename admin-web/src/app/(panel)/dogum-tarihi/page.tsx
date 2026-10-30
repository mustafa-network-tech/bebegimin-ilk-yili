import Link from "next/link";

import { correctBirthDateAction } from "@/app/actions/admin";
import { BirthCorrectionForm } from "@/components/admin-action-form";
import { Badge, EmptyState, PageHeader } from "@/components/ui";
import { lookupBabies, previewBirthDate } from "@/lib/admin/queries";
import { date, statusLabel } from "@/lib/format";

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };
const v = (x: string | string[] | undefined) => typeof x === "string" ? x : "";

export default async function BirthDatePage({ searchParams }: Props) {
  const p = await searchParams;
  const q = v(p.q).slice(0, 60);
  const babyId = v(p.baby);
  const newDate = v(p.date);
  const results = q.length >= 2 ? await lookupBabies(q) : [];
  const selected = results.find((baby) => baby.baby_id === babyId);
  const preview = selected && /^\d{4}-\d{2}-\d{2}$/.test(newDate) ? (await previewBirthDate(selected.baby_id, newDate))[0] : null;
  return <><PageHeader eyebrow="Destek işlemleri" title="Doğum tarihi düzeltmesi" description="Bebeği arayın, değişikliğin lifecycle etkisini önizleyin ve gerekçeli olarak uygulayın." /><section className="card"><form className="filter-bar" method="get"><input name="q" defaultValue={q} minLength={2} maxLength={60} required placeholder="En az 2 karakter veya bebek UUID" /><button className="button primary" type="submit">Bebek ara</button></form>{q.length > 0 && q.length < 2 && <p className="form-message error">En az 2 karakter yazın.</p>}{q.length >= 2 && results.length === 0 && <EmptyState title="Bebek bulunamadı" text="Adı veya UUID’yi kontrol edin." />}{results.length > 0 && <div className="table-wrap"><table><thead><tr><th>Bebek</th><th>Mevcut doğum tarihi</th><th>Lifecycle</th><th>İçerik</th><th></th></tr></thead><tbody>{results.map((baby) => <tr key={baby.baby_id}><td><strong>{baby.first_name}</strong><small className="code">{baby.baby_id}</small></td><td>{date(baby.birth_date)}</td><td><Badge tone={baby.status === "ACTIVE" ? "good" : "neutral"}>{baby.status}</Badge><small>Kapanış: {date(baby.effective_close_date)}</small></td><td>{baby.content_count}</td><td><Link className="button secondary" href={`/dogum-tarihi?${new URLSearchParams({ q, baby: baby.baby_id })}`}>Seç</Link></td></tr>)}</tbody></table></div>}</section>{selected && <section className="section detail-grid"><article className="card"><p className="eyebrow">Seçilen profil</p><h2>{selected.first_name}</h2><dl className="facts"><dt>Mevcut doğum tarihi</dt><dd>{date(selected.birth_date)}</dd><dt>Mevcut durum</dt><dd>{selected.status}</dd><dt>Etkin kapanış</dt><dd>{date(selected.effective_close_date)}</dd><dt>Onaylı uzatma</dt><dd>{selected.approved_extension_days} gün</dd></dl><form className="stack-form" method="get"><input type="hidden" name="q" value={q} /><input type="hidden" name="baby" value={selected.baby_id} /><label>Yeni doğum tarihi<input name="date" type="date" defaultValue={newDate} max={new Date().toISOString().slice(0, 10)} required /></label><button className="button secondary" type="submit">Etkisini önizle</button></form></article><article className="card"><p className="eyebrow">Güvenli önizleme</p>{preview ? <><h2>{statusLabel(preview.status_before.toLowerCase())} → {statusLabel(preview.status_after.toLowerCase())}</h2><dl className="facts"><dt>Önce</dt><dd>{date(preview.birth_date_before)}</dd><dt>Sonra</dt><dd>{date(preview.birth_date_after)}</dd><dt>Eski kapanış</dt><dd>{date(preview.effective_close_before)}</dd><dt>Yeni kapanış</dt><dd>{date(preview.effective_close_after)}</dd></dl>{preview.would_reopen && <p className="notice">Bu düzeltme kilitli profili yeniden açacak.</p>}{preview.would_lock && <p className="notice danger-notice">Bu düzeltme profili kilitleyecek.</p>}<BirthCorrectionForm action={correctBirthDateAction} babyId={selected.baby_id} birthDate={newDate} wouldReopen={preview.would_reopen} /></> : <EmptyState title="Önizleme bekleniyor" text="Yeni tarihi seçerek lifecycle sonucunu doğrulayın." />}</article></section>}</>;
}
