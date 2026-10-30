"use client";

import { useActionState, useState } from "react";

import type { ActionState } from "@/app/actions/admin";

const initialState: ActionState = {};
type Action = (state: ActionState, data: FormData) => Promise<ActionState>;

function Messages({ state }: { state: ActionState }) {
  return <>
    {state.error && <p className="form-message error">{state.error}</p>}
    {state.success && <p className="form-message success">{state.success}</p>}
  </>;
}

export function GrantTrialForm({ action, userId, hadTrial }: { action: Action; userId: string; hadTrial: boolean }) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="stack-form">
      <input type="hidden" name="user_id" value={userId} />
      <label>
        Gerekçe
        <textarea name="reason" required minLength={3} maxLength={500} rows={2} placeholder="Örn. ilk üyelik denemesi" />
      </label>
      {hadTrial && (
        <label className="check-row">
          <input name="allow_repeat" type="checkbox" />
          Bu kullanıcı daha önce deneme almış; bilinçli olarak yeniden veriyorum.
        </label>
      )}
      <Messages state={state} />
      <button className="button primary" type="submit" disabled={pending}>{pending ? "Kaydediliyor…" : "72 saatlik deneme ver"}</button>
    </form>
  );
}

export function RevokeTrialForm({ action, userId }: { action: Action; userId: string }) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="stack-form">
      <input type="hidden" name="user_id" value={userId} />
      <label>
        Sonlandırma gerekçesi
        <textarea name="reason" required minLength={3} maxLength={500} rows={2} />
      </label>
      <Messages state={state} />
      <button className="button secondary" type="submit" disabled={pending}>{pending ? "Kaydediliyor…" : "Denemeyi sonlandır"}</button>
    </form>
  );
}

export function MarkSentForm({
  action,
  userId,
  template,
  trialId,
  label,
}: {
  action: Action;
  userId: string;
  template: "welcome" | "trial_activated";
  trialId?: string | null;
  label: string;
}) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="inline-action-form">
      <input type="hidden" name="user_id" value={userId} />
      <input type="hidden" name="template" value={template} />
      {trialId && <input type="hidden" name="trial_id" value={trialId} />}
      <Messages state={state} />
      <button className="button primary" type="submit" disabled={pending}>{pending ? "Kaydediliyor…" : label}</button>
    </form>
  );
}

export function TemplateForm({
  action,
  kind,
  subject,
  body,
}: {
  action: Action;
  kind: "welcome" | "trial_activated";
  subject: string;
  body: string;
}) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="stack-form">
      <input type="hidden" name="kind" value={kind} />
      <label>
        Konu
        <input name="subject" defaultValue={subject} maxLength={200} placeholder="E-posta konusu" />
      </label>
      <label>
        Metin
        <textarea name="body" defaultValue={body} maxLength={10000} rows={12} placeholder="E-posta metni (düz metin)" />
      </label>
      <Messages state={state} />
      <button className="button primary" type="submit" disabled={pending}>{pending ? "Kaydediliyor…" : "Şablonu kaydet"}</button>
    </form>
  );
}

/** Copy helpers for the manual e-mail (the system never sends anything). */
export function CopyButton({ text, label }: { text: string; label: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className="button secondary"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setDone(true);
          setTimeout(() => setDone(false), 1500);
        } catch {
          setDone(false);
        }
      }}
    >
      {done ? "Kopyalandı" : label}
    </button>
  );
}
