-- =====================================================================
-- Phase 6: family accounts and the family-package subscription.
--
--   * A family_account groups babies and people. Per-baby family_members
--     (relation + permissions) stay as the compatibility layer; the account
--     adds parent seats (max 2) and the Family Member capacity of the plan.
--   * The subscription belongs to the family_account only (never to a person
--     or a baby). Parents are not counted against max_family_members.
--   * Plans, capacities and prices live in a versioned catalog; the annual
--     price must equal monthly x 12 x 0.90 (enforced by trigger).
--   * Subscriptions are a projection of verified provider events
--     (billing_events, append-only, idempotent by provider event id). Clients
--     can only open a checkout intent; they can never activate a plan.
--   * Nothing here touches the lifecycle or content permissions.
--
-- Decisions (see docs/implementation/ADR/0002-family-accounts-and-subscriptions.md):
--   * Pending invitations do not reserve capacity; the authoritative check is
--     at activation (family_members insert), serialised per account.
--   * A downgrade below the active member count is applied as the provider
--     reports it, flagged over_capacity; nobody is removed and new Family
--     Member activations are refused until the count fits.
--   * `subscription_enforcement` flag (default off): when off, accounts
--     without a live subscription keep today's behaviour; a live
--     subscription's capacity is always enforced.
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('subscription_enforcement', false,
        'Phase 6: when on, Family Member activation requires a live family subscription.')
on conflict (key) do nothing;

-- Family accounts ----------------------------------------------------------------------
create table public.family_accounts (
  id           uuid primary key default gen_random_uuid(),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 80),
  status       text not null default 'active' check (status in ('active', 'closed')),
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger family_accounts_set_updated_at
  before update on public.family_accounts
  for each row execute function public.set_updated_at();

create table public.family_account_members (
  id                 uuid primary key default gen_random_uuid(),
  family_account_id  uuid not null references public.family_accounts (id) on delete cascade,
  user_id            uuid not null references auth.users (id) on delete cascade,
  role               text not null check (role in ('parent', 'family_member')),
  relationship_label text check (relationship_label is null or char_length(relationship_label) <= 40),
  status             text not null default 'active' check (status in ('invited', 'active', 'suspended', 'removed')),
  invited_by         uuid references auth.users (id) on delete set null,
  activated_at       timestamptz,
  removed_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (family_account_id, user_id)
);

create index family_account_members_user_idx on public.family_account_members (user_id) where status = 'active';

create trigger family_account_members_set_updated_at
  before update on public.family_account_members
  for each row execute function public.set_updated_at();

-- A baby belongs to exactly one family account at a time.
create table public.family_account_babies (
  baby_id           uuid primary key references public.babies (id) on delete cascade,
  family_account_id uuid not null references public.family_accounts (id) on delete cascade,
  linked_at         timestamptz not null default now()
);

create index family_account_babies_account_idx on public.family_account_babies (family_account_id);

-- Legacy mapping report: babies whose household could not be derived safely.
create table public.family_account_migration_report (
  id                         bigint generated always as identity primary key,
  baby_id                    uuid not null references public.babies (id) on delete cascade,
  reason                     text not null check (reason in ('no_parent', 'too_many_parents', 'ambiguous_parent_sets')),
  parent_ids                 uuid[] not null default '{}',
  created_at                 timestamptz not null default now(),
  resolved_at                timestamptz,
  resolved_family_account_id uuid references public.family_accounts (id) on delete set null
);

create unique index family_account_migration_report_open_idx
  on public.family_account_migration_report (baby_id) where resolved_at is null;

-- Plan catalog -----------------------------------------------------------------------------
create table public.subscription_plans (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null check (code in ('small_family', 'normal_family', 'large_family')),
  billing_period     text not null check (billing_period in ('monthly', 'annual')),
  version            integer not null default 1 check (version > 0),
  max_parent_seats   smallint not null check (max_parent_seats = 2),
  max_family_members smallint not null check (max_family_members > 0),
  price_minor        integer not null check (price_minor > 0),
  currency           text not null default 'TRY' check (currency = 'TRY'),
  active_from        timestamptz not null default now(),
  active_until       timestamptz,
  created_at         timestamptz not null default now(),
  unique (code, billing_period, version),
  check (active_until is null or active_until > active_from)
);

