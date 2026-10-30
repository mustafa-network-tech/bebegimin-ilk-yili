import "server-only";

import { requireSuperAdmin } from "./auth";
import type {
  AuditRow,
  BabyLookupRow,
  BirthPreview,
  ConversionFunnel,
  DashboardSummary,
  ExtensionRow,
  GooglePlayCatalogCheckRow,
  PaymentEventRow,
  PaymentProblemRow,
  PlanRow,
  PlatformAuditRow,
  ProductRow,
  PurchaseRow,
  SubscriptionRow,
  TestAccessEventRow,
  TestAccessUserRow,
  UserActivityRow,
  UserActivitySummary,
  UserFamilyRow,
} from "./types";
import { createServerSupabase } from "@/lib/supabase/server";

async function rpc<T>(name: string, params?: Record<string, unknown>): Promise<T> {
  await requireSuperAdmin();
  const supabase = await createServerSupabase();
  const { data, error } = await supabase.rpc(name, params);
  if (error) throw new Error(error.message);
  return data as T;
}

export const getDashboard = () => rpc<DashboardSummary>("admin_dashboard_summary");
export const getUsersFamilies = (search: string | null, status: string, offset: number) =>
  rpc<UserFamilyRow[]>("admin_users_families", {
    p_search: search,
    p_status: status,
    p_limit: 50,
    p_offset: offset,
  });
export const getPlans = () => rpc<PlanRow[]>("admin_subscription_plans");
export const getSubscriptions = (status: string, plan: string | null, search: string | null, offset: number) =>
  rpc<SubscriptionRow[]>("admin_subscriptions", {
    p_status: status,
    p_plan_code: plan,
    p_search: search,
    p_limit: 50,
    p_offset: offset,
  });
export const getProducts = () => rpc<ProductRow[]>("admin_premium_products");
export const getGooglePlayCatalogLatest = async () =>
  (await rpc<GooglePlayCatalogCheckRow[]>("admin_google_play_catalog_latest"))[0] ?? null;
export const getPurchases = (status: string, product: string | null, search: string | null, offset: number) =>
  rpc<PurchaseRow[]>("admin_purchase_records", {
    p_status: status,
    p_product_code: product,
    p_search: search,
    p_limit: 50,
    p_offset: offset,
  });
export const getPaymentEvents = (kind: string, result: string | null, offset: number) =>
  rpc<PaymentEventRow[]>("admin_payment_events", {
    p_kind: kind,
    p_result: result,
    p_limit: 50,
    p_offset: offset,
  });
export const getExtensions = (status: string, search: string | null, offset: number) =>
  rpc<ExtensionRow[]>("admin_extension_queue", {
    p_status: status,
    p_search: search,
    p_limit: 50,
    p_offset: offset,
  });
export const lookupBabies = (query: string) => rpc<BabyLookupRow[]>("admin_baby_lookup", { p_query: query, p_limit: 20 });
export const previewBirthDate = (babyId: string, birthDate: string) =>
  rpc<BirthPreview[]>("admin_preview_birth_date_correction", { p_baby_id: babyId, p_birth_date: birthDate });
export const getAuditLog = (action: string | null, offset: number) =>
  rpc<AuditRow[]>("admin_audit_log", {
    p_action: action,
    p_baby_id: null,
    p_limit: 50,
    p_offset: offset,
  });
export const getPlatformAuditLog = (source: string, offset: number) =>
  rpc<PlatformAuditRow[]>("admin_platform_audit_log", { p_source: source, p_limit: 50, p_offset: offset });
export const getTestAccessUsers = (search: string | null, status: string, offset: number) =>
  rpc<TestAccessUserRow[]>("admin_test_access_users", {
    p_search: search,
    p_status: status,
    p_limit: 50,
    p_offset: offset,
  });
export const getTestAccessEvents = (offset: number) =>
  rpc<TestAccessEventRow[]>("admin_test_access_events", { p_user_id: null, p_limit: 50, p_offset: offset });

export const getUserActivity = (userId: string, offset: number) =>
  rpc<UserActivityRow[]>("admin_user_activity", { p_user_id: userId, p_limit: 50, p_offset: offset });
export const getUserActivitySummary = async (userId: string) =>
  (await rpc<UserActivitySummary[]>("admin_user_activity_summary", { p_user_id: userId }))[0] ?? null;
export const getConversionFunnel = async (days: number) =>
  (await rpc<ConversionFunnel[]>("admin_conversion_funnel", { p_days: days }))[0] ?? null;
export const getPaymentProblems = (offset: number) =>
  rpc<PaymentProblemRow[]>("admin_payment_problems", { p_limit: 50, p_offset: offset });
