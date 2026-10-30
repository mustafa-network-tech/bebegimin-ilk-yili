-- =====================================================================
-- Audited Google Play catalog checks initiated by the Super Admin panel.
--
-- Only normalized catalog state and prices are stored. Service-account
-- credentials, OAuth tokens, purchase tokens and raw Google responses never
-- cross this RPC boundary.
-- =====================================================================
begin;

create table public.google_play_catalog_checks (
  id                 bigint generated always as identity primary key,
  checked_by         uuid not null references auth.users (id),
  connection_status  text not null check (connection_status in
                       ('success', 'not_configured', 'permission_denied', 'unavailable')),
  package_name       text not null check (package_name = 'com.mkdigitalsystems.bebegimin_ilk_yili'),
  results            jsonb not null default '[]'::jsonb
                       check (jsonb_typeof(results) = 'array' and jsonb_array_length(results) <= 20),
  error_code         text check (error_code is null or error_code ~ '^[a-z0-9_]{3,80}$'),
  checked_at         timestamptz not null default now(),
  check ((connection_status = 'success' and error_code is null)
      or (connection_status <> 'success' and error_code is not null and results = '[]'::jsonb))
);

create index google_play_catalog_checks_time_idx
  on public.google_play_catalog_checks (checked_at desc, id desc);

create or replace function public.google_play_catalog_checks_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Google Play catalog checks are append-only' using errcode = '42501';
end;
$$;

create trigger google_play_catalog_checks_append_only
  before update or delete on public.google_play_catalog_checks
  for each row execute function public.google_play_catalog_checks_append_only();

alter table public.google_play_catalog_checks enable row level security;
revoke all on table public.google_play_catalog_checks from public, anon, authenticated;
grant all on table public.google_play_catalog_checks to service_role;

