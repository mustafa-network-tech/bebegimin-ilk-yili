-- =====================================================================
-- Audited, UUID-based unlimited test access.
--
-- This is deliberately separate from subscriptions, premium orders and
-- product entitlements. It never creates a store purchase or contributes to
-- revenue/payment statistics. An active grant gives every family in which
-- the user is an active parent unlimited non-financial access while all
-- membership, lifecycle, renderer, rate-limit and file-isolation checks stay
-- in force.
-- =====================================================================
begin;

create table public.test_access_grants (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  enabled        boolean not null default true,
  granted_at     timestamptz not null default now(),
  granted_by     uuid references auth.users (id) on delete set null,
  grant_reason   text not null check (char_length(btrim(grant_reason)) between 3 and 500),
  revoked_at     timestamptz,
  revoked_by     uuid references auth.users (id) on delete set null,
  revoke_reason  text check (revoke_reason is null or char_length(btrim(revoke_reason)) between 3 and 500),
  check ((enabled and revoked_at is null and revoked_by is null and revoke_reason is null)
      or (not enabled and revoked_at is not null and revoke_reason is not null))
);

create table public.test_access_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null,
  action      text not null check (action in ('granted', 'revoked')),
  actor_id    uuid references auth.users (id) on delete set null,
  reason      text not null check (char_length(btrim(reason)) between 3 and 500),
  created_at  timestamptz not null default now()
);

create index test_access_events_user_time_idx
  on public.test_access_events (user_id, created_at desc, id desc);

create or replace function public.test_access_events_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'test access audit events are append-only' using errcode = '42501';
end;
$$;

create trigger test_access_events_append_only
  before update or delete on public.test_access_events
  for each row execute function public.test_access_events_append_only();

alter table public.test_access_grants enable row level security;
alter table public.test_access_events enable row level security;
revoke all on table public.test_access_grants, public.test_access_events from public, anon, authenticated;
grant all on table public.test_access_grants, public.test_access_events to service_role;

-- Initial grants approved by the project owner. The join makes this forward
-- migration safe on fresh databases where demo users are seeded afterwards.
with approved (user_id, reason) as (
  values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'Owner-approved unlimited demo access'),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'Owner-approved unlimited demo access'),
    ('44444444-4444-4444-8444-444444444444'::uuid, 'Owner-approved unlimited demo access'),
    ('098ed0fd-b95a-42bb-8bdb-16050541466f'::uuid, 'Owner-approved unlimited demo access')
), inserted as (
  insert into public.test_access_grants (user_id, enabled, granted_by, grant_reason)
  select a.user_id, true, null, a.reason
    from approved a
    join auth.users u on u.id = a.user_id
  on conflict (user_id) do nothing
  returning user_id, grant_reason
)
insert into public.test_access_events (user_id, action, actor_id, reason)
select i.user_id, 'granted', null, i.grant_reason from inserted i;

