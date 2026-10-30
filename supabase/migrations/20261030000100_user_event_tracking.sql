-- =====================================================================
-- User journey and subscription conversion tracking (operational, not advertising).
--
--   * user_events           : append-only journey / payment-stage events. Fixed
--                             vocabularies only (CHECK lists): no free text, no jsonb,
--                             no tokens, receipts, e-mail, baby or content data.
--   * user_events_write     : INTERNAL writer. Never raises (a tracking problem must
--                             never block sign-up, sign-in or a purchase) and is
--                             callable by no API role.
--   * record_server_user_event : service_role-only wrapper for Edge Functions. The
--                             user id is passed explicitly (auth.uid() does not exist
--                             under the service role); the Edge Function takes it from
--                             the verified JWT.
--   * Triggers              : registration, e-mail verification, first sign-in, family
--                             account, baby link, subscription activation / cancel /
--                             expiry. They call the internal writer directly.
--   * admin_* read models   : Super Admin only (same gate as the other admin RPCs):
--                             per-user timeline + summary, conversion funnel, open
--                             payment problems. Events before `tracking_started` are
--                             shown from existing tables only, as they are on record;
--                             nothing is estimated or back-filled.
--   * purge_user_events     : retention (design target 13 months, pending the KVKK
--                             decision). NOT scheduled here, see
--                             docs/operations/user-event-tracking.md.
-- No existing row is changed or deleted. Client (Flutter) events come in a later
-- phase: their event types are already allowed, but no client write path exists yet.
-- Rollback: supabase/rollbacks/20261030000100_user_event_tracking.down.sql
-- =====================================================================
begin;

-- 1. Tables -----------------------------------------------------------------------------------
create table public.user_event_meta (
  key   text primary key,
  value timestamptz not null
);
insert into public.user_event_meta (key, value) values ('tracking_started', now());

create table public.user_events (
  id                bigint generated always as identity primary key,
  user_id           uuid references auth.users (id) on delete cascade,
  family_account_id uuid references public.family_accounts (id) on delete cascade,
  event_type        text not null check (event_type in (
    -- server side (triggers)
    'user_registered', 'email_verified', 'first_sign_in', 'family_created', 'baby_added',
    'subscription_activated', 'subscription_canceled', 'subscription_expired',
    -- server side (verification Edge Function)
    'payment_verified', 'payment_pending', 'store_verification_failed', 'activation_granted', 'activation_failed',
    -- client side (later phase)
    'plans_viewed', 'plan_selected', 'payment_started', 'payment_canceled_by_user', 'payment_failed'
  )),
  platform          text not null default 'unknown' check (platform in ('android', 'ios', 'web', 'unknown')),
  plan_code         text check (plan_code is null or plan_code ~ '^[a-z][a-z0-9_]{0,39}$'),
  product_kind      text check (product_kind is null or product_kind in ('subscription', 'premium')),
  status            text not null default 'ok' check (status in ('ok', 'failed', 'pending')),
  error_code        text check (error_code is null or error_code in (
    'not_configured', 'google_401', 'google_403', 'google_404', 'product_not_found',
    'base_plan_unavailable', 'verification_failed', 'purchase_rejected', 'temporary_error',
    'purchase_not_yours', 'purchase_inactive', 'user_canceled', 'store_error', 'billing_unavailable'
  )),
  occurred_at       timestamptz not null default now(),
  check (user_id is not null or family_account_id is not null)
);

create index user_events_user_idx on public.user_events (user_id, occurred_at desc) where user_id is not null;
create index user_events_family_idx on public.user_events (family_account_id, occurred_at desc)
  where family_account_id is not null;
create index user_events_type_idx on public.user_events (event_type, occurred_at desc);

alter table public.user_events enable row level security;
alter table public.user_event_meta enable row level security;
revoke all on table public.user_events, public.user_event_meta from public, anon, authenticated;
grant all on table public.user_events, public.user_event_meta to service_role;