create or replace function public.admin_record_google_play_catalog_check(
  p_connection_status text,
  p_package_name text,
  p_results jsonb,
  p_error_code text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_item jsonb;
  v_kind text;
  v_product text;
  v_base text;
  v_status text;
  v_play_state text;
  v_expected_price integer;
  v_play_price integer;
  v_expected_currency text;
  v_play_currency text;
  v_detail text;
  v_sanitized jsonb := '[]'::jsonb;
begin
  perform public.assert_admin_console('write', 15);
  if p_connection_status is null or p_connection_status not in
     ('success', 'not_configured', 'permission_denied', 'unavailable') then
    raise exception 'invalid Google Play connection status' using errcode = '22023';
  end if;
  if p_package_name is distinct from 'com.mkdigitalsystems.bebegimin_ilk_yili' then
    raise exception 'invalid Google Play package' using errcode = '22023';
  end if;
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 20 then
    raise exception 'invalid Google Play catalog result' using errcode = '22023';
  end if;
  if p_error_code is not null and p_error_code !~ '^[a-z0-9_]{3,80}$' then
    raise exception 'invalid Google Play error code' using errcode = '22023';
  end if;
  if p_connection_status = 'success' then
    if p_error_code is not null then
      raise exception 'successful Google Play checks cannot have an error' using errcode = '22023';
    end if;
  elsif p_error_code is null or p_results <> '[]'::jsonb then
    raise exception 'failed Google Play checks cannot contain catalog results' using errcode = '22023';
  end if;

  for v_item in select value from jsonb_array_elements(p_results) loop
    v_kind := v_item ->> 'kind';
    v_product := v_item ->> 'product_id';
    v_base := nullif(v_item ->> 'base_plan_id', '');
    v_status := v_item ->> 'status';
    v_play_state := nullif(v_item ->> 'play_state', '');
    v_expected_price := (v_item ->> 'expected_price_minor')::integer;
    v_play_price := case when v_item -> 'play_price_minor' = 'null'::jsonb or not (v_item ? 'play_price_minor')
                         then null else (v_item ->> 'play_price_minor')::integer end;
    v_expected_currency := v_item ->> 'expected_currency';
    v_play_currency := nullif(v_item ->> 'play_currency', '');
    v_detail := nullif(v_item ->> 'detail_code', '');

    if v_kind is null or v_kind not in ('subscription', 'one_time')
       or v_status is null or v_status not in ('verified', 'not_found', 'mismatch') then
      raise exception 'invalid Google Play catalog item' using errcode = '22023';
    end if;
    if v_kind = 'subscription' and
       (v_product not in ('small_family', 'normal_family', 'large_family') or v_base not in ('monthly', 'annual')) then
      raise exception 'invalid Google Play subscription item' using errcode = '22023';
    end if;
    if v_kind = 'one_time' and
       (v_product not in ('first_year_book', 'first_year_html', 'first_year_film') or v_base is not null) then
      raise exception 'invalid Google Play one-time item' using errcode = '22023';
    end if;
    if v_expected_price is null or v_expected_price < 0 or v_play_price < 0
       or v_expected_currency is distinct from 'TRY'
       or (v_play_currency is not null and v_play_currency !~ '^[A-Z]{3}$') then
      raise exception 'invalid Google Play price result' using errcode = '22023';
    end if;
    if v_play_state is not null and v_play_state !~ '^[A-Z_]{3,40}$' then
      raise exception 'invalid Google Play state' using errcode = '22023';
    end if;
    if v_detail is not null and v_detail !~ '^[a-z0-9_]{3,80}$' then
      raise exception 'invalid Google Play detail code' using errcode = '22023';
    end if;

    -- Rebuild from an allow-list so callers cannot persist raw provider data
    -- or secret-looking extra keys.
    v_sanitized := v_sanitized || jsonb_build_array(jsonb_build_object(
      'kind', v_kind,
      'product_id', v_product,
      'base_plan_id', v_base,
      'status', v_status,
      'play_state', v_play_state,
      'expected_price_minor', v_expected_price,
      'play_price_minor', v_play_price,
      'expected_currency', v_expected_currency,
      'play_currency', v_play_currency,
      'detail_code', v_detail
    ));
  end loop;

  insert into public.google_play_catalog_checks
    (checked_by, connection_status, package_name, results, error_code)
  values (auth.uid(), p_connection_status, p_package_name, v_sanitized, p_error_code)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_google_play_catalog_latest()
returns table (
  check_id bigint,
  connection_status text,
  package_name text,
  results jsonb,
  error_code text,
  checked_at timestamptz,
  checked_by uuid,
  checked_by_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('read', 120);
  return query
  select c.id, c.connection_status, c.package_name, c.results, c.error_code,
         c.checked_at, c.checked_by,
         coalesce(nullif(p.display_name, ''), u.email::text, 'Süper Admin')
    from public.google_play_catalog_checks c
    left join public.profiles p on p.id = c.checked_by
    left join auth.users u on u.id = c.checked_by
   order by c.checked_at desc, c.id desc
   limit 1;
end;
$$;

-- Extend the existing platform audit read model with the append-only catalog
-- checks. Only aggregate status is exposed here; item details stay on the
-- catalog pages.
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
  if p_source is null or p_source not in ('all', 'role', 'flag', 'google_play') then
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
    union all
    select 'google_play'::text, c.id, 'catalog_checked'::text, c.package_name, c.checked_by::text,
           jsonb_build_object(
             'connection_status', c.connection_status,
             'error_code', c.error_code,
             'verified', (select count(*) from jsonb_array_elements(c.results) i where i ->> 'status' = 'verified'),
             'mismatched', (select count(*) from jsonb_array_elements(c.results) i where i ->> 'status' <> 'verified')
           ), c.checked_at
      from public.google_play_catalog_checks c where p_source in ('all', 'google_play')
  )
  select e.source, e.id, e.action, e.target, e.actor, e.details, e.created_at, count(*) over ()
    from events e
   order by e.created_at desc, e.id desc
   limit v_limit offset v_offset;
end;
$$;

revoke all on function public.google_play_catalog_checks_append_only(),
  public.admin_record_google_play_catalog_check(text, text, jsonb, text),
  public.admin_google_play_catalog_latest(),
  public.admin_platform_audit_log(text, integer, integer)
  from public, anon;
revoke all on function public.google_play_catalog_checks_append_only() from authenticated;

grant execute on function public.admin_record_google_play_catalog_check(text, text, jsonb, text),
  public.admin_google_play_catalog_latest(),
  public.admin_platform_audit_log(text, integer, integer)
  to authenticated, service_role;

commit;
