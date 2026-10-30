import { redirect } from "next/navigation";

import { getAdminSession } from "@/lib/admin/auth";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  const { user, admin } = await getAdminSession();
  if (!user) redirect("/giris");
  if (!admin?.is_super_admin) redirect("/yetkisiz");
  redirect(admin.console_enabled ? "/dashboard" : "/panel-kapali");
}
