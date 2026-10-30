-- =====================================================================
-- Web admin read models.
--
-- These RPCs deliberately keep the underlying family, billing and premium
-- tables service-only. Every call re-checks the database-backed Super Admin
-- role, the admin_console kill switch and the existing per-admin rate limit.
-- Raw provider payloads and purchase tokens are never returned.
-- =====================================================================
begin;

create or replace function public.admin_dashboard_summary()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.business_date_istanbul();
begin
  perform public.assert_admin_console('read', 120);
  return jsonb_build_object(
    'users_total', (select count(*) from auth.users),
    'families_active', (select count(*) from public.family_accounts f where f.status = 'active'),
    'babies_total', (select count(*) from public.babies),
    'subscriptions_access_granting', (
      select count(*) from public.subscriptions s
       where s.status = 'grace'
          or (s.status in ('trialing', 'active')
              and (s.current_period_end is null or s.current_period_end > now() - interval '1 day'))
    ),
    'subscriptions_past_due', (select count(*) from public.subscriptions s where s.status = 'past_due'),
    'subscriptions_over_capacity', (select count(*) from public.subscriptions s where s.over_capacity),
    'premium_orders_paid', (select count(*) from public.premium_orders o where o.status = 'paid'),
    'premium_entitlements_active', (select count(*) from public.product_entitlements e where e.status = 'active'),
    'extension_requests_pending', (
      select count(*) from public.baby_extension_requests er
      join public.babies b on b.id = er.baby_id
      where er.status = 'pending' and v_today < b.birth_date + 375
    ),
    'payment_events_rejected_24h', (
      (select count(*) from public.billing_events e
        where e.result = 'rejected' and e.received_at >= now() - interval '24 hours')
      +
      (select count(*) from public.premium_order_events e
        where e.result = 'rejected' and e.received_at >= now() - interval '24 hours')
    ),
    'generated_at', now()
  );
end;
$$;

