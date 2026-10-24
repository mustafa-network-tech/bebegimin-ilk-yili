export type DashboardSummary = {
  users_total: number;
  families_active: number;
  babies_total: number;
  subscriptions_access_granting: number;
  subscriptions_past_due: number;
  subscriptions_over_capacity: number;
  premium_orders_paid: number;
  premium_entitlements_active: number;
  extension_requests_pending: number;
  payment_events_rejected_24h: number;
  generated_at: string;
};

export type UserFamilyRow = {
  user_id: string;
  email: string | null;
  display_name: string | null;
  user_created_at: string;
  family_count: number;
  families: Array<{
    id: string;
    display_name: string;
    account_status: string;
    member_role: string;
    member_status: string;
    baby_count: number;
  }>;
  total_count: number;
};

export type PlanRow = {
  plan_id: string;
  plan_code: string;
  billing_period: string;
  version: number;
  max_parent_seats: number;
  max_family_members: number;
  price_minor: number;
  currency: string;
  active_from: string;
  active_until: string | null;
  catalog_active: boolean;
  google_product_id: string | null;
  google_base_plan_id: string | null;
  app_store_product_id: string | null;
  access_granting_subscriptions: number;
  subscriptions_total: number;
};

export type SubscriptionRow = {
  subscription_id: string;
  family_account_id: string;
  family_name: string;
  parent_count: number;
  family_member_count: number;
  baby_count: number;
  plan_code: string;
  billing_period: string;
  status: string;
  provider: string;
  provider_reference_masked: string;
  current_period_start: string | null;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
  over_capacity: boolean;
  updated_at: string;
  total_count: number;
};

export type ProductRow = {
  product_id: string;
  product_code: string;
  version: number;
  price_minor: number;
  currency: string;
  delivery_format: string;
  active_from: string;
  active_until: string | null;
  catalog_active: boolean;
  storefront_enabled: boolean;
  google_product_id: string | null;
  app_store_product_id: string | null;
  paid_orders: number;
  refunded_or_revoked_orders: number;
  active_entitlements: number;
};

export type PurchaseRow = {
  order_id: string;
  family_account_id: string;
  family_name: string;
  baby_id: string;
  baby_first_name: string;
  product_code: string;
  price_minor: number;
  currency: string;
  provider: string;
  provider_reference_masked: string | null;
  status: string;
  requested_by_name: string;
  paid_at: string | null;
  created_at: string;
  updated_at: string;
  total_count: number;
};

export type PaymentEventRow = {
  event_kind: string;
  event_id: number;
  provider: string;
  provider_event_reference_masked: string;
  event_type: string;
  related_id: string | null;
  result: string | null;
  error_summary: string | null;
  received_at: string;
  total_count: number;
};

export type ExtensionRow = {
  request_id: string;
  baby_id: string;
  baby_first_name: string;
  requested_days: number;
  status: string;
  requested_by_name: string;
  requested_at: string;
  base_close_date: string;
  days_until_base_close: number;
  sla: string | null;
  decided_by_name: string | null;
  decided_at: string | null;
  decision_note: string | null;
  total_count: number;
};

export type BabyLookupRow = {
  baby_id: string;
  first_name: string;
  birth_date: string;
  status: string;
  base_close_date: string;
  effective_close_date: string;
  approved_extension_days: number;
  extension_status: string | null;
  content_count: number;
};

export type BirthPreview = {
  birth_date_before: string;
  birth_date_after: string;
  status_before: string;
  status_after: string;
  base_close_before: string;
  base_close_after: string;
  effective_close_before: string;
  effective_close_after: string;
  approved_extension_days: number;
  would_reopen: boolean;
  would_lock: boolean;
};

export type AuditRow = {
  id: number;
  created_at: string;
  action: string;
  baby_id: string;
  baby_first_name: string;
  actor_name: string;
  details: Record<string, unknown>;
  total_count: number;
};

export type PlatformAuditRow = {
  source: string;
  event_id: number;
  action: string;
  target: string;
  actor: string;
  details: Record<string, unknown>;
  created_at: string;
  total_count: number;
};