-- Annual = monthly x 12 x 0.90 for the same plan and version; capacities match.
create or replace function public.subscription_plans_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_other public.subscription_plans;
begin
  if tg_op = 'UPDATE' and (new.code, new.billing_period, new.version, new.price_minor, new.max_family_members,
                           new.max_parent_seats, new.currency)
                          is distinct from
                          (old.code, old.billing_period, old.version, old.price_minor, old.max_family_members,
                           old.max_parent_seats, old.currency) then
    raise exception 'catalog rows are immutable; add a new version' using errcode = '42501';
  end if;
  select * into v_other from public.subscription_plans p
   where p.code = new.code and p.version = new.version and p.billing_period <> new.billing_period;
  if found then
    if v_other.max_family_members <> new.max_family_members then
      raise exception 'monthly and annual capacity must match' using errcode = '23514';
    end if;
    if (new.billing_period = 'annual' and new.price_minor <> round(v_other.price_minor * 12 * 0.90))
       or (new.billing_period = 'monthly' and v_other.price_minor <> round(new.price_minor * 12 * 0.90)) then
      raise exception 'annual price must equal monthly x 12 x 0.90' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger subscription_plans_guard
  before insert or update on public.subscription_plans
  for each row execute function public.subscription_plans_guard();

insert into public.subscription_plans (code, billing_period, max_parent_seats, max_family_members, price_minor) values
  ('small_family',  'monthly', 2, 3,  29900),
  ('small_family',  'annual',  2, 3,  322920),
  ('normal_family', 'monthly', 2, 6,  36900),
  ('normal_family', 'annual',  2, 6,  398520),
  ('large_family',  'monthly', 2, 12, 46900),
  ('large_family',  'annual',  2, 12, 506520);

create table public.subscription_plan_provider_products (
  provider            text not null check (provider ~ '^[a-z_]{2,30}$'),
  provider_product_id text not null check (char_length(provider_product_id) between 1 and 200),
  plan_id             uuid not null references public.subscription_plans (id),
  primary key (provider, provider_product_id),
  unique (provider, plan_id)
);

-- Mock provider until a store / payment provider is chosen.
insert into public.subscription_plan_provider_products (provider, provider_product_id, plan_id)
select 'mock', 'mock.' || p.code || '.' || p.billing_period, p.id from public.subscription_plans p;

-- Current catalog rows (latest active version per plan and period).
create or replace function public.current_subscription_plans()
returns setof public.subscription_plans
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (p.code, p.billing_period) p.*
    from public.subscription_plans p
   where p.active_from <= now() and (p.active_until is null or p.active_until > now())
   order by p.code, p.billing_period, p.version desc;
$$;

create or replace function public.billing_active_provider()
returns text
language sql
immutable
set search_path = ''
as $$
  select 'mock'::text;
$$;

-- Subscriptions and provider events --------------------------------------------------------
create table public.subscriptions (
  id                       uuid primary key default gen_random_uuid(),
  family_account_id        uuid not null references public.family_accounts (id) on delete restrict,
  plan_id                  uuid not null references public.subscription_plans (id),
  plan_code                text not null,
  billing_period           text not null,
  status                   text not null check (status in ('trialing', 'active', 'grace', 'past_due', 'canceled', 'expired')),
  provider                 text not null,
  provider_customer_id     text,
  provider_subscription_id text not null,
  current_period_start     timestamptz,
  current_period_end       timestamptz,
  cancel_at_period_end     boolean not null default false,
  over_capacity            boolean not null default false,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (provider, provider_subscription_id)
);

-- At most one live subscription per family account.
create unique index subscriptions_one_live_idx on public.subscriptions (family_account_id)
  where status in ('trialing', 'active', 'grace', 'past_due');

create trigger subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

create table public.subscription_checkout_intents (
  id                uuid primary key default gen_random_uuid(),
  family_account_id uuid not null references public.family_accounts (id) on delete cascade,
  requested_by      uuid references auth.users (id) on delete set null,
  plan_id           uuid not null references public.subscription_plans (id),
  provider          text not null,
  price_minor       integer not null,
  currency          text not null,
  status            text not null default 'open' check (status in ('open', 'consumed', 'expired')),
  expires_at        timestamptz not null default now() + interval '1 day',
  created_at        timestamptz not null default now(),
  consumed_at       timestamptz
);

create index subscription_checkout_intents_account_idx on public.subscription_checkout_intents (family_account_id, created_at desc);

create table public.billing_events (
  id                bigint generated always as identity primary key,
  provider          text not null,
  provider_event_id text not null,
  event_type        text not null,
  family_account_id uuid,
  subscription_id   uuid,
  payload           jsonb not null,
  result            text check (result in ('applied', 'rejected')),
  error             text,
  received_at       timestamptz not null default now(),
  unique (provider, provider_event_id)
);

