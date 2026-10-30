import "server-only";

import { cache } from "react";
import { redirect } from "next/navigation";

import { createServerSupabase } from "@/lib/supabase/server";

export type AdminSession = {
  is_super_admin: boolean;
  console_enabled: boolean;
};

export const getAdminSession = cache(async () => {
  const supabase = await createServerSupabase();
  const { data: auth, error: authError } = await supabase.auth.getUser();
  if (authError || !auth.user) return { user: null, admin: null };

  const { data, error } = await supabase.rpc("admin_session");
  if (error) throw new Error("Yönetici yetkisi doğrulanamadı.");
  const admin = ((data as AdminSession[] | null)?.[0] ?? null) as AdminSession | null;
  return { user: auth.user, admin };
});

export async function requireSuperAdmin(options: { requireConsole?: boolean } = {}) {
  const { user, admin } = await getAdminSession();
  if (!user) redirect("/giris");
  if (!admin?.is_super_admin) redirect("/yetkisiz");
  if ((options.requireConsole ?? true) && !admin.console_enabled) redirect("/panel-kapali");
  return { user, admin };
}