-- 2. Writers ------------------------------------------------------------------------------------
-- Internal writer: swallows every error and de-duplicates identical events within a minute
-- (the store re-delivers unfinished purchases).
create or replace function public.user_events_write(
  p_user uuid,
  p_family uuid,
  p_event_type text,
  p_platform text,
  p_plan_code text,
  p_product_kind text,
  p_status text,
  p_error_code text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user is null and p_family is null then
    return false;
  end if;
  if exists (
    select 1 from public.user_events e
     where e.event_type = p_event_type
       and e.user_id is not distinct from p_user
       and e.family_account_id is not distinct from p_family
       and e.plan_code is not distinct from p_plan_code
       and e.error_code is not distinct from p_error_code
       and e.occurred_at > clock_timestamp() - interval '1 minute'
  ) then
    return false;
  end if;
  insert into public.user_events (user_id, family_account_id, event_type, platform, plan_code,
                                  product_kind, status, error_code)
  values (p_user, p_family, p_event_type, coalesce(p_platform, 'unknown'), p_plan_code,
          p_product_kind, coalesce(p_status, 'ok'), p_error_code);
  return true;
exception when others then
  return false;
end;
$$;

revoke all on function public.user_events_write(uuid, uuid, text, text, text, text, text, text)
  from public, anon, authenticated, service_role;

-- Edge Function entry point (service_role only). Returns false instead of raising.
create or replace function public.record_server_user_event(
  p_user uuid,
  p_event_type text,
  p_platform text default 'unknown',
  p_plan_code text default null,
  p_product_kind text default null,
  p_status text default 'ok',
  p_error_code text default null,
  p_family_account_id uuid default null
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select public.user_events_write(p_user, p_family_account_id, p_event_type, p_platform, p_plan_code,
                                  p_product_kind, p_status, p_error_code);
$$;

revoke all on function public.record_server_user_event(uuid, text, text, text, text, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.record_server_user_event(uuid, text, text, text, text, text, text, uuid)
  to service_role;

-- 3. Triggers (never block the triggering statement) -------------------------------------------------
create or replace function public.user_events_on_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform public.user_events_write(new.id, null, 'user_registered', 'unknown', null, null, 'ok', null);
    else
      if old.email_confirmed_at is null and new.email_confirmed_at is not null then
        perform public.user_events_write(new.id, null, 'email_verified', 'unknown', null, null, 'ok', null);
      end if;
      if old.last_sign_in_at is null and new.last_sign_in_at is not null then
        perform public.user_events_write(new.id, null, 'first_sign_in', 'unknown', null, null, 'ok', null);
      end if;
    end if;
  exception when others then
    null;
  end;
  return new;
end;
$$;

create trigger user_events_auth_insert
  after insert on auth.users
  for each row execute function public.user_events_on_auth_user();
create trigger user_events_auth_update
  after update of email_confirmed_at, last_sign_in_at on auth.users
  for each row execute function public.user_events_on_auth_user();

create or replace function public.user_events_on_family_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.user_events_write(new.created_by, new.id, 'family_created', 'unknown', null, null, 'ok', null);
  exception when others then
    null;
  end;
  return new;
end;
$$;

create trigger user_events_family_account
  after insert on public.family_accounts
  for each row execute function public.user_events_on_family_account();

create or replace function public.user_events_on_baby_link()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.user_events_write(
      (select b.created_by from public.babies b where b.id = new.baby_id),
      new.family_account_id, 'baby_added', 'unknown', null, null, 'ok', null);
  exception when others then
    null;
  end;
  return new;
end;
$$;

create trigger user_events_baby_link
  after insert on public.family_account_babies
  for each row execute function public.user_events_on_baby_link();

-- Subscription state is family-scoped: the user is not known here, the family account is.
create or replace function public.user_events_on_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_platform text := case new.provider when 'google_play' then 'android' when 'app_store' then 'ios' else 'unknown' end;
begin
  begin
    if tg_op = 'INSERT' then
      if public.subscription_grants_access(new.status, new.current_period_end) then
        perform public.user_events_write(null, new.family_account_id, 'subscription_activated', v_platform,
                                         new.plan_code, 'subscription', 'ok', null);
      end if;
    else
      if not public.subscription_grants_access(old.status, old.current_period_end)
         and public.subscription_grants_access(new.status, new.current_period_end) then
        perform public.user_events_write(null, new.family_account_id, 'subscription_activated', v_platform,
                                         new.plan_code, 'subscription', 'ok', null);
      end if;
      if (new.cancel_at_period_end and not old.cancel_at_period_end and new.status in ('active', 'trialing', 'grace'))
         or (new.status = 'canceled' and old.status <> 'canceled') then
        perform public.user_events_write(null, new.family_account_id, 'subscription_canceled', v_platform,
                                         new.plan_code, 'subscription', 'ok', null);
      end if;
      if new.status = 'expired' and old.status <> 'expired' then
        perform public.user_events_write(null, new.family_account_id, 'subscription_expired', v_platform,
                                         new.plan_code, 'subscription', 'ok', null);
      end if;
    end if;
  exception when others then
    null;
  end;
  return new;
end;
$$;

create trigger user_events_subscription
  after insert or update on public.subscriptions
  for each row execute function public.user_events_on_subscription();

revoke all on function public.user_events_on_auth_user(), public.user_events_on_family_account(),
  public.user_events_on_baby_link(), public.user_events_on_subscription()
  from public, anon, authenticated, service_role;

-- 4. Internal helpers (no API role may call them) --------------------------------------------------------
create or replace function public.user_events_parent_accounts(p_user uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select fam.family_account_id from public.family_account_members fam
   where fam.user_id = p_user and fam.role = 'parent' and fam.status <> 'removed';
$$;

-- Does the user's family currently hold what the verified purchase should have granted?
create or replace function public.user_events_has_access(p_user uuid, p_kind text, p_plan_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_kind
    when 'premium' then exists (
      select 1 from public.product_entitlements e
       where e.family_account_id in (select public.user_events_parent_accounts(p_user))
         and e.status = 'active'
         and (p_plan_code is null or e.product_code = p_plan_code))
    else exists (
      select 1 from public.subscriptions s
       where s.family_account_id in (select public.user_events_parent_accounts(p_user))
         and public.subscription_grants_access(s.status, s.current_period_end))
  end;
$$;

-- Two different situations, kept apart on purpose:
--   paid_not_activated  : the store itself confirmed the payment (payment_verified) but the
--                         family has no access / entitlement and no later activation_granted.
--   verification_failed : the store could not be reached or rejected the check; whether any
--                         money moved is UNKNOWN.
create or replace function public.user_payment_problem(p_user uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pv record;
  v_vf record;
begin
  select e.occurred_at, e.product_kind, e.plan_code into v_pv
    from public.user_events e
   where e.user_id = p_user and e.event_type = 'payment_verified'
   order by e.occurred_at desc, e.id desc limit 1;
  if found
     and not exists (select 1 from public.user_events g
                      where g.user_id = p_user and g.event_type = 'activation_granted'
                        and g.occurred_at >= v_pv.occurred_at)
     and not public.user_events_has_access(p_user, v_pv.product_kind, v_pv.plan_code) then
    return 'paid_not_activated';
  end if;

  select e.occurred_at, e.product_kind, e.plan_code into v_vf
    from public.user_events e
   where e.user_id = p_user and e.event_type = 'store_verification_failed'
   order by e.occurred_at desc, e.id desc limit 1;
  if found
     -- A later successful store check supersedes a failed one (an unresolved paid payment
     -- is reported by the first rule above).
     and not exists (select 1 from public.user_events g
                      where g.user_id = p_user and g.event_type in ('activation_granted', 'payment_verified')
                        and g.occurred_at >= v_vf.occurred_at)
     and (v_vf.product_kind is null
          or not public.user_events_has_access(p_user, v_vf.product_kind, v_vf.plan_code)) then
    return 'verification_failed';
  end if;
  return null;
end;
$$;

revoke all on function public.user_events_parent_accounts(uuid), public.user_events_has_access(uuid, text, text),
  public.user_payment_problem(uuid)
  from public, anon, authenticated, service_role;

-- 5. Admin read models ---------------------------------------------------------------------------------------
-- Timeline: recorded events (after tracking started) + history rebuilt only from rows that
-- exist in the current tables (before tracking started). No estimated events.
create or replace function public.admin_user_activity(
  p_user_id uuid,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  event_type text,
  occurred_at timestamptz,
  platform text,
  plan_code text,
  status text,
  error_code text,
  source text,
  scope text,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_cutover timestamptz := (select m.value from public.user_event_meta m where m.key = 'tracking_started');
begin
  perform public.assert_admin_console('read', 120);
  if p_user_id is null or not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'user not found' using errcode = 'P0002';
  end if;

  return query
  with accounts as (
    select public.user_events_parent_accounts(p_user_id) as id
  ), merged as (
    select e.event_type, e.occurred_at, e.platform, e.plan_code, e.status, e.error_code,
           'recorded'::text as source,
           case when e.user_id = p_user_id then 'user' else 'family' end as scope
      from public.user_events e
     where e.user_id = p_user_id or e.family_account_id in (select a.id from accounts a)
    union all
    select 'user_registered', u.created_at, 'unknown', null, 'ok', null, 'history', 'user'
      from auth.users u where u.id = p_user_id and u.created_at < v_cutover
    union all
    select 'email_verified', u.email_confirmed_at, 'unknown', null, 'ok', null, 'history', 'user'
      from auth.users u
     where u.id = p_user_id and u.email_confirmed_at is not null and u.email_confirmed_at < v_cutover
    union all
    select 'family_created', fa.created_at, 'unknown', null, 'ok', null, 'history', 'user'
      from public.family_accounts fa where fa.created_by = p_user_id and fa.created_at < v_cutover
    union all
    select 'baby_added', fab.linked_at, 'unknown', null, 'ok', null, 'history', 'user'
      from public.family_account_babies fab
      join public.babies b on b.id = fab.baby_id
     where b.created_by = p_user_id and fab.linked_at < v_cutover
    union all
    -- An opened checkout intent: the plan was chosen and a purchase prepared; it does NOT
    -- prove that the store payment screen was shown.
    select 'checkout_intent_created', i.created_at, 'unknown', p.code, case i.status when 'consumed' then 'ok' else 'pending' end,
           null, 'history', 'user'
      from public.subscription_checkout_intents i
      join public.subscription_plans p on p.id = i.plan_id
     where i.requested_by = p_user_id and i.created_at < v_cutover
    union all
    select 'subscription_activated', s.created_at,
           case s.provider when 'google_play' then 'android' when 'app_store' then 'ios' else 'unknown' end,
           s.plan_code, 'ok', null, 'history', 'family'
      from public.subscriptions s
     where s.family_account_id in (select a.id from accounts a) and s.created_at < v_cutover
  )
  select m.event_type, m.occurred_at, m.platform, m.plan_code, m.status, m.error_code, m.source, m.scope,
         count(*) over ()
    from merged m
   order by m.occurred_at desc, m.event_type
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_user_activity_summary(p_user_id uuid)
returns table (
  user_id uuid,
  registered_at timestamptz,
  email_verified_at timestamptz,
  last_activity_at timestamptz,
  family_created_at timestamptz,
  baby_added_at timestamptz,
  plans_viewed_at timestamptz,
  plan_selected_at timestamptz,
  checkout_started_at timestamptz,
  payment_verified_at timestamptz,
  activated_at timestamptz,
  subscription_status text,
  subscription_plan_code text,
  has_payment_attempt boolean,
  payment_success_count bigint,
  payment_failure_count bigint,
  payment_problem text,
  tracking_started_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user auth.users;
begin
  perform public.assert_admin_console('read', 120);
  select * into v_user from auth.users u where u.id = p_user_id;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;

  return query
  with accounts as (
    select public.user_events_parent_accounts(p_user_id) as id
  ), best_sub as (
    select s.status, s.plan_code
      from public.subscriptions s
     where s.family_account_id in (select a.id from accounts a)
     order by public.subscription_grants_access(s.status, s.current_period_end) desc, s.updated_at desc
     limit 1
  )
  select p_user_id,
         v_user.created_at,
         v_user.email_confirmed_at,
         greatest(
           (select max(e.occurred_at) from public.user_events e
             where e.user_id = p_user_id or e.family_account_id in (select a.id from accounts a)),
           v_user.last_sign_in_at,
           (select max(i.created_at) from public.subscription_checkout_intents i where i.requested_by = p_user_id)),
         (select min(fa.created_at) from public.family_accounts fa where fa.created_by = p_user_id),
         (select min(fab.linked_at) from public.family_account_babies fab
            join public.babies b on b.id = fab.baby_id where b.created_by = p_user_id),
         (select min(e.occurred_at) from public.user_events e where e.user_id = p_user_id and e.event_type = 'plans_viewed'),
         (select min(e.occurred_at) from public.user_events e where e.user_id = p_user_id and e.event_type = 'plan_selected'),
         least(
           (select min(i.created_at) from public.subscription_checkout_intents i where i.requested_by = p_user_id),
           (select min(e.occurred_at) from public.user_events e where e.user_id = p_user_id and e.event_type = 'payment_started')),
         least(
           (select min(e.occurred_at) from public.user_events e where e.user_id = p_user_id and e.event_type = 'payment_verified'),
           (select min(be.received_at) from public.billing_events be
             where be.family_account_id in (select a.id from accounts a) and be.result = 'applied' and be.error is null)),
         (select min(s.created_at) from public.subscriptions s where s.family_account_id in (select a.id from accounts a)),
         (select b.status from best_sub b),
         (select b.plan_code from best_sub b),
         exists (select 1 from public.subscription_checkout_intents i where i.requested_by = p_user_id)
           or exists (select 1 from public.user_events e
                       where e.user_id = p_user_id
                         and e.event_type in ('payment_started', 'payment_verified', 'payment_pending',
                                              'store_verification_failed', 'activation_failed', 'payment_failed')),
         (select count(*) from public.billing_events be
           where be.family_account_id in (select a.id from accounts a) and be.result = 'applied' and be.error is null)
         + (select count(*) from public.premium_orders o
             where o.family_account_id in (select a.id from accounts a) and o.status = 'paid'),
         (select count(*) from public.user_events e
           where e.user_id = p_user_id and e.event_type in ('store_verification_failed', 'activation_failed')),
         public.user_payment_problem(p_user_id),
         (select m.value from public.user_event_meta m where m.key = 'tracking_started');
end;
$$;

create or replace function public.admin_conversion_funnel(p_days integer default 30)
returns table (
  registered bigint,
  email_verified bigint,
  family_created bigint,
  plans_viewed bigint,
  checkout_started bigint,
  payment_verified bigint,
  activated_users bigint,
  activated_families bigint,
  open_paid_not_activated bigint,
  open_verification_failed bigint,
  plans_viewed_available boolean,
  tracking_started_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_since timestamptz;
begin
  perform public.assert_admin_console('read', 120);
  if p_days is null or p_days not in (7, 30, 90) then
    raise exception 'invalid period' using errcode = '22023';
  end if;
  v_since := now() - make_interval(days => p_days);

  return query
  with problems as (
    select public.user_payment_problem(c.user_id) as problem
      from (select distinct e.user_id from public.user_events e
             where e.user_id is not null and e.occurred_at >= v_since
               and e.event_type in ('payment_verified', 'store_verification_failed', 'activation_failed')
             limit 500) c
  )
  select
    (select count(*) from auth.users u where u.created_at >= v_since),
    (select count(*) from auth.users u where u.email_confirmed_at >= v_since),
    (select count(distinct fa.created_by) from public.family_accounts fa
      where fa.created_at >= v_since and fa.created_by is not null),
    (select count(distinct e.user_id) from public.user_events e
      where e.event_type = 'plans_viewed' and e.occurred_at >= v_since),
    (select count(*) from (
       select i.requested_by as uid from public.subscription_checkout_intents i
        where i.created_at >= v_since and i.requested_by is not null
       union
       select e.user_id from public.user_events e
        where e.event_type = 'payment_started' and e.occurred_at >= v_since and e.user_id is not null) q),
    (select count(distinct e.user_id) from public.user_events e
      where e.event_type = 'payment_verified' and e.occurred_at >= v_since),
    (select count(distinct fam.user_id) from public.subscriptions s
       join public.family_account_members fam
         on fam.family_account_id = s.family_account_id and fam.role = 'parent' and fam.status <> 'removed'
      where s.created_at >= v_since),
    (select count(distinct s.family_account_id) from public.subscriptions s where s.created_at >= v_since),
    (select count(*) from problems p where p.problem = 'paid_not_activated'),
    (select count(*) from problems p where p.problem = 'verification_failed'),
    exists (select 1 from public.user_events e where e.event_type = 'plans_viewed'),
    (select m.value from public.user_event_meta m where m.key = 'tracking_started');
end;
$$;

create or replace function public.admin_payment_problems(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  problem text,
  last_event_at timestamptz,
  plan_code text,
  error_code text,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform public.assert_admin_console('read', 120);
  return query
  with cand as (
    select distinct e.user_id as uid from public.user_events e
     where e.user_id is not null and e.occurred_at >= now() - interval '90 days'
       and e.event_type in ('payment_verified', 'store_verification_failed', 'activation_failed')
     limit 500
  ), flagged as (
    select c.uid, public.user_payment_problem(c.uid) as problem from cand c
  ), shown as (
    select f.uid, f.problem, l.occurred_at, l.plan_code, l.error_code
      from flagged f
      cross join lateral (
        select e.occurred_at, e.plan_code, e.error_code from public.user_events e
         where e.user_id = f.uid
           and e.event_type in ('payment_verified', 'store_verification_failed', 'activation_failed')
         order by e.occurred_at desc, e.id desc limit 1) l
     where f.problem is not null
  )
  select s.uid, s.problem, s.occurred_at, s.plan_code, s.error_code, count(*) over ()
    from shown s
   order by s.occurred_at desc, s.uid
   limit v_limit offset v_offset;
end;
$$;

revoke all on function public.admin_user_activity(uuid, integer, integer),
  public.admin_user_activity_summary(uuid),
  public.admin_conversion_funnel(integer),
  public.admin_payment_problems(integer, integer)
  from public, anon;
grant execute on function public.admin_user_activity(uuid, integer, integer),
  public.admin_user_activity_summary(uuid),
  public.admin_conversion_funnel(integer),
  public.admin_payment_problems(integer, integer)
  to authenticated, service_role;

-- 6. Retention ---------------------------------------------------------------------------------------------------
create or replace function public.purge_user_events(p_older_than interval default interval '13 months')
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted bigint;
begin
  if p_older_than is null or p_older_than < interval '1 month' then
    raise exception 'retention must be at least one month' using errcode = '22023';
  end if;
  delete from public.user_events e where e.occurred_at < now() - p_older_than;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.purge_user_events(interval) from public, anon, authenticated;
grant execute on function public.purge_user_events(interval) to service_role;

commit;