-- Append-only: only the processing outcome may be filled in, once.
create or replace function public.billing_events_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'billing events are append-only' using errcode = '42501';
  end if;
  if old.result is not null
     or (new.provider, new.provider_event_id, new.event_type, new.payload, new.received_at)
        is distinct from (old.provider, old.provider_event_id, old.event_type, old.payload, old.received_at) then
    raise exception 'billing events are append-only' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger billing_events_append_only
  before update or delete on public.billing_events
  for each row execute function public.billing_events_append_only();

-- RLS: every new table is service-only; clients read through RPCs.
alter table public.family_accounts enable row level security;
alter table public.family_account_members enable row level security;
alter table public.family_account_babies enable row level security;
alter table public.family_account_migration_report enable row level security;
alter table public.subscription_plans enable row level security;
alter table public.subscription_plan_provider_products enable row level security;
alter table public.subscriptions enable row level security;
alter table public.subscription_checkout_intents enable row level security;
alter table public.billing_events enable row level security;

revoke all on table public.family_accounts, public.family_account_members, public.family_account_babies,
  public.family_account_migration_report, public.subscription_plans, public.subscription_plan_provider_products,
  public.subscriptions, public.subscription_checkout_intents, public.billing_events
  from public, anon, authenticated;
grant all on table public.family_accounts, public.family_account_members, public.family_account_babies,
  public.family_account_migration_report, public.subscription_plans, public.subscription_plan_provider_products,
  public.subscriptions, public.subscription_checkout_intents, public.billing_events
  to service_role;