-- Central predicates. Access follows the UUID and is effective for an account
-- only while that UUID is an active parent of that account.
create or replace function public.user_has_test_access(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null and exists (
    select 1 from public.test_access_grants g
     where g.user_id = p_user and g.enabled
  );
$$;

create or replace function public.family_account_has_test_access(p_account uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_account is not null and exists (
    select 1
      from public.family_account_members m
      join public.test_access_grants g on g.user_id = m.user_id and g.enabled
     where m.family_account_id = p_account
       and m.role = 'parent'
       and m.status = 'active'
  );
$$;

create or replace function public.baby_has_test_access(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_account_babies fab
     where fab.baby_id = p_baby_id
       and public.family_account_has_test_access(fab.family_account_id)
  );
$$;

-- Unlimited family-member seats for test families. The two-parent invariant is
-- intentionally retained because it is an authority boundary, not a paywall.
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
  v_test boolean;
begin
  perform 1 from public.family_accounts a where a.id = p_account for update;
  select * into m from public.family_account_members x
   where x.family_account_id = p_account and x.user_id = p_user;

  if found and m.status = 'active' and (m.role = 'parent' or not p_as_parent) then
    return;
  end if;

  v_test := public.family_account_has_test_access(p_account);
  if p_as_parent then
    if public.family_account_active_parent_count(p_account) >= 2 then
      raise exception 'both parent seats are taken' using errcode = 'P0001', hint = 'parent_seats_full';
    end if;
  elsif not v_test then
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

-- All content-write subscription checks flow through this predicate.
create or replace function public.baby_subscription_ok(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.subscription_enforcement_enabled()
      or public.baby_has_test_access(p_baby_id)
      or exists (
        select 1
          from public.family_account_babies fab
          join public.subscriptions s on s.family_account_id = fab.family_account_id
         where fab.baby_id = p_baby_id
           and public.subscription_grants_access(s.status, s.current_period_end)
      );
$$;

create or replace function public.baby_access_state(p_baby_id uuid)
returns table (
  allowed boolean,
  reason text,
  is_parent boolean,
  family_account_id uuid,
  subscription_status text,
  plan_code text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_sub record;
  v_parent boolean;
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  v_parent := v_account is not null and public.family_account_is_parent(v_account);
  select s.status, s.plan_code, s.current_period_end into v_sub
    from public.subscriptions s
   where s.family_account_id = v_account
   order by public.subscription_grants_access(s.status, s.current_period_end) desc, s.updated_at desc
   limit 1;

  return query select
    public.baby_subscription_ok(p_baby_id),
    case
      when v_account is not null and public.family_account_has_test_access(v_account) then 'test_access'
      when not public.subscription_enforcement_enabled() then 'enforcement_off'
      when v_account is null then 'account_unmapped'
      when v_sub.status is null then 'no_subscription'
      when public.subscription_grants_access(v_sub.status, v_sub.current_period_end) then 'ok'
      when v_sub.status = 'past_due' then 'payment_issue'
      else 'subscription_ended'
    end,
    v_parent,
    v_account,
    v_sub.status::text,
    v_sub.plan_code::text;
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
    'test_access', public.family_account_has_test_access(p_family_account_id),
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

-- Test families never open a real subscription checkout intent.
create or replace function public.request_subscription_checkout(
  p_family_account_id uuid,
  p_plan_code text,
  p_billing_period text,
  p_provider text default null
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
  v_provider text := coalesce(p_provider, public.billing_active_provider());
  v_plan public.subscription_plans;
  v_product text;
  v_intent uuid;
  v_active integer;
begin
  if auth.uid() is null or not public.family_account_is_parent(p_family_account_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if public.family_account_has_test_access(p_family_account_id) then
    raise exception 'unlimited test access already includes every plan feature'
      using errcode = 'P0001', hint = 'test_access_included';
  end if;
  if v_provider not in ('mock', 'app_store', 'google_play') then
    raise exception 'unknown provider' using errcode = '22023';
  end if;
  select * into v_plan from public.current_subscription_plans() p
   where p.code = p_plan_code and p.billing_period = p_billing_period;
  if not found then
    raise exception 'unknown plan' using errcode = '22023';
  end if;
  select pp.provider_product_id into v_product
    from public.subscription_plan_provider_products pp
   where pp.provider = v_provider and pp.plan_id = v_plan.id;
  if v_product is null then
    raise exception 'plan is not sold by this provider' using errcode = '55000';
  end if;
  v_active := public.family_account_active_member_count(p_family_account_id);

  insert into public.subscription_checkout_intents (family_account_id, requested_by, plan_id, provider, price_minor, currency)
  values (p_family_account_id, auth.uid(), v_plan.id, v_provider, v_plan.price_minor, v_plan.currency)
  returning id into v_intent;

  return query select v_intent, v_provider, v_product, v_plan.code, v_plan.billing_period,
                      v_plan.price_minor, v_plan.currency, v_plan.max_family_members::integer, v_active,
                      v_active > v_plan.max_family_members;
end;
$$;

-- Premium storefront: test access is presented as ownership, without any
-- premium_order or product_entitlement row.
create or replace function public.premium_purchase_block(p_baby_id uuid, p_user uuid default auth.uid())
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
begin
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null or not public.family_account_is_parent(v_account, p_user) then
    return 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return 'premium_requires_locked';
  end if;
  if public.family_account_has_test_access(v_account) then
    return 'test_access_included';
  end if;
  if not exists (
    select 1 from public.subscriptions s
     where s.family_account_id = v_account
       and public.subscription_grants_access(s.status, s.current_period_end)
  ) then
    return 'subscription_required';
  end if;
  if not coalesce((select f.enabled from public.platform_flags f where f.key = 'premium_storefront'), false) then
    return 'storefront_closed';
  end if;
  return null;
end;
$$;

create or replace function public.premium_storefront(p_baby_id uuid)
returns table (
  product_code text,
  price_minor integer,
  currency text,
  delivery_format text,
  owned boolean,
  purchase_block text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_block text;
  v_test boolean;
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null or not public.family_account_is_parent(v_account) then
    raise exception 'only parents see the premium storefront' using errcode = '42501', hint = 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    raise exception 'premium products open after the first year archive is locked'
      using errcode = '55000', hint = 'premium_requires_locked';
  end if;
  v_test := public.family_account_has_test_access(v_account);
  v_block := public.premium_purchase_block(p_baby_id);

  return query
  select p.code, p.price_minor, p.currency, p.delivery_format,
         v_test or exists (select 1 from public.product_entitlements e
                            where e.family_account_id = v_account and e.baby_id = p_baby_id
                              and e.product_code = p.code and e.status = 'active'),
         case
           when exists (select 1 from public.product_entitlements e
                         where e.family_account_id = v_account and e.baby_id = p_baby_id
                           and e.product_code = p.code and e.status = 'active') then 'already_owned'
           when v_test then 'test_access_included'
           else v_block
         end
    from public.current_premium_products() p
   order by p.price_minor;
end;
$$;

create or replace function public.baby_entitlements(p_baby_id uuid)
returns table (product_code text, status text, granted_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_test_granted_at timestamptz;
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select min(g.granted_at) into v_test_granted_at
    from public.family_account_babies fab
    join public.family_account_members m on m.family_account_id = fab.family_account_id
      and m.role = 'parent' and m.status = 'active'
    join public.test_access_grants g on g.user_id = m.user_id and g.enabled
   where fab.baby_id = p_baby_id;

  return query
  with sources as (
    select e.product_code, e.status, e.granted_at, 1 as priority
      from public.product_entitlements e
      join public.family_account_babies fab on fab.baby_id = e.baby_id and fab.family_account_id = e.family_account_id
     where e.baby_id = p_baby_id and e.status = 'active'
    union all
    select pc.code, 'active'::text, v_test_granted_at, 0
      from (values ('first_year_book'::text), ('first_year_html'::text), ('first_year_film'::text)) pc(code)
     where v_test_granted_at is not null
  )
  select distinct on (s.product_code) s.product_code, s.status, s.granted_at
    from sources s
   order by s.product_code, s.priority, s.granted_at;
end;
$$;

create or replace function public.request_premium_purchase(
  p_baby_id uuid,
  p_product_code text,
  p_provider text
)
returns table (
  order_id uuid,
  provider text,
  provider_product_id text,
  product_code text,
  price_minor integer,
  currency text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_block text;
  v_account uuid;
  v_product public.premium_products;
  v_store_id text;
  v_order uuid;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_provider not in ('mock', 'app_store', 'google_play') then
    raise exception 'unknown provider' using errcode = '22023';
  end if;
  v_block := public.premium_purchase_block(p_baby_id);
  if v_block = 'not_parent' then
    raise exception 'only parents can buy premium products' using errcode = '42501', hint = v_block;
  elsif v_block = 'test_access_included' then
    raise exception 'unlimited test access already includes this product'
      using errcode = 'P0001', hint = v_block;
  elsif v_block is not null then
    raise exception 'premium purchase is not available' using errcode = '55000', hint = v_block;
  end if;

  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  perform 1 from public.family_accounts a where a.id = v_account for update;
  select * into v_product from public.current_premium_products() p where p.code = p_product_code;
  if not found then
    raise exception 'unknown product' using errcode = '22023';
  end if;
  if exists (select 1 from public.product_entitlements e
              where e.family_account_id = v_account and e.baby_id = p_baby_id
                and e.product_code = p_product_code and e.status = 'active') then
    raise exception 'already owned' using errcode = 'P0001', hint = 'already_owned';
  end if;
  select pp.provider_product_id into v_store_id
    from public.premium_product_provider_products pp
   where pp.provider = p_provider and pp.product_id = v_product.id;
  if v_store_id is null then
    raise exception 'product is not sold by this provider' using errcode = '55000';
  end if;

  insert into public.premium_orders (family_account_id, baby_id, product_id, product_code, requested_by,
                                     price_minor, currency, provider)
  values (v_account, p_baby_id, v_product.id, v_product.code, auth.uid(), v_product.price_minor, v_product.currency,
          p_provider)
  returning id into v_order;

  return query select v_order, p_provider, v_store_id, v_product.code, v_product.price_minor, v_product.currency;
end;
$$;

-- Output creation keeps parent, LOCKED archive and product validation. Test
-- access substitutes only for the financial subscription + entitlement pair.
create or replace function public.output_request_block(p_baby_id uuid, p_product text, p_user uuid default auth.uid())
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
begin
  if public.output_product_mime(p_product) is null then
    raise exception 'unknown product' using errcode = '22023';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null or not public.family_account_is_parent(v_account, p_user) then
    return 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return 'premium_requires_locked';
  end if;
  if public.family_account_has_test_access(v_account) then
    return null;
  end if;
  if not exists (select 1 from public.subscriptions s
                  where s.family_account_id = v_account
                    and public.subscription_grants_access(s.status, s.current_period_end)) then
    return 'subscription_required';
  end if;
  if not exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_account and e.baby_id = p_baby_id
                    and e.product_code = p_product and e.status = 'active') then
    return 'entitlement_required';
  end if;
  return null;
end;
$$;

create or replace function public.output_create_snapshot(p_baby_id uuid, p_product text, p_user uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_content jsonb;
  v_checksum text;
  v_id uuid;
begin
  if public.output_product_mime(p_product) is null then
    raise exception 'unknown product' using errcode = '22023';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_user is not null and not public.family_account_is_parent(v_account, p_user) then
    raise exception 'only parents can create output snapshots'
      using errcode = '42501', hint = 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    raise exception 'snapshots are taken after the archive is locked'
      using errcode = '55000', hint = 'premium_requires_locked';
  end if;
  if not public.family_account_has_test_access(v_account) then
    if not exists (select 1 from public.subscriptions s
                    where s.family_account_id = v_account
                      and public.subscription_grants_access(s.status, s.current_period_end)) then
      raise exception 'an active subscription is required'
        using errcode = '55000', hint = 'subscription_required';
    end if;
    if not exists (select 1 from public.product_entitlements e
                    where e.family_account_id = v_account and e.baby_id = p_baby_id
                      and e.product_code = p_product and e.status = 'active') then
      raise exception 'no active entitlement for this product' using errcode = '42501', hint = 'entitlement_required';
    end if;
  end if;

  v_content := public.build_archive_snapshot_content(p_baby_id);
  v_checksum := encode(sha256(convert_to(v_content::text, 'UTF8')), 'hex');
  insert into public.archive_snapshots (family_account_id, baby_id, schema_version, content, checksum, content_bytes,
                                        item_counts, created_by)
  values (v_account, p_baby_id, 1, v_content, v_checksum, 1,
          jsonb_build_object(
            'members', jsonb_array_length(v_content -> 'members'),
            'milestones', jsonb_array_length(v_content -> 'milestones'),
            'memories', jsonb_array_length(v_content -> 'memories'),
            'letters', jsonb_array_length(v_content -> 'letters'),
            'media', jsonb_array_length(v_content -> 'media'),
            'comments', jsonb_array_length(v_content -> 'comments')),
          p_user)
  on conflict (family_account_id, baby_id, schema_version, checksum) do nothing
  returning id into v_id;
  if v_id is null then
    select s.id into v_id from public.archive_snapshots s
     where s.family_account_id = v_account and s.baby_id = p_baby_id and s.schema_version = 1 and s.checksum = v_checksum;
  end if;
  return v_id;
end;
$$;

create or replace function public.output_claim_jobs(
  p_worker text,
  p_products text[],
  p_limit integer default 1,
  p_lease_seconds integer default 120
)
returns table (
  job_id uuid,
  snapshot_id uuid,
  project_id uuid,
  baby_id uuid,
  product_code text,
  attempt integer,
  lease_expires_at timestamptz,
  settings jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_worker is null or p_worker !~ '^[A-Za-z0-9._:-]{1,80}$' then
    raise exception 'invalid worker id' using errcode = '22023';
  end if;
  if p_lease_seconds not between 30 and 900 or p_limit not between 1 and 10 then
    raise exception 'invalid lease or limit' using errcode = '22023';
  end if;
  if not public.output_worker_enabled() or coalesce(cardinality(p_products), 0) = 0 then
    return;
  end if;
  perform public.output_expire_leases();

  update public.output_jobs j
     set status = 'canceled', last_error_code = 'entitlement_revoked', finished_at = now()
   where j.status = 'queued'
     and not public.family_account_has_test_access(j.family_account_id)
     and not exists (select 1 from public.product_entitlements e
                      where e.family_account_id = j.family_account_id and e.baby_id = j.baby_id
                        and e.product_code = j.product_code and e.status = 'active');

  update public.output_jobs j
     set status = 'canceled', last_error_code = 'subscription_inactive', finished_at = now()
   where j.status = 'queued'
     and not public.family_account_has_test_access(j.family_account_id)
     and not exists (select 1 from public.subscriptions s
                      where s.family_account_id = j.family_account_id
                        and public.subscription_grants_access(s.status, s.current_period_end));

  update public.output_jobs j
     set status = 'canceled', last_error_code = 'lifecycle_reopened', finished_at = now()
   where j.status = 'queued' and coalesce(public.baby_lifecycle_active_internal(j.baby_id), true);

  return query
  with picked as (
    select j.id from public.output_jobs j
     where j.status = 'queued' and j.available_at <= now() and j.product_code = any (p_products)
     order by j.available_at, j.created_at
     limit p_limit
     for update skip locked
  ), claimed as (
    update public.output_jobs j
       set status = 'running', attempts = j.attempts + 1, lease_owner = p_worker,
           lease_expires_at = now() + make_interval(secs => p_lease_seconds), heartbeat_at = now(),
           started_at = coalesce(j.started_at, now())
      from picked
     where j.id = picked.id
    returning j.id, j.snapshot_id, j.project_id, j.baby_id, j.product_code, j.attempts, j.lease_expires_at
  ), logged as (
    insert into public.output_job_attempts (job_id, attempt, worker)
    select c.id, c.attempts, p_worker from claimed c
  )
  select c.id, c.snapshot_id, c.project_id, c.baby_id, c.product_code, c.attempts::integer, c.lease_expires_at, p.settings
    from claimed c
    join public.output_projects p on p.id = c.project_id;
end;
$$;

create or replace function public.output_artifact_download_block(p_artifact_id uuid, p_user uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id;
  if v_art.id is null or p_user is null then
    return 'not_found';
  end if;
  if not exists (select 1 from public.family_members fm where fm.baby_id = v_art.baby_id and fm.user_id = p_user)
     or not exists (select 1 from public.family_account_babies fab
                     where fab.baby_id = v_art.baby_id and fab.family_account_id = v_art.family_account_id) then
    return 'not_found';
  end if;
  if not public.family_account_is_member(v_art.family_account_id, p_user) then
    return 'membership_inactive';
  end if;
  if not public.family_account_is_parent(v_art.family_account_id, p_user) then
    return 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(v_art.baby_id), true) then
    return 'premium_requires_locked';
  end if;
  if not public.family_account_has_test_access(v_art.family_account_id) then
    if not exists (select 1 from public.subscriptions s
                    where s.family_account_id = v_art.family_account_id
                      and public.subscription_grants_access(s.status, s.current_period_end)) then
      return 'subscription_required';
    end if;
    if not exists (select 1 from public.product_entitlements e
                    where e.family_account_id = v_art.family_account_id and e.baby_id = v_art.baby_id
                      and e.product_code = v_art.product_code and e.status = 'active') then
      return 'entitlement_required';
    end if;
  end if;
  if v_art.status <> 'ready' then
    return 'artifact_not_ready';
  end if;
  return null;
end;
$$;

-- Super Admin read/write surface -----------------------------------------------------
create or replace function public.admin_test_access_users(
  p_search text default null,
  p_status text default 'all',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  email text,
  display_name text,
  user_created_at timestamptz,
  families jsonb,
  access_enabled boolean,
  granted_at timestamptz,
  granted_by uuid,
  revoked_at timestamptz,
  revoked_by uuid,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pattern text;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform public.assert_admin_console('read', 120);
  if p_status is null or p_status not in ('all', 'active', 'inactive') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;
  v_pattern := public.admin_search_pattern(p_search);

  return query
  with users as (
    select u.id, u.email::text as email, p.display_name, u.created_at,
           coalesce(jsonb_agg(distinct jsonb_build_object(
             'id', fa.id,
             'display_name', fa.display_name,
             'account_status', fa.status,
             'member_role', fam.role,
             'member_status', fam.status,
             'baby_count', (select count(*) from public.family_account_babies fab where fab.family_account_id = fa.id)
           )) filter (where fa.id is not null), '[]'::jsonb) as families,
           coalesce(g.enabled, false) as access_enabled,
           g.granted_at, g.granted_by, g.revoked_at, g.revoked_by
      from auth.users u
      left join public.profiles p on p.id = u.id
      left join public.family_account_members fam on fam.user_id = u.id
      left join public.family_accounts fa on fa.id = fam.family_account_id
      left join public.test_access_grants g on g.user_id = u.id
     where v_pattern is null
        or coalesce(u.email, '') ilike v_pattern escape '\'
        or coalesce(p.display_name, '') ilike v_pattern escape '\'
        or u.id::text = btrim(p_search)
     group by u.id, u.email, p.display_name, u.created_at, g.enabled,
              g.granted_at, g.granted_by, g.revoked_at, g.revoked_by
  ), filtered as (
    select * from users u
     where p_status = 'all'
        or (p_status = 'active' and u.access_enabled)
        or (p_status = 'inactive' and not u.access_enabled)
  )
  select f.id, f.email, f.display_name, f.created_at, f.families, f.access_enabled,
         f.granted_at, f.granted_by, f.revoked_at, f.revoked_by, count(*) over ()
    from filtered f
   order by f.access_enabled desc, f.created_at desc, f.id
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_test_access_events(
  p_user_id uuid default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  event_id bigint,
  user_id uuid,
  email text,
  display_name text,
  action text,
  actor_id uuid,
  actor_name text,
  reason text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform public.assert_admin_console('read', 120);
  return query
  select e.id, e.user_id, u.email::text, p.display_name, e.action, e.actor_id,
         coalesce(nullif(ap.display_name, ''), au.email::text, 'Migration'),
         e.reason, e.created_at, count(*) over ()
    from public.test_access_events e
    left join auth.users u on u.id = e.user_id
    left join public.profiles p on p.id = e.user_id
    left join auth.users au on au.id = e.actor_id
    left join public.profiles ap on ap.id = e.actor_id
   where p_user_id is null or e.user_id = p_user_id
   order by e.created_at desc, e.id desc
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_set_test_access(
  p_user_id uuid,
  p_enabled boolean,
  p_reason text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := nullif(btrim(p_reason), '');
  v_current boolean;
begin
  perform public.assert_admin_console('write', 30);
  if p_user_id is null or p_enabled is null then
    raise exception 'user and access state are required' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) not between 3 and 500 then
    raise exception 'reason must be between 3 and 500 characters' using errcode = '22023';
  end if;
  perform 1 from auth.users u where u.id = p_user_id for update;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  select g.enabled into v_current from public.test_access_grants g where g.user_id = p_user_id;
  if coalesce(v_current, false) = p_enabled and (v_current is not null or not p_enabled) then
    return 'unchanged';
  end if;

  if p_enabled then
    insert into public.test_access_grants
      (user_id, enabled, granted_at, granted_by, grant_reason, revoked_at, revoked_by, revoke_reason)
    values (p_user_id, true, now(), v_actor, v_reason, null, null, null)
    on conflict (user_id) do update
       set enabled = true, granted_at = now(), granted_by = v_actor, grant_reason = v_reason,
           revoked_at = null, revoked_by = null, revoke_reason = null;
    insert into public.test_access_events (user_id, action, actor_id, reason)
    values (p_user_id, 'granted', v_actor, v_reason);
    return 'granted';
  end if;

  update public.test_access_grants
     set enabled = false, revoked_at = now(), revoked_by = v_actor, revoke_reason = v_reason
   where user_id = p_user_id and enabled;
  if not found then
    return 'unchanged';
  end if;
  insert into public.test_access_events (user_id, action, actor_id, reason)
  values (p_user_id, 'revoked', v_actor, v_reason);
  return 'revoked';
end;
$$;

revoke all on function public.test_access_events_append_only(),
  public.user_has_test_access(uuid),
  public.family_account_has_test_access(uuid),
  public.baby_has_test_access(uuid)
  from public, anon, authenticated;
grant execute on function public.user_has_test_access(uuid),
  public.family_account_has_test_access(uuid),
  public.baby_has_test_access(uuid)
  to service_role;

revoke all on function public.admin_test_access_users(text, text, integer, integer),
  public.admin_test_access_events(uuid, integer, integer),
  public.admin_set_test_access(uuid, boolean, text)
  from public, anon;
grant execute on function public.admin_test_access_users(text, text, integer, integer),
  public.admin_test_access_events(uuid, integer, integer),
  public.admin_set_test_access(uuid, boolean, text)
  to authenticated, service_role;

commit;