create or replace function public.admin_users_families(
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
  family_count bigint,
  families jsonb,
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
  if p_status is null or p_status not in ('all', 'with_family', 'without_family') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;
  v_pattern := public.admin_search_pattern(p_search);

  return query
  with users as (
    select u.id, u.email, p.display_name, u.created_at,
           count(distinct fam.family_account_id) filter (where fam.status <> 'removed') as family_count,
           coalesce(jsonb_agg(distinct jsonb_build_object(
             'id', fa.id,
             'display_name', fa.display_name,
             'account_status', fa.status,
             'member_role', fam.role,
             'member_status', fam.status,
             'baby_count', (select count(*) from public.family_account_babies fab where fab.family_account_id = fa.id)
           )) filter (where fa.id is not null), '[]'::jsonb) as families
      from auth.users u
      left join public.profiles p on p.id = u.id
      left join public.family_account_members fam on fam.user_id = u.id
      left join public.family_accounts fa on fa.id = fam.family_account_id
     where v_pattern is null
        or coalesce(u.email, '') ilike v_pattern escape '\'
        or coalesce(p.display_name, '') ilike v_pattern escape '\'
        or u.id::text = btrim(p_search)
     group by u.id, u.email, p.display_name, u.created_at
  ), filtered as (
    select * from users u
     where p_status = 'all'
        or (p_status = 'with_family' and u.family_count > 0)
        or (p_status = 'without_family' and u.family_count = 0)
  )
  select f.id, f.email, f.display_name, f.created_at, f.family_count, f.families, count(*) over ()
    from filtered f
   order by f.created_at desc, f.id
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_subscription_plans()
returns table (
  plan_id uuid,
  plan_code text,
  billing_period text,
  version integer,
  max_parent_seats integer,
  max_family_members integer,
  price_minor integer,
  currency text,
  active_from timestamptz,
  active_until timestamptz,
  catalog_active boolean,
  google_product_id text,
  google_base_plan_id text,
  app_store_product_id text,
  access_granting_subscriptions bigint,
  subscriptions_total bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('read', 120);
  return query
  select p.id, p.code, p.billing_period, p.version,
         p.max_parent_seats::integer, p.max_family_members::integer,
         p.price_minor, p.currency, p.active_from, p.active_until,
         p.active_from <= now() and (p.active_until is null or p.active_until > now()),
         split_part(g.provider_product_id, ':', 1),
         nullif(split_part(g.provider_product_id, ':', 2), ''),
         a.provider_product_id,
         count(s.id) filter (
           where s.status = 'grace'
              or (s.status in ('trialing', 'active')
                  and (s.current_period_end is null or s.current_period_end > now() - interval '1 day'))
         ),
         count(s.id)
    from public.subscription_plans p
    left join public.subscription_plan_provider_products g
      on g.plan_id = p.id and g.provider = 'google_play'
    left join public.subscription_plan_provider_products a
      on a.plan_id = p.id and a.provider = 'app_store'
    left join public.subscriptions s on s.plan_id = p.id
   group by p.id, g.provider_product_id, a.provider_product_id
   order by p.max_family_members, p.billing_period desc, p.version desc;
end;
$$;

create or replace function public.admin_subscriptions(
  p_status text default 'access_granting',
  p_plan_code text default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  subscription_id uuid,
  family_account_id uuid,
  family_name text,
  parent_count integer,
  family_member_count integer,
  baby_count bigint,
  plan_code text,
  billing_period text,
  status text,
  provider text,
  provider_reference_masked text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean,
  over_capacity boolean,
  updated_at timestamptz,
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
  if p_status is null or p_status not in
     ('access_granting', 'all', 'trialing', 'active', 'grace', 'past_due', 'canceled', 'expired') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;
  if p_plan_code is not null and p_plan_code not in ('small_family', 'normal_family', 'large_family') then
    raise exception 'invalid plan filter' using errcode = '22023';
  end if;
  v_pattern := public.admin_search_pattern(p_search);

  return query
  with filtered as (
    select s.*, fa.display_name as family_name
      from public.subscriptions s
      join public.family_accounts fa on fa.id = s.family_account_id
     where (p_status = 'all'
            or (p_status = 'access_granting' and
                (s.status = 'grace' or (s.status in ('trialing', 'active')
                 and (s.current_period_end is null or s.current_period_end > now() - interval '1 day'))))
            or s.status = p_status)
       and (p_plan_code is null or s.plan_code = p_plan_code)
       and (v_pattern is null
            or fa.display_name ilike v_pattern escape '\'
            or fa.id::text = btrim(p_search)
            or s.id::text = btrim(p_search))
  )
  select f.id, f.family_account_id, f.family_name,
         public.family_account_active_parent_count(f.family_account_id),
         public.family_account_active_member_count(f.family_account_id),
         (select count(*) from public.family_account_babies fab where fab.family_account_id = f.family_account_id),
         f.plan_code, f.billing_period, f.status, f.provider,
         case
           when f.provider_subscription_id is null then null
           when char_length(f.provider_subscription_id) <= 8 then repeat('*', char_length(f.provider_subscription_id))
           else left(f.provider_subscription_id, 4) || '…' || right(f.provider_subscription_id, 4)
         end,
         f.current_period_start, f.current_period_end, f.cancel_at_period_end,
         f.over_capacity, f.updated_at, count(*) over ()
    from filtered f
   order by f.updated_at desc, f.id
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_premium_products()
returns table (
  product_id uuid,
  product_code text,
  version integer,
  price_minor integer,
  currency text,
  delivery_format text,
  active_from timestamptz,
  active_until timestamptz,
  catalog_active boolean,
  storefront_enabled boolean,
  google_product_id text,
  app_store_product_id text,
  paid_orders bigint,
  refunded_or_revoked_orders bigint,
  active_entitlements bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('read', 120);
  return query
  select p.id, p.code, p.version, p.price_minor, p.currency, p.delivery_format,
         p.active_from, p.active_until,
         p.active_from <= now() and (p.active_until is null or p.active_until > now()),
         coalesce((select f.enabled from public.platform_flags f where f.key = 'premium_storefront'), false),
         g.provider_product_id, a.provider_product_id,
         count(distinct o.id) filter (where o.status = 'paid'),
         count(distinct o.id) filter (where o.status in ('refunded', 'revoked')),
         count(distinct e.id) filter (where e.status = 'active')
    from public.premium_products p
    left join public.premium_product_provider_products g
      on g.product_id = p.id and g.provider = 'google_play'
    left join public.premium_product_provider_products a
      on a.product_id = p.id and a.provider = 'app_store'
    left join public.premium_orders o on o.product_id = p.id
    left join public.product_entitlements e on e.source_order_id = o.id
   group by p.id, g.provider_product_id, a.provider_product_id
   order by p.price_minor, p.version desc;
end;
$$;

create or replace function public.admin_purchase_records(
  p_status text default 'all',
  p_product_code text default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  order_id uuid,
  family_account_id uuid,
  family_name text,
  baby_id uuid,
  baby_first_name text,
  product_code text,
  price_minor integer,
  currency text,
  provider text,
  provider_reference_masked text,
  status text,
  requested_by_name text,
  paid_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
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
  if p_status is null or p_status not in ('all', 'pending', 'paid', 'canceled', 'refunded', 'revoked') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;
  if p_product_code is not null and p_product_code not in
     ('first_year_book', 'first_year_html', 'first_year_film') then
    raise exception 'invalid product filter' using errcode = '22023';
  end if;
  v_pattern := public.admin_search_pattern(p_search);

  return query
  select o.id, o.family_account_id, fa.display_name, o.baby_id, b.first_name,
         o.product_code, o.price_minor, o.currency, o.provider,
         case
           when o.provider_order_ref is null then null
           when char_length(o.provider_order_ref) <= 8 then repeat('*', char_length(o.provider_order_ref))
           else left(o.provider_order_ref, 4) || '…' || right(o.provider_order_ref, 4)
         end,
         o.status, coalesce(nullif(pr.display_name, ''), 'Kullanıcı'),
         o.paid_at, o.created_at, o.updated_at, count(*) over ()
    from public.premium_orders o
    join public.family_accounts fa on fa.id = o.family_account_id
    join public.babies b on b.id = o.baby_id
    left join public.profiles pr on pr.id = o.requested_by
   where (p_status = 'all' or o.status = p_status)
     and (p_product_code is null or o.product_code = p_product_code)
     and (v_pattern is null
          or fa.display_name ilike v_pattern escape '\'
          or b.first_name ilike v_pattern escape '\'
          or o.id::text = btrim(p_search))
   order by o.created_at desc, o.id
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_payment_events(
  p_kind text default 'all',
  p_result text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  event_kind text,
  event_id bigint,
  provider text,
  provider_event_reference_masked text,
  event_type text,
  related_id uuid,
  result text,
  error_summary text,
  received_at timestamptz,
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
  if p_kind is null or p_kind not in ('all', 'subscription', 'premium') then
    raise exception 'invalid event kind' using errcode = '22023';
  end if;
  if p_result is not null and p_result not in ('applied', 'rejected') then
    raise exception 'invalid result filter' using errcode = '22023';
  end if;

  return query
  with events as (
    select 'subscription'::text as kind, e.id, e.provider, e.provider_event_id,
           e.event_type, e.subscription_id as related_id, e.result, e.error, e.received_at
      from public.billing_events e
     where p_kind in ('all', 'subscription') and (p_result is null or e.result = p_result)
    union all
    select 'premium'::text, e.id, e.provider, e.provider_event_id,
           e.event_type, e.order_id, e.result, e.error, e.received_at
      from public.premium_order_events e
     where p_kind in ('all', 'premium') and (p_result is null or e.result = p_result)
  )
  select e.kind, e.id, e.provider,
         case
           when char_length(e.provider_event_id) <= 8 then repeat('*', char_length(e.provider_event_id))
           else left(e.provider_event_id, 4) || '…' || right(e.provider_event_id, 4)
         end,
         e.event_type, e.related_id, e.result,
         case when e.error is null then null else left(e.error, 200) end,
         e.received_at, count(*) over ()
    from events e
   order by e.received_at desc, e.id desc
   limit v_limit offset v_offset;
end;
$$;

create or replace function public.admin_platform_audit_log(
  p_source text default 'all',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  source text,
  event_id bigint,
  action text,
  target text,
  actor text,
  details jsonb,
  created_at timestamptz,
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
  if p_source is null or p_source not in ('all', 'role', 'flag') then
    raise exception 'invalid audit source' using errcode = '22023';
  end if;

  return query
  with events as (
    select 'role'::text as source, e.id, e.event::text as action,
           e.user_id::text as target, e.changed_by::text as actor,
           jsonb_build_object('role', e.role, 'granted_by', e.granted_by) as details,
           e.changed_at as created_at
      from public.platform_role_events e where p_source in ('all', 'role')
    union all
    select 'flag'::text, e.id, 'flag_changed'::text, e.key, e.changed_by,
           jsonb_build_object('old_value', e.old_value, 'new_value', e.new_value, 'note', e.note),
           e.changed_at
      from public.platform_flag_events e where p_source in ('all', 'flag')
  )
  select e.source, e.id, e.action, e.target, e.actor, e.details, e.created_at, count(*) over ()
    from events e
   order by e.created_at desc, e.id desc
   limit v_limit offset v_offset;
end;
$$;

revoke all on function public.admin_dashboard_summary(),
  public.admin_users_families(text, text, integer, integer),
  public.admin_subscription_plans(),
  public.admin_subscriptions(text, text, text, integer, integer),
  public.admin_premium_products(),
  public.admin_purchase_records(text, text, text, integer, integer),
  public.admin_payment_events(text, text, integer, integer),
  public.admin_platform_audit_log(text, integer, integer)
  from public, anon;

grant execute on function public.admin_dashboard_summary(),
  public.admin_users_families(text, text, integer, integer),
  public.admin_subscription_plans(),
  public.admin_subscriptions(text, text, text, integer, integer),
  public.admin_premium_products(),
  public.admin_purchase_records(text, text, text, integer, integer),
  public.admin_payment_events(text, text, integer, integer),
  public.admin_platform_audit_log(text, integer, integer)
  to authenticated, service_role;

commit;