-- Helpers ------------------------------------------------------------------------------------
create or replace function public.family_account_active_member_count(p_account uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.family_account_members m
   where m.family_account_id = p_account and m.role = 'family_member' and m.status = 'active';
$$;

create or replace function public.family_account_active_parent_count(p_account uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.family_account_members m
   where m.family_account_id = p_account and m.role = 'parent' and m.status = 'active';
$$;

create or replace function public.family_account_is_parent(p_account uuid, p_user uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.family_account_members m
                  where m.family_account_id = p_account and m.user_id = p_user
                    and m.role = 'parent' and m.status = 'active');
$$;

create or replace function public.family_account_is_member(p_account uuid, p_user uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.family_account_members m
                  where m.family_account_id = p_account and m.user_id = p_user and m.status = 'active');
$$;

-- Live subscription with its plan capacity (at most one row).
create or replace function public.family_account_live_subscription(p_account uuid)
returns table (subscription_id uuid, plan_id uuid, plan_code text, billing_period text, status text,
               max_family_members integer, max_parent_seats integer)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, s.plan_id, s.plan_code, s.billing_period, s.status,
         p.max_family_members::integer, p.max_parent_seats::integer
    from public.subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
   where s.family_account_id = p_account and s.status in ('trialing', 'active', 'grace', 'past_due');
$$;

create or replace function public.family_account_refresh_capacity(p_account uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.subscriptions s
     set over_capacity = public.family_account_active_member_count(p_account) > p.max_family_members
    from public.subscription_plans p
   where p.id = s.plan_id and s.family_account_id = p_account
     and s.status in ('trialing', 'active', 'grace', 'past_due');
$$;

-- Activation guard. Serialised per account by a row lock so concurrent
-- activations can never exceed parent seats or plan capacity.
create or replace function public.family_account_activate_member(
  p_account uuid,
  p_user uuid,
  p_as_parent boolean,
  p_relationship_label text,
  p_invited_by uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.family_account_members;
  v_sub record;
begin
  perform 1 from public.family_accounts a where a.id = p_account for update;
  select * into m from public.family_account_members x
   where x.family_account_id = p_account and x.user_id = p_user;

  if found and m.status = 'active' and (m.role = 'parent' or not p_as_parent) then
    return; -- already counted (e.g. added to a sibling)
  end if;

  if p_as_parent then
    if public.family_account_active_parent_count(p_account) >= 2 then
      raise exception 'both parent seats are taken' using errcode = 'P0001', hint = 'parent_seats_full';
    end if;
  else
    select * into v_sub from public.family_account_live_subscription(p_account);
    if found then
      if public.family_account_active_member_count(p_account) >= v_sub.max_family_members then
        raise exception 'family plan capacity is full' using errcode = 'P0001', hint = 'family_capacity_full';
      end if;
    elsif coalesce((select f.enabled from public.platform_flags f where f.key = 'subscription_enforcement'), false) then
      raise exception 'an active family subscription is required' using errcode = 'P0001', hint = 'subscription_required';
    end if;
  end if;

  insert into public.family_account_members (family_account_id, user_id, role, relationship_label, status,
                                             invited_by, activated_at)
  values (p_account, p_user, case when p_as_parent then 'parent' else 'family_member' end,
          nullif(btrim(p_relationship_label), ''), 'active', p_invited_by, now())
  on conflict (family_account_id, user_id) do update
     set role = excluded.role, status = 'active', activated_at = now(), removed_at = null,
         relationship_label = coalesce(public.family_account_members.relationship_label, excluded.relationship_label);
  perform public.family_account_refresh_capacity(p_account);
end;
$$;

-- Compatibility layer: per-baby memberships drive account membership.
create or replace function public.family_members_account_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
begin
  if tg_op = 'INSERT' then
    select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = new.baby_id;
    if v_account is null then
      return new; -- legacy baby, not yet mapped
    end if;
    perform public.family_account_activate_member(
      v_account, new.user_id, new.relation in ('anne', 'baba') and new.is_admin,
      coalesce(new.relation_label, new.relation), new.invited_by);
    return new;
  end if;

  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = old.baby_id;
  if v_account is not null and not exists (
    select 1 from public.family_members fm
      join public.family_account_babies fab on fab.baby_id = fm.baby_id
     where fab.family_account_id = v_account and fm.user_id = old.user_id
  ) then
    update public.family_account_members
       set status = 'removed', removed_at = now()
     where family_account_id = v_account and user_id = old.user_id and status = 'active';
    perform public.family_account_refresh_capacity(v_account);
  end if;
  return old;
end;
$$;

create trigger family_members_account_sync
  after insert or delete on public.family_members
  for each row execute function public.family_members_account_sync();

-- Baby creation joins (or creates) the creator's family account atomically.
drop function public.create_baby(text, date, text, text, text, time, text, integer, numeric, text);

create or replace function public.create_baby(
  p_first_name text,
  p_birth_date date,
  p_relation text,
  p_relation_label text default null,
  p_last_name text default null,
  p_birth_time time default null,
  p_birth_place text default null,
  p_birth_weight_grams integer default null,
  p_birth_length_cm numeric default null,
  p_story text default null,
  p_family_account_id uuid default null
)
returns public.babies
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_baby public.babies;
  v_count integer;
  v_account uuid := p_family_account_id;
  v_accounts uuid[];
  v_name text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select count(*) into v_count from public.babies where created_by = v_uid and created_at > now() - interval '1 hour';
  if v_count >= 10 then
    raise exception 'too many babies created, try later' using errcode = 'P0001';
  end if;

  if v_account is not null then
    if not public.family_account_is_parent(v_account, v_uid) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
  else
    select coalesce(array_agg(m.family_account_id), '{}') into v_accounts
      from public.family_account_members m
     where m.user_id = v_uid and m.role = 'parent' and m.status = 'active';
    if cardinality(v_accounts) > 1 then
      raise exception 'choose a family account' using errcode = 'P0001', hint = 'family_account_ambiguous';
    elsif cardinality(v_accounts) = 1 then
      v_account := v_accounts[1];
    else
      select nullif(btrim(p.display_name), '') into v_name from public.profiles p where p.id = v_uid;
      insert into public.family_accounts (display_name, created_by)
      values (case when v_name is null then 'Ailem' else public.tr_suffix(v_name, 'genitive') || ' ailesi' end, v_uid)
      returning id into v_account;
      insert into public.family_account_members (family_account_id, user_id, role, relationship_label, status, activated_at)
      values (v_account, v_uid, 'parent', coalesce(nullif(btrim(p_relation_label), ''), p_relation), 'active', now());
    end if;
  end if;

  insert into public.babies (first_name, last_name, birth_date, birth_time, birth_place,
                             birth_weight_grams, birth_length_cm, story, created_by)
  values (btrim(p_first_name), nullif(btrim(p_last_name), ''), p_birth_date, p_birth_time,
          nullif(btrim(p_birth_place), ''), p_birth_weight_grams, p_birth_length_cm,
          nullif(btrim(p_story), ''), v_uid)
  returning * into v_baby;

  insert into public.family_account_babies (baby_id, family_account_id) values (v_baby.id, v_account);

  insert into public.family_members (baby_id, user_id, relation, relation_label, is_admin, permissions, invited_by)
  values (v_baby.id, v_uid, p_relation, nullif(btrim(p_relation_label), ''), true,
          array(select key from public.permissions), null);

  return v_baby;
end;
$$;

revoke all on function public.create_baby(text, date, text, text, text, time, text, integer, numeric, text, uuid) from public, anon;
grant execute on function public.create_baby(text, date, text, text, text, time, text, integer, numeric, text, uuid)
  to authenticated, service_role;

-- Legacy backfill: exact matches only -----------------------------------------------------------
-- A baby's parent set = its anne/baba admins. Babies with an identical parent
-- set of 1-2 users become one account. A user that appears in two different
-- parent sets (or already parents another account with a different set) is
-- ambiguous: those babies go to the report instead of merging households.
create or replace function public.backfill_family_accounts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_account uuid;
  v_created integer := 0;
  v_linked integer := 0;
  v_n integer;
  v_name text;
begin
  drop table if exists pg_temp.fa_babies;
  create temp table fa_babies as
  select b.id as baby_id,
         coalesce(array(
           select fm.user_id from public.family_members fm
            where fm.baby_id = b.id and fm.relation in ('anne', 'baba') and fm.is_admin
            order by fm.user_id), '{}') as parents
    from public.babies b
   where not exists (select 1 from public.family_account_babies fab where fab.baby_id = b.id)
     and not exists (select 1 from public.family_account_migration_report rep
                      where rep.baby_id = b.id and rep.resolved_at is null);

  insert into public.family_account_migration_report (baby_id, reason, parent_ids)
  select fb.baby_id, case when cardinality(fb.parents) = 0 then 'no_parent' else 'too_many_parents' end, fb.parents
    from fa_babies fb
   where cardinality(fb.parents) = 0 or cardinality(fb.parents) > 2;
  delete from fa_babies fb where cardinality(fb.parents) = 0 or cardinality(fb.parents) > 2;

  with sets as (select distinct fb.parents from fa_babies fb),
       existing as (
         select a.id, array(select m.user_id from public.family_account_members m
                             where m.family_account_id = a.id and m.role = 'parent' and m.status = 'active'
                             order by m.user_id) as parents
           from public.family_accounts a
       ),
       ambiguous_users as (
         select u from sets s, unnest(s.parents) u group by u having count(*) > 1
         union
         select u from sets s cross join lateral unnest(s.parents) u
          where exists (select 1 from existing e where u = any (e.parents) and e.parents <> s.parents)
       ),
       ambiguous as (
         select fb.baby_id, fb.parents from fa_babies fb
          where exists (select 1 from ambiguous_users au where au.u = any (fb.parents))
       ), reported as (
         insert into public.family_account_migration_report (baby_id, reason, parent_ids)
         select a.baby_id, 'ambiguous_parent_sets', a.parents from ambiguous a
         returning baby_id
       )
  delete from fa_babies fb using reported rp where rp.baby_id = fb.baby_id;

  for r in select distinct fb.parents from fa_babies fb loop
    select a.id into v_account
      from public.family_accounts a
     where array(select m.user_id from public.family_account_members m
                  where m.family_account_id = a.id and m.role = 'parent' and m.status = 'active'
                  order by m.user_id) = r.parents
     limit 1;
    if v_account is null then
      select nullif(btrim(p.display_name), '') into v_name from public.profiles p where p.id = r.parents[1];
      insert into public.family_accounts (display_name, created_by)
      values (case when v_name is null then 'Ailem' else public.tr_suffix(v_name, 'genitive') || ' ailesi' end, r.parents[1])
      returning id into v_account;
      insert into public.family_account_members (family_account_id, user_id, role, relationship_label, status, activated_at)
      select v_account, u, 'parent',
             (select fm.relation from public.family_members fm
                join fa_babies fb on fb.baby_id = fm.baby_id
               where fm.user_id = u and fb.parents = r.parents limit 1),
             'active', now()
        from unnest(r.parents) u;
      v_created := v_created + 1;
    end if;

    insert into public.family_account_babies (baby_id, family_account_id)
    select fb.baby_id, v_account from fa_babies fb where fb.parents = r.parents;
    get diagnostics v_n = row_count;
    v_linked := v_linked + v_n;

    -- Everyone else in these babies' circles joins as an active Family Member
    -- (legacy mapping never removes or blocks anyone; capacity is applied
    -- once a plan exists, see over_capacity).
    insert into public.family_account_members (family_account_id, user_id, role, relationship_label, status, activated_at)
    select distinct on (fm.user_id) v_account, fm.user_id, 'family_member',
           coalesce(fm.relation_label, fm.relation), 'active', now()
      from public.family_members fm
      join fa_babies fb on fb.baby_id = fm.baby_id
     where fb.parents = r.parents and not (fm.user_id = any (r.parents))
     order by fm.user_id, fm.joined_at
    on conflict (family_account_id, user_id) do nothing;
    v_account := null;
  end loop;

  drop table if exists pg_temp.fa_babies;
  return jsonb_build_object('created_accounts', v_created, 'linked_babies', v_linked,
                            'unresolved_babies', (select count(*) from public.family_account_migration_report
                                                   where resolved_at is null));
end;
$$;

-- Manual resolution for a reported baby (operations, service role).
create or replace function public.resolve_family_account_mapping(p_baby_id uuid, p_family_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  fm record;
begin
  if exists (select 1 from public.family_account_babies where baby_id = p_baby_id) then
    raise exception 'baby is already mapped' using errcode = 'P0001';
  end if;
  insert into public.family_account_babies (baby_id, family_account_id) values (p_baby_id, p_family_account_id);
  for fm in select * from public.family_members where baby_id = p_baby_id order by joined_at loop
    if not exists (select 1 from public.family_account_members m
                    where m.family_account_id = p_family_account_id and m.user_id = fm.user_id and m.status = 'active') then
      insert into public.family_account_members (family_account_id, user_id, role, relationship_label, status, activated_at)
      values (p_family_account_id, fm.user_id,
              case when fm.relation in ('anne', 'baba') and fm.is_admin
                        and public.family_account_active_parent_count(p_family_account_id) < 2
                   then 'parent' else 'family_member' end,
              coalesce(fm.relation_label, fm.relation), 'active', now())
      on conflict (family_account_id, user_id) do update set status = 'active', removed_at = null, activated_at = now();
    end if;
  end loop;
  update public.family_account_migration_report
     set resolved_at = now(), resolved_family_account_id = p_family_account_id
   where baby_id = p_baby_id and resolved_at is null;
  perform public.family_account_refresh_capacity(p_family_account_id);
end;
$$;

-- Checkout intent (the only thing a client can start) ----------------------------------------
create or replace function public.request_subscription_checkout(
  p_family_account_id uuid,
  p_plan_code text,
  p_billing_period text
)
returns table (
  intent_id uuid,
  provider text,
  provider_product_id text,
  plan_code text,
  billing_period text,
  price_minor integer,
  currency text,
  max_family_members integer,
  active_family_members integer,
  would_exceed_capacity boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.subscription_plans;
  v_product text;
  v_intent uuid;
  v_active integer;
begin
  if auth.uid() is null or not public.family_account_is_parent(p_family_account_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  select * into v_plan from public.current_subscription_plans() p
   where p.code = p_plan_code and p.billing_period = p_billing_period;
  if not found then
    raise exception 'unknown plan' using errcode = '22023';
  end if;
  select pp.provider_product_id into v_product
    from public.subscription_plan_provider_products pp
   where pp.provider = public.billing_active_provider() and pp.plan_id = v_plan.id;
  if v_product is null then
    raise exception 'plan is not sold by the active provider' using errcode = '55000';
  end if;
  v_active := public.family_account_active_member_count(p_family_account_id);

  insert into public.subscription_checkout_intents (family_account_id, requested_by, plan_id, provider, price_minor, currency)
  values (p_family_account_id, auth.uid(), v_plan.id, public.billing_active_provider(), v_plan.price_minor, v_plan.currency)
  returning id into v_intent;

  return query select v_intent, public.billing_active_provider(), v_product, v_plan.code, v_plan.billing_period,
                      v_plan.price_minor, v_plan.currency, v_plan.max_family_members::integer, v_active,
                      v_active > v_plan.max_family_members;
end;
$$;

-- Verified provider event -> subscription projection (service role only) ----------------------
-- Payload (normalised by the provider adapter):
--   provider_subscription_id, provider_product_id, status, [checkout_intent_id],
--   [provider_customer_id], [current_period_start], [current_period_end],
--   [cancel_at_period_end], [family_account_id]
create or replace function public.billing_apply_event(
  p_provider text,
  p_provider_event_id text,
  p_event_type text,
  p_payload jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event bigint;
  v_status text;
  v_plan public.subscription_plans;
  v_sub public.subscriptions;
  v_intent public.subscription_checkout_intents;
  v_account uuid;
  v_sub_ext text := nullif(p_payload ->> 'provider_subscription_id', '');
begin
  if p_provider is null or p_provider_event_id is null or p_event_type is null or p_payload is null then
    raise exception 'incomplete event' using errcode = '22023';
  end if;
  insert into public.billing_events (provider, provider_event_id, event_type, payload)
  values (p_provider, p_provider_event_id, p_event_type, p_payload)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_event;
  if v_event is null then
    return 'duplicate';
  end if;

  begin
    if v_sub_ext is null then
      raise exception 'provider_subscription_id is required';
    end if;
    v_status := case p_payload ->> 'status'
      when 'trialing' then 'trialing'
      when 'active' then 'active'
      when 'in_grace_period' then 'grace'
      when 'grace' then 'grace'
      when 'past_due' then 'past_due'
      when 'canceled' then 'canceled'
      when 'cancelled' then 'canceled'
      when 'expired' then 'expired'
    end;
    if v_status is null then
      raise exception 'unknown provider status %', p_payload ->> 'status';
    end if;
    select p.* into v_plan
      from public.subscription_plan_provider_products pp
      join public.subscription_plans p on p.id = pp.plan_id
     where pp.provider = p_provider and pp.provider_product_id = p_payload ->> 'provider_product_id';
    if not found then
      raise exception 'unknown provider product';
    end if;

    select * into v_sub from public.subscriptions s
     where s.provider = p_provider and s.provider_subscription_id = v_sub_ext
     for update;

    if nullif(p_payload ->> 'checkout_intent_id', '') is not null then
      select * into v_intent from public.subscription_checkout_intents i
       where i.id = (p_payload ->> 'checkout_intent_id')::uuid and i.provider = p_provider
       for update;
      if not found then
        raise exception 'unknown checkout intent';
      end if;
    end if;

    if v_sub.id is null then
      -- A new subscription is only bound through the parent's own checkout intent.
      if v_intent.id is null then
        raise exception 'a checkout intent is required for a new subscription';
      end if;
      if v_intent.status <> 'open' or v_intent.expires_at <= now() then
        raise exception 'checkout intent is not open';
      end if;
      if v_intent.plan_id <> v_plan.id then
        raise exception 'product does not match the checkout intent';
      end if;
      if nullif(p_payload ->> 'family_account_id', '') is not null
         and (p_payload ->> 'family_account_id')::uuid <> v_intent.family_account_id then
        raise exception 'family account mismatch';
      end if;
      v_account := v_intent.family_account_id;
      insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider,
                                        provider_customer_id, provider_subscription_id, current_period_start,
                                        current_period_end, cancel_at_period_end)
      values (v_account, v_plan.id, v_plan.code, v_plan.billing_period, v_status, p_provider,
              p_payload ->> 'provider_customer_id', v_sub_ext,
              (p_payload ->> 'current_period_start')::timestamptz, (p_payload ->> 'current_period_end')::timestamptz,
              coalesce((p_payload ->> 'cancel_at_period_end')::boolean, false))
      returning * into v_sub;
      update public.subscription_checkout_intents set status = 'consumed', consumed_at = now() where id = v_intent.id;
    else
      v_account := v_sub.family_account_id;
      if (v_intent.id is not null and v_intent.family_account_id <> v_account)
         or (nullif(p_payload ->> 'family_account_id', '') is not null
             and (p_payload ->> 'family_account_id')::uuid <> v_account) then
        raise exception 'family account mismatch';
      end if;
      update public.subscriptions
         set plan_id = v_plan.id, plan_code = v_plan.code, billing_period = v_plan.billing_period,
             status = v_status,
             provider_customer_id = coalesce(p_payload ->> 'provider_customer_id', provider_customer_id),
             current_period_start = coalesce((p_payload ->> 'current_period_start')::timestamptz, current_period_start),
             current_period_end = coalesce((p_payload ->> 'current_period_end')::timestamptz, current_period_end),
             cancel_at_period_end = coalesce((p_payload ->> 'cancel_at_period_end')::boolean, cancel_at_period_end)
       where id = v_sub.id
      returning * into v_sub;
      if v_intent.id is not null and v_intent.status = 'open' then
        update public.subscription_checkout_intents set status = 'consumed', consumed_at = now() where id = v_intent.id;
      end if;
    end if;

    perform public.family_account_refresh_capacity(v_account);
    update public.billing_events set result = 'applied', family_account_id = v_account, subscription_id = v_sub.id
     where id = v_event;
    return 'applied';
  exception when others then
    update public.billing_events set result = 'rejected', error = left(sqlerrm, 500) where id = v_event;
    return 'rejected';
  end;
end;
$$;

-- Read models for the app ---------------------------------------------------------------------
create or replace function public.subscription_plan_catalog()
returns table (
  plan_code text,
  billing_period text,
  version integer,
  max_parent_seats integer,
  max_family_members integer,
  price_minor integer,
  currency text
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.code, p.billing_period, p.version, p.max_parent_seats::integer, p.max_family_members::integer,
         p.price_minor, p.currency
    from public.current_subscription_plans() p
   order by p.max_family_members, p.billing_period desc;
$$;

create or replace function public.family_account_id_for_baby(p_baby_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  return (select fab.family_account_id from public.family_account_babies fab where fab.baby_id = p_baby_id);
end;
$$;

create or replace function public.family_account_overview(p_family_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account public.family_accounts;
  v_role text;
  v_sub jsonb;
begin
  select m.role into v_role from public.family_account_members m
   where m.family_account_id = p_family_account_id and m.user_id = auth.uid() and m.status = 'active';
  if v_role is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select * into v_account from public.family_accounts where id = p_family_account_id;

  select jsonb_build_object(
           'plan_code', s.plan_code, 'billing_period', s.billing_period, 'status', s.status,
           'current_period_end', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
           'over_capacity', s.over_capacity, 'max_family_members', p.max_family_members,
           'max_parent_seats', p.max_parent_seats, 'price_minor', p.price_minor, 'currency', p.currency)
    into v_sub
    from public.subscriptions s
    join public.subscription_plans p on p.id = s.plan_id
   where s.family_account_id = p_family_account_id
   order by (s.status in ('trialing', 'active', 'grace', 'past_due')) desc, s.updated_at desc
   limit 1;

  return jsonb_build_object(
    'id', v_account.id,
    'display_name', v_account.display_name,
    'my_role', v_role,
    'subscription', v_sub,
    'subscription_live', coalesce(v_sub ->> 'status' in ('trialing', 'active', 'grace', 'past_due'), false),
    'enforcement', coalesce((select f.enabled from public.platform_flags f where f.key = 'subscription_enforcement'), false),
    'active_parents', public.family_account_active_parent_count(p_family_account_id),
    'active_family_members', public.family_account_active_member_count(p_family_account_id),
    'babies', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.id, 'first_name', b.first_name) order by b.birth_date)
        from public.family_account_babies fab join public.babies b on b.id = fab.baby_id
       where fab.family_account_id = p_family_account_id), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', m.user_id,
               'display_name', coalesce(nullif(pr.display_name, ''), 'Aile üyesi'),
               'role', m.role, 'status', m.status, 'relationship_label', m.relationship_label)
             order by (m.role = 'parent') desc, (m.status = 'active') desc, m.activated_at)
        from public.family_account_members m left join public.profiles pr on pr.id = m.user_id
       where m.family_account_id = p_family_account_id and m.status <> 'removed'), '[]'::jsonb)
  );
end;
$$;

-- Grants ----------------------------------------------------------------------------------------
revoke all on function public.family_account_active_member_count(uuid),
  public.family_account_active_parent_count(uuid),
  public.family_account_is_parent(uuid, uuid),
  public.family_account_is_member(uuid, uuid),
  public.family_account_live_subscription(uuid),
  public.family_account_refresh_capacity(uuid),
  public.family_account_activate_member(uuid, uuid, boolean, text, uuid),
  public.family_members_account_sync(),
  public.current_subscription_plans(),
  public.backfill_family_accounts(),
  public.resolve_family_account_mapping(uuid, uuid),
  public.billing_apply_event(text, text, text, jsonb),
  public.subscription_plans_guard(),
  public.billing_events_append_only()
  from public, anon, authenticated;
grant execute on function public.backfill_family_accounts(),
  public.resolve_family_account_mapping(uuid, uuid),
  public.billing_apply_event(text, text, text, jsonb),
  public.family_account_live_subscription(uuid),
  public.current_subscription_plans()
  to service_role;

revoke all on function public.request_subscription_checkout(uuid, text, text),
  public.subscription_plan_catalog(),
  public.family_account_id_for_baby(uuid),
  public.family_account_overview(uuid),
  public.billing_active_provider()
  from public, anon;
grant execute on function public.request_subscription_checkout(uuid, text, text),
  public.subscription_plan_catalog(),
  public.family_account_id_for_baby(uuid),
  public.family_account_overview(uuid),
  public.billing_active_provider()
  to authenticated, service_role;

-- Map existing households now (exact matches only; the rest is reported).
select public.backfill_family_accounts();

commit;
