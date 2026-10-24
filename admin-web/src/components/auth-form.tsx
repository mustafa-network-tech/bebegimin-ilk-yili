"use client";

import Link from "next/link";
import { useActionState } from "react";

import type { AuthState } from "@/app/actions/auth";

type Props = {
  action: (state: AuthState, formData: FormData) => Promise<AuthState>;
  kind: "login" | "forgot" | "reset";
};

const initialState: AuthState = {};

export function AuthForm({ action, kind }: Props) {
  const [state, formAction, pending] = useActionState(action, initialState);
  return (
    <form action={formAction} className="auth-form">
      {kind !== "reset" && (
        <label>
          E-posta
          <input name="email" type="email" autoComplete="email" required placeholder="ornek@adres.com" />
        </label>
      )}
      {kind !== "forgot" && (
        <label>
          {kind === "reset" ? "Yeni şifre" : "Şifre"}
          <input name="password" type="password" autoComplete={kind === "reset" ? "new-password" : "current-password"} required minLength={8} />
        </label>
      )}
      {kind === "reset" && (
        <label>
          Yeni şifre tekrar
          <input name="confirmation" type="password" autoComplete="new-password" required minLength={8} />
        </label>
      )}
      {state.error && <p className="form-message error">{state.error}</p>}
      {state.success && <p className="form-message success">{state.success}</p>}
      <button className="button primary" type="submit" disabled={pending}>
        {pending ? "İşleniyor…" : kind === "login" ? "Giriş yap" : kind === "forgot" ? "Bağlantı gönder" : "Şifreyi güncelle"}
      </button>
      {kind === "login" && <Link href="/sifremi-unuttum">Şifremi unuttum</Link>}
      {kind !== "login" && <Link href="/giris">Giriş ekranına dön</Link>}
    </form>
  );
}
