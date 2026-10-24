"use client";

import { useActionState } from "react";

import type { ActionState } from "@/app/actions/admin";

const initialState: ActionState = {};

export function ExtensionActionForm({
  action,
  requestId,
}: {
  action: (state: ActionState, data: FormData) => Promise<ActionState>;
  requestId: string;
}) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="inline-action-form">
      <input type="hidden" name="request_id" value={requestId} />
      <textarea name="note" maxLength={2000} rows={2} placeholder="Karar notu (ret için zorunlu)" />
      {state.error && <span className="form-message error">{state.error}</span>}
      {state.success && <span className="form-message success">{state.success}</span>}
      <div className="button-row">
        <button className="button secondary" name="decision" value="rejected" disabled={pending}>Reddet</button>
        <button className="button primary" name="decision" value="approved" disabled={pending}>Onayla</button>
      </div>
    </form>
  );
}

export function BirthCorrectionForm({
  action,
  babyId,
  birthDate,
  wouldReopen,
}: {
  action: (state: ActionState, data: FormData) => Promise<ActionState>;
  babyId: string;
  birthDate: string;
  wouldReopen: boolean;
}) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="stack-form">
      <input type="hidden" name="baby_id" value={babyId} />
      <input type="hidden" name="birth_date" value={birthDate} />
      <label>
        Düzeltme gerekçesi
        <textarea name="reason" required minLength={3} maxLength={2000} rows={4} placeholder="Belge veya destek kaydıyla doğrulanan gerekçe" />
      </label>
      {wouldReopen && (
        <label className="check-row">
          <input name="confirm_reopen" type="checkbox" required />
          Bu düzeltmenin kilitli profili yeniden açacağını anlıyorum.
        </label>
      )}
      {state.error && <p className="form-message error">{state.error}</p>}
      {state.success && <p className="form-message success">{state.success}</p>}
      <button className="button primary" type="submit" disabled={pending}>{pending ? "Kaydediliyor…" : "Düzeltmeyi uygula"}</button>
    </form>
  );
}
