-- =====================================================================
-- Scheduled Google Play reconciliation (no RTDN needed).
--   * billing_reconcile_state    : per-subscription check schedule, lease,
--                                  back-off and server-side acknowledgement state.
--   * billing_reconcile_cursors  : forward-only cursor of the voided-purchases poll.
--   * billing_reconcile_runs     : one summary row per run (counters only).
--   * RPCs (service_role only)   : claim / finish / ack note / voided filter /
--                                  cursor / run log / config / health.
--   * subscription_grants_access : slack after the period end 1 day -> 2 days.
--       Only status trialing / active is tolerated. grace keeps its own rule;
--       past_due (hold / pause), canceled and expired never grant access, so a
--       refunded, revoked or held subscription is not extended by the slack.
--   * Flags in platform_flags    : billing_reconcile (default OFF) and
--                                  billing_reconcile_dry_run (default ON).
-- billing_apply_event / premium_apply_event are NOT touched: the Edge Function
-- feeds them exactly like the store notifications would.
-- The cron schedule is NOT created here (see docs/operations/billing-reconcile-setup.md).
-- Rollback: supabase/rollbacks/20261029000100_billing_reconcile.down.sql
-- No subscription, payment or purchase row is changed or deleted.
-- =====================================================================
begin;

-- 1. Access gate: two days of slack ---------------------------------------------------------
create or replace function public.subscription_grants_access(p_status text, p_period_end timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_status = 'grace'
      or (p_status in ('trialing', 'active')
          and (p_period_end is null or p_period_end > now() - interval '2 days'));
$$;

-- 2. Tables -----------------------------------------------------------------------------------
create table public.billing_reconcile_state (
  subscription_id     uuid primary key references public.subscriptions (id) on delete cascade,
  next_check_at       timestamptz not null default now(),
  last_checked_at     timestamptz,
  lease_until         timestamptz,
  failure_count       integer not null default 0 check (failure_count >= 0),
  last_error_code     text,
  ack_state           text not null default 'unknown' check (ack_state in ('unknown', 'pending', 'acknowledged', 'failed')),
  ack_attempts        integer not null default 0 check (ack_attempts >= 0),
  ack_first_seen_at   timestamptz,
  ack_last_error_code text,
  acknowledged_at     timestamptz,
  updated_at          timestamptz not null default now()
);
create index billing_reconcile_state_due_idx on public.billing_reconcile_state (next_check_at);

create table public.billing_reconcile_cursors (
  key        text primary key,
  cursor_ms  bigint not null,
  updated_at timestamptz not null default now()
);

create table public.billing_reconcile_runs (
  id            bigint generated always as identity primary key,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz not null default now(),
  dry_run       boolean not null,
  checked       integer not null default 0,
  changed       integer not null default 0,
  downgrades    integer not null default 0,
  failed        integer not null default 0,
  acked         integer not null default 0,
  voided_seen   integer not null default 0,
  voided_applied integer not null default 0,
  blocked       boolean not null default false,
  codes         jsonb not null default '{}'::jsonb
);
create index billing_reconcile_runs_started_idx on public.billing_reconcile_runs (started_at desc);

alter table public.billing_reconcile_state enable row level security;
alter table public.billing_reconcile_cursors enable row level security;
alter table public.billing_reconcile_runs enable row level security;
revoke all on public.billing_reconcile_state, public.billing_reconcile_cursors, public.billing_reconcile_runs
  from public, anon, authenticated;

-- 3. Flags (OFF / dry-run by default) -------------------------------------------------------------
insert into public.platform_flags (key, enabled, note) values
  ('billing_reconcile', false, 'Scheduled Google Play reconciliation. Off until enabled on purpose.'),
  ('billing_reconcile_dry_run', true, 'While on, reconciliation only computes and logs; nothing is applied.')
on conflict (key) do nothing;

-- 4. Schedule policy (one place, unit-testable) ------------------------------------------------------
-- When is a subscription due again? Failures back off 15 min x4 up to 24 h.
create or replace function public.billing_reconcile_next_check(
  p_status text,
  p_period_end timestamptz,
  p_failures integer
)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select now() + case
    when coalesce(p_failures, 0) > 0
      then least(interval '24 hours', interval '15 minutes' * power(4, least(p_failures, 4) - 1)::integer)
    when p_status = 'past_due' then interval '6 hours'
    when p_status = 'grace' then interval '1 hour'
    when p_period_end is null then interval '1 day'
    when p_period_end > now() + interval '2 days'
      -- far from the renewal: a daily look still catches refunds and revocations
      then least(interval '1 day', greatest(interval '15 minutes', p_period_end - interval '2 days' - now()))
    when p_period_end > now() then interval '1 hour'
    when p_period_end > now() - interval '2 days' then interval '15 minutes'
    else interval '1 hour'
  end;
$$;

-- 5. RPCs (service_role only) ---------------------------------------------------------------------
create or replace function public.billing_reconcile_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'enabled', coalesce((select f.enabled from public.platform_flags f where f.key = 'billing_reconcile'), false),
    'dry_run', coalesce((select f.enabled from public.platform_flags f where f.key = 'billing_reconcile_dry_run'), true)
  );
