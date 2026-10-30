-- Rollback of 20261029000100_billing_reconcile.sql.
-- Restores the 1-day access slack and removes the reconciliation tables, RPCs and
-- flags. Subscriptions, billing events, premium orders and entitlements are untouched.
-- Unschedule the cron job FIRST (see docs/operations/billing-reconcile-setup.md):
--   select cron.unschedule('billing-reconcile');
begin;

create or replace function public.subscription_grants_access(p_status text, p_period_end timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_status = 'grace'
      or (p_status in ('trialing', 'active')
          and (p_period_end is null or p_period_end > now() - interval '1 day'));
$$;

drop function if exists
  public.billing_reconcile_health(),
  public.billing_reconcile_recent_downgrades(integer),
  public.billing_reconcile_record_run(jsonb),
  public.billing_reconcile_cursor_set(text, bigint),
  public.billing_reconcile_cursor_get(text),
  public.billing_voided_known(text[], text[]),
  public.billing_reconcile_note_ack(text, text, text),
  public.billing_reconcile_finish(uuid, text, text),
  public.billing_reconcile_claim(integer, integer),
  public.billing_reconcile_config(),
  public.billing_reconcile_next_check(text, timestamptz, integer);

drop table if exists public.billing_reconcile_runs;
drop table if exists public.billing_reconcile_cursors;
drop table if exists public.billing_reconcile_state;

delete from public.platform_flags where key in ('billing_reconcile', 'billing_reconcile_dry_run');

commit;
