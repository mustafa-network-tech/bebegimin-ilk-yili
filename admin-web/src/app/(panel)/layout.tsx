import { AdminShell } from "@/components/admin-shell";
import { requireSuperAdmin } from "@/lib/admin/auth";
import { getPendingSignupCount } from "@/lib/admin/queries";

export const dynamic = "force-dynamic";

export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  const { user } = await requireSuperAdmin();
  // The menu counter must never break a page: a failed count simply hides the badge.
  const pendingSignups = await getPendingSignupCount().catch(() => 0);
  return <AdminShell email={user.email} pendingSignups={Number(pendingSignups) || 0}>{children}</AdminShell>;
}
