"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { createServerSupabase } from "@/lib/supabase/server";

export type AuthState = { error?: string; success?: string };

export async function loginAction(_: AuthState, formData: FormData): Promise<AuthState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!email || !password) return { error: "E-posta ve şifre zorunludur." };

  const supabase = await createServerSupabase();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) return { error: "E-posta veya şifre hatalı." };

  const { data, error: roleError } = await supabase.rpc("admin_session");
  const admin = (data as Array<{ is_super_admin: boolean; console_enabled: boolean }> | null)?.[0];
  if (roleError || !admin?.is_super_admin) {
    await supabase.auth.signOut({ scope: "local" });
    return { error: "Bu hesap platform yöneticisi yetkisine sahip değil." };
  }
  redirect(admin.console_enabled ? "/dashboard" : "/panel-kapali");
}

export async function logoutAction() {
  const supabase = await createServerSupabase();
  await supabase.auth.signOut({ scope: "local" });
  redirect("/giris");
}

export async function forgotPasswordAction(_: AuthState, formData: FormData): Promise<AuthState> {
  const email = String(formData.get("email") ?? "").trim();
  if (!email) return { error: "E-posta adresini yazın." };
  const requestHeaders = await headers();
  const origin = process.env.NEXT_PUBLIC_ADMIN_URL || requestHeaders.get("origin") || "http://localhost:3000";
  const supabase = await createServerSupabase();
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${origin}/auth/callback?next=/sifre-yenile`,
  });
  if (error) return { error: "Şifre sıfırlama bağlantısı gönderilemedi." };
  return { success: "Hesap mevcutsa şifre sıfırlama bağlantısı gönderildi." };
}

export async function updatePasswordAction(_: AuthState, formData: FormData): Promise<AuthState> {
  const password = String(formData.get("password") ?? "");
  const confirmation = String(formData.get("confirmation") ?? "");
  if (password.length < 8) return { error: "Şifre en az 8 karakter olmalıdır." };
  if (password !== confirmation) return { error: "Şifreler eşleşmiyor." };
  const supabase = await createServerSupabase();
  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: "Şifre güncellenemedi." };
  return { success: "Şifreniz güncellendi. Yönetim paneline dönebilirsiniz." };
}