$$;

-- Hands out due Google subscriptions and leases them (FOR UPDATE SKIP LOCKED), so two
-- overlapping runs never take the same row; a crashed run's lease simply expires.
create or replace function public.billing_reconcile_claim(p_limit integer default 40, p_lease_seconds integer default 600)
returns table (
  subscription_id uuid,
  provider_subscription_id text,
  status text,
  current_period_end timestamptz,
  cancel_at_period_end boolean,
  failure_count integer,
  ack_state text,
  ack_first_seen_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  p_limit := greatest(1, least(coalesce(p_limit, 40), 200));
  p_lease_seconds := greatest(30, least(coalesce(p_lease_seconds, 600), 3600));

  insert into public.billing_reconcile_state (subscription_id, next_check_at)
  select s.id, now()
    from public.subscriptions s
   where s.provider = 'google_play' and s.status in ('trialing', 'active', 'grace', 'past_due')
  on conflict (subscription_id) do nothing;

  return query
  with due as (
    select st.subscription_id
      from public.billing_reconcile_state st
      join public.subscriptions s on s.id = st.subscription_id
     where s.provider = 'google_play'
       and s.status in ('trialing', 'active', 'grace', 'past_due')
       and st.next_check_at <= now()
       and (st.lease_until is null or st.lease_until < now())
     order by st.next_check_at
     limit p_limit
       for update of st skip locked
  ),
  leased as (
    update public.billing_reconcile_state st
       set lease_until = now() + make_interval(secs => p_lease_seconds), updated_at = now()
      from due
     where st.subscription_id = due.subscription_id
    returning st.subscription_id, st.failure_count, st.ack_state, st.ack_first_seen_at
  )
  select l.subscription_id, s.provider_subscription_id, s.status, s.current_period_end, s.cancel_at_period_end,
         l.failure_count, l.ack_state, l.ack_first_seen_at
    from leased l
    join public.subscriptions s on s.id = l.subscription_id;
end;
$$;

-- Closes a claim. outcome: ok | error | replaced (Play moved the user to a new token that
-- only the app can link) | skipped (dry run). The next check comes from the schedule policy.
create or replace function public.billing_reconcile_finish(
  p_subscription_id uuid,
  p_outcome text,
  p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.subscriptions;
  v_failures integer;
begin
  select * into v_sub from public.subscriptions where id = p_subscription_id;
  if not found then
    return;
  end if;
  select case when p_outcome = 'error' then st.failure_count + 1 else 0 end into v_failures
    from public.billing_reconcile_state st where st.subscription_id = p_subscription_id;
  update public.billing_reconcile_state
     set lease_until = null,
         failure_count = coalesce(v_failures, 0),
         last_checked_at = case when p_outcome = 'error' then last_checked_at else now() end,
         last_error_code = case when p_outcome = 'ok' or p_outcome = 'skipped' then null else left(p_error_code, 60) end,
         -- An entitlement that Google still shows as unacknowledged is looked at every 30 minutes
         -- (2 hours after many failed attempts): Google refunds it after three days.
         next_check_at = case
           when ack_state in ('pending', 'failed')
             then least(public.billing_reconcile_next_check(v_sub.status, v_sub.current_period_end, coalesce(v_failures, 0)),
                        now() + case when ack_attempts < 8 then interval '30 minutes' else interval '2 hours' end)
           else public.billing_reconcile_next_check(v_sub.status, v_sub.current_period_end, coalesce(v_failures, 0))
         end,
         updated_at = now()
   where subscription_id = p_subscription_id;
end;
$$;

-- Server-side acknowledgement bookkeeping (kept apart from the entitlement itself).
-- p_ack: pending | acknowledged | failed. Looked up by the (secret) purchase token, which
-- never leaves the database.
create or replace function public.billing_reconcile_note_ack(
  p_provider_subscription_id text,
  p_ack text,
  p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_ack not in ('pending', 'acknowledged', 'failed') then
    raise exception 'unknown ack state' using errcode = '22023';
  end if;
  select s.id into v_id from public.subscriptions s
   where s.provider = 'google_play' and s.provider_subscription_id = p_provider_subscription_id;
  if v_id is null then
    return;
  end if;
  insert into public.billing_reconcile_state (subscription_id, next_check_at) values (v_id, now())
  on conflict (subscription_id) do nothing;
  update public.billing_reconcile_state
     set ack_state = p_ack,
         ack_attempts = case when p_ack = 'failed' then ack_attempts + 1 else ack_attempts end,
         ack_first_seen_at = coalesce(ack_first_seen_at, case when p_ack <> 'acknowledged' then now() end),
         ack_last_error_code = case when p_ack = 'failed' then left(p_error_code, 60) else null end,
         acknowledged_at = case when p_ack = 'acknowledged' then coalesce(acknowledged_at, now()) else acknowledged_at end,
         updated_at = now()
   where subscription_id = v_id;
end;
$$;

-- Which voided purchases do we know? Unknown ones (never verified by us) must not reach the
-- apply RPCs, where they would only be recorded as rejected events.
create or replace function public.billing_voided_known(p_tokens text[], p_orders text[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'tokens', coalesce((
      select jsonb_agg(s.provider_subscription_id) from public.subscriptions s
       where s.provider = 'google_play' and s.provider_subscription_id = any (coalesce(p_tokens, '{}'))
    ), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(o.provider_order_ref) from public.premium_orders o
       where o.provider = 'google_play' and o.provider_order_ref = any (coalesce(p_orders, '{}'))
    ), '[]'::jsonb)
  );
$$;

create or replace function public.billing_reconcile_cursor_get(p_key text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select c.cursor_ms from public.billing_reconcile_cursors c where c.key = p_key;
$$;

-- The cursor only ever moves forward.
create or replace function public.billing_reconcile_cursor_set(p_key text, p_ms bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.billing_reconcile_cursors (key, cursor_ms) values (p_key, p_ms)
  on conflict (key) do update
     set cursor_ms = greatest(public.billing_reconcile_cursors.cursor_ms, excluded.cursor_ms), updated_at = now();
$$;

create or replace function public.billing_reconcile_record_run(p_run jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.billing_reconcile_runs
    (started_at, dry_run, checked, changed, downgrades, failed, acked, voided_seen, voided_applied, blocked, codes)
  values (
    coalesce((p_run ->> 'started_at')::timestamptz, now()),
    coalesce((p_run ->> 'dry_run')::boolean, true),
    coalesce((p_run ->> 'checked')::integer, 0),
    coalesce((p_run ->> 'changed')::integer, 0),
    coalesce((p_run ->> 'downgrades')::integer, 0),
    coalesce((p_run ->> 'failed')::integer, 0),
    coalesce((p_run ->> 'acked')::integer, 0),
    coalesce((p_run ->> 'voided_seen')::integer, 0),
    coalesce((p_run ->> 'voided_applied')::integer, 0),
    coalesce((p_run ->> 'blocked')::boolean, false),
    coalesce(p_run -> 'codes', '{}'::jsonb)
  );
$$;

-- Circuit breaker input: access removals actually applied in the last N minutes.
create or replace function public.billing_reconcile_recent_downgrades(p_minutes integer default 60)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(r.downgrades), 0)::integer
    from public.billing_reconcile_runs r
   where not r.dry_run and r.started_at > now() - make_interval(mins => greatest(1, p_minutes));
$$;

-- Counters for monitoring (no tokens, no user data).
create or replace function public.billing_reconcile_health()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'config', public.billing_reconcile_config(),
    'tracked', (select count(*) from public.billing_reconcile_state),
    'overdue_1h', (select count(*) from public.billing_reconcile_state st
                    join public.subscriptions s on s.id = st.subscription_id
                   where s.status in ('trialing', 'active', 'grace', 'past_due')
                     and st.next_check_at < now() - interval '1 hour'),
    'failing', (select count(*) from public.billing_reconcile_state where failure_count > 0),
    'ack_pending', (select count(*) from public.billing_reconcile_state where ack_state = 'pending'),
    'ack_failed', (select count(*) from public.billing_reconcile_state where ack_state = 'failed'),
    -- Google refunds purchases that stay unacknowledged for three days: warn after 24 h.
    'ack_at_risk_24h', (select count(*) from public.billing_reconcile_state
                         where ack_state in ('pending', 'failed') and ack_first_seen_at < now() - interval '24 hours'),
    'last_run', (select to_jsonb(r) - 'id' from public.billing_reconcile_runs r order by r.id desc limit 1)
  );
$$;

revoke all on function
  public.billing_reconcile_next_check(text, timestamptz, integer),
  public.billing_reconcile_config(),
  public.billing_reconcile_claim(integer, integer),
  public.billing_reconcile_finish(uuid, text, text),
  public.billing_reconcile_note_ack(text, text, text),
  public.billing_voided_known(text[], text[]),
  public.billing_reconcile_cursor_get(text),
  public.billing_reconcile_cursor_set(text, bigint),
  public.billing_reconcile_record_run(jsonb),
  public.billing_reconcile_recent_downgrades(integer),
  public.billing_reconcile_health()
  from public, anon, authenticated;
grant execute on function
  public.billing_reconcile_next_check(text, timestamptz, integer),
  public.billing_reconcile_config(),
  public.billing_reconcile_claim(integer, integer),
  public.billing_reconcile_finish(uuid, text, text),
  public.billing_reconcile_note_ack(text, text, text),
  public.billing_voided_known(text[], text[]),
  public.billing_reconcile_cursor_get(text),
  public.billing_reconcile_cursor_set(text, bigint),
  public.billing_reconcile_record_run(jsonb),
  public.billing_reconcile_recent_downgrades(integer),
  public.billing_reconcile_health()
  to service_role;

commit;
