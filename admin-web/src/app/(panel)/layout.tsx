import { AdminShell } from "@/components/admin-shell";
import { requireSuperAdmin } from "@/lib/admin/auth";

export const dynamic = "force-dynamic";

export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  const { user } = await requireSuperAdmin();
  return <AdminShell email={user.email}>{children}</AdminShell>;
}
