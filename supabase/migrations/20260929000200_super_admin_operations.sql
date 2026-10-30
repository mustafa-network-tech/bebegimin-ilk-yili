-- =====================================================================
-- Phase 5: audited Super Admin operations console.
--
--   * Platform Super Admin (platform_user_roles) is strictly separate from a
--     baby's family admin (family_members.is_admin). Every console RPC
--     re-checks the database role; client-side claims are never trusted.
--   * Read models expose the minimum personal data needed to decide:
--     baby first name, requester/decider display name, lifecycle dates.
--   * Console reads and writes are rate limited per admin and can be closed
--     with the `admin_console` platform flag.
--   * Role grants/revokes stay an operational (service-role) process and are
--     audited by trigger; there is no end-user UI for them.
-- =====================================================================
begin;

-- Kill switch for the console ---------------------------------------------------------
insert into public.platform_flags (key, enabled, note)
values ('admin_console', true, 'Phase 5: Super Admin operations console.')
on conflict (key) do nothing;

-- Role change audit (grants happen through the service role only) -----------------------
create table public.platform_role_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null,
  role       text not null,
  event      text not null check (event in ('granted', 'revoked', 'restored', 'deleted')),
  granted_by uuid,
  changed_by text not null default current_user,
  changed_at timestamptz not null default now()
);

alter table public.platform_role_events enable row level security;
revoke all on table public.platform_role_events from public, anon, authenticated;
grant all on table public.platform_role_events to service_role;

create or replace function public.platform_user_roles_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.platform_role_events (user_id, role, event, granted_by)
    values (new.user_id, new.role, 'granted', new.granted_by);
  elsif tg_op = 'UPDATE' then
    if old.revoked_at is null and new.revoked_at is not null then
      insert into public.platform_role_events (user_id, role, event, granted_by)
      values (new.user_id, new.role, 'revoked', new.granted_by);
    elsif old.revoked_at is not null and new.revoked_at is null then
      insert into public.platform_role_events (user_id, role, event, granted_by)
      values (new.user_id, new.role, 'restored', new.granted_by);
    end if;
  else
    insert into public.platform_role_events (user_id, role, event, granted_by)
    values (old.user_id, old.role, 'deleted', old.granted_by);
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.platform_user_roles_audit() from public, anon, authenticated;

create trigger platform_user_roles_audit
  after insert or update or delete on public.platform_user_roles
  for each row execute function public.platform_user_roles_audit();

-- Per-admin rate limiting ------------------------------------------------------------
create table public.admin_rate_limits (
  user_id      uuid not null references auth.users (id) on delete cascade,
  action       text not null,
  window_start timestamptz not null,
  hits         integer not null default 0,
  primary key (user_id, action, window_start)
);

alter table public.admin_rate_limits enable row level security;
revoke all on table public.admin_rate_limits from public, anon, authenticated;
grant all on table public.admin_rate_limits to service_role;

-- Gate for every console RPC: DB role + console flag + rate limit.
create or replace function public.assert_admin_console(p_action text, p_max_per_minute integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_window timestamptz := date_trunc('minute', clock_timestamp());
  v_hits integer;
begin
  if v_user is null or not public.is_super_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if not coalesce((select f.enabled from public.platform_flags f where f.key = 'admin_console'), true) then
    raise exception 'admin console is disabled' using errcode = '55000', hint = 'admin_console_disabled';
  end if;
  insert into public.admin_rate_limits (user_id, action, window_start, hits)
  values (v_user, p_action, v_window, 1)
  on conflict (user_id, action, window_start) do update set hits = public.admin_rate_limits.hits + 1
  returning hits into v_hits;
  if v_hits > p_max_per_minute then
    raise exception 'rate limit exceeded' using errcode = 'P0001', hint = 'rate_limited';
  end if;
  delete from public.admin_rate_limits
   where user_id = v_user and window_start < v_window - interval '1 hour';
end;
$$;

revoke all on function public.assert_admin_console(text, integer) from public, anon, authenticated;
grant execute on function public.assert_admin_console(text, integer) to service_role;

-- Safe ILIKE pattern from user input (length-limited, wildcards escaped).
create or replace function public.admin_search_pattern(p_search text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := nullif(btrim(p_search), '');
begin
  if v is null then
    return null;
  end if;
  if char_length(v) > 60 then
    raise exception 'search text is too long' using errcode = '22023';
  end if;
  return '%' || replace(replace(replace(v, '\', '\\'), '%', '\%'), '_', '\_') || '%';
end;
$$;

revoke all on function public.admin_search_pattern(text) from public, anon, authenticated;
grant execute on function public.admin_search_pattern(text) to service_role;

-- Who am I? Safe for every signed-in user; reveals nothing but the caller's
-- own role.
create or replace function public.admin_session()
returns table (is_super_admin boolean, console_enabled boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_super_admin(),
         public.is_super_admin()
           and coalesce((select f.enabled from public.platform_flags f where f.key = 'admin_console'), true);
$$;

-- Extension queue ---------------------------------------------------------------------
-- p_status: pending | decided | expired | all. Pending requests are ordered by
-- the closest base close date (SLA) and flagged urgent (<= 3 days) / soon
-- (<= 7 days). A pending request whose base close has passed is shown as
-- expired and can no longer be approved.
create or replace function public.admin_extension_queue(
  p_status text default 'pending',
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  request_id uuid,
  baby_id uuid,
  baby_first_name text,
  requested_days smallint,
  status text,
  requested_by_name text,
  requested_at timestamptz,
  base_close_date date,
  days_until_base_close integer,
  sla text,
  decided_by_name text,
  decided_at timestamptz,
  decision_note text,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.business_date_istanbul();
  v_pattern text;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform public.assert_admin_console('read', 120);
  if p_status is null or p_status not in ('pending', 'decided', 'expired', 'all') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;
  v_pattern := public.admin_search_pattern(p_search);

  return query
  with base as (
    select er.id, er.baby_id, b.first_name, er.requested_days, er.requested_by, er.created_at,
           er.decided_by, er.decided_at, er.decision_note,
           b.birth_date + 375 as base_close,
           case when er.status = 'pending' and v_today >= b.birth_date + 375 then 'expired' else er.status end
             as effective_status
      from public.baby_extension_requests er
      join public.babies b on b.id = er.baby_id
     where v_pattern is null
        or b.first_name ilike v_pattern escape '\'
        or er.baby_id::text = btrim(p_search)
        or er.id::text = btrim(p_search)
  ), filtered as (
    select * from base f
     where case p_status
             when 'pending' then f.effective_status = 'pending'
             when 'decided' then f.effective_status in ('approved', 'rejected')
             when 'expired' then f.effective_status = 'expired'
             else true
           end
  )
  select f.id, f.baby_id, f.first_name, f.requested_days, f.effective_status,
         coalesce(nullif(rp.display_name, ''), 'Aile üyesi'), f.created_at,
         f.base_close, f.base_close - v_today,
         case
           when f.effective_status <> 'pending' then null
           when f.base_close - v_today <= 3 then 'urgent'
           when f.base_close - v_today <= 7 then 'soon'
           else 'normal'
         end,
         dp.display_name, f.decided_at, f.decision_note,
         count(*) over ()
    from filtered f
    left join public.profiles rp on rp.id = f.requested_by
    left join public.profiles dp on dp.id = f.decided_by
   order by (f.effective_status = 'pending') desc,
            case when f.effective_status = 'pending' then f.base_close end asc nulls last,
            coalesce(f.decided_at, f.created_at) desc,
            f.id
   limit v_limit offset v_offset;
end;
$$;

-- Decision wrapper: console gate + rate limit + mandatory note for a
-- rejection. decide_baby_extension() keeps the row lock, immutability and the
-- atomic audit/notification.
create or replace function public.admin_decide_extension(
  p_request_id uuid,
  p_decision text,
  p_note text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('write', 30);
  if p_decision = 'rejected' and nullif(btrim(p_note), '') is null then
    raise exception 'a note is required to reject' using errcode = '22023', hint = 'decision_note_required';
  end if;
  return public.decide_baby_extension(p_request_id, p_decision, p_note);
end;
$$;

-- Baby lookup for birth-date corrections -------------------------------------------------
create or replace function public.admin_baby_lookup(p_query text, p_limit integer default 20)
returns table (
  baby_id uuid,
  first_name text,
  birth_date date,
  status text,
  base_close_date date,
  effective_close_date date,
  approved_extension_days integer,
  extension_status text,
  content_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.business_date_istanbul();
  v_query text := nullif(btrim(p_query), '');
  v_pattern text;
begin
  perform public.assert_admin_console('read', 120);
  if v_query is null or char_length(v_query) < 2 then
    raise exception 'search text is too short' using errcode = '22023', hint = 'search_too_short';
  end if;
  v_pattern := public.admin_search_pattern(v_query);

  return query
  select b.id, b.first_name, b.birth_date,
         case when v_today < b.birth_date + 375 + coalesce(ext.days, 0) then 'ACTIVE' else 'LOCKED' end,
         b.birth_date + 375,
         b.birth_date + 375 + coalesce(ext.days, 0),
         coalesce(ext.days, 0),
         er.status,
         (select count(*) from public.memories m where m.baby_id = b.id)
         + (select count(*) from public.milestones ms where ms.baby_id = b.id)
         + (select count(*) from public.letters l where l.baby_id = b.id)
         + (select count(*) from public.media md where md.baby_id = b.id)
         + (select count(*) from public.time_capsules c where c.baby_id = b.id)
    from public.babies b
    left join public.baby_extension_requests er on er.baby_id = b.id
    left join lateral (
      select er.requested_days::integer as days where er.status = 'approved'
    ) ext on true
   where b.id::text = v_query or b.first_name ilike v_pattern escape '\'
   order by b.first_name, b.id
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
end;
$$;

-- Lifecycle effect of a birth-date correction, shown before confirming.
create or replace function public.admin_preview_birth_date_correction(p_baby_id uuid, p_birth_date date)
returns table (
  birth_date_before date,
  birth_date_after date,
  status_before text,
  status_after text,
  base_close_before date,
  base_close_after date,
  effective_close_before date,
  effective_close_after date,
  approved_extension_days integer,
  would_reopen boolean,
  would_lock boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := public.business_date_istanbul();
  v_birth date;
  v_ext integer;
begin
  perform public.assert_admin_console('read', 120);
  if p_birth_date is null or p_birth_date > v_today or p_birth_date <= date '1900-01-01' then
    raise exception 'invalid birth date' using errcode = '22023';
  end if;
  select b.birth_date into v_birth from public.babies b where b.id = p_baby_id;
  if v_birth is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select coalesce(max(er.requested_days) filter (where er.status = 'approved'), 0)::integer
    into v_ext
    from public.baby_extension_requests er
   where er.baby_id = p_baby_id;

  return query
  select v_birth, p_birth_date,
         case when v_today < v_birth + 375 + v_ext then 'ACTIVE' else 'LOCKED' end,
         case when v_today < p_birth_date + 375 + v_ext then 'ACTIVE' else 'LOCKED' end,
         v_birth + 375, p_birth_date + 375,
         v_birth + 375 + v_ext, p_birth_date + 375 + v_ext,
         v_ext,
         v_today >= v_birth + 375 + v_ext and v_today < p_birth_date + 375 + v_ext,
         v_today < v_birth + 375 + v_ext and v_today >= p_birth_date + 375 + v_ext;
end;
$$;

-- Correction wrapper: console gate + rate limit; the audited rules live in
-- correct_baby_birth_date() (reason, reopen confirmation, security event).
create or replace function public.admin_correct_birth_date(
  p_baby_id uuid,
  p_birth_date date,
  p_reason text,
  p_confirm_reopen boolean default false
)
returns date
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('write', 30);
  return public.correct_baby_birth_date(p_baby_id, p_birth_date, p_reason, p_confirm_reopen);
end;
$$;

-- Audit log ---------------------------------------------------------------------------
-- Lifecycle-relevant actions only, with an allow-listed subset of details.
create or replace function public.admin_audit_log(
  p_action text default null,
  p_baby_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id bigint,
  created_at timestamptz,
  action text,
  baby_id uuid,
  baby_first_name text,
  actor_name text,
  details jsonb,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actions text[] := array[
    'extension_requested', 'extension_approved', 'extension_rejected', 'extension_expired',
    'birth_date_corrected', 'lifecycle_reopened', 'profile_locked', 'upload_quarantined'
  ];
  v_keys text[] := array[
    'requested_days', 'note', 'reason', 'birth_date_before', 'birth_date_after', 'actor_role',
    'effective_close_date', 'security_event', 'was_active', 'is_active'
  ];
begin
  perform public.assert_admin_console('read', 120);
  if p_action is not null and not (p_action = any (v_actions)) then
    raise exception 'invalid action filter' using errcode = '22023';
  end if;

  return query
  select al.id, al.created_at, al.action, al.baby_id, b.first_name,
         case when al.actor_id is null then 'Sistem' else coalesce(nullif(p.display_name, ''), 'Kullanıcı') end,
         coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(al.details) e where e.key = any (v_keys)),
                  '{}'::jsonb),
         count(*) over ()
    from public.activity_logs al
    join public.babies b on b.id = al.baby_id
    left join public.profiles p on p.id = al.actor_id
   where al.action = any (v_actions)
     and (p_action is null or al.action = p_action)
     and (p_baby_id is null or al.baby_id = p_baby_id)
   order by al.created_at desc, al.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 100)
   offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_session(),
  public.admin_extension_queue(text, text, integer, integer),
  public.admin_decide_extension(uuid, text, text),
  public.admin_baby_lookup(text, integer),
  public.admin_preview_birth_date_correction(uuid, date),
  public.admin_correct_birth_date(uuid, date, text, boolean),
  public.admin_audit_log(text, uuid, integer, integer)
  from public, anon;
grant execute on function public.admin_session(),
  public.admin_extension_queue(text, text, integer, integer),
  public.admin_decide_extension(uuid, text, text),
  public.admin_baby_lookup(text, integer),
  public.admin_preview_birth_date_correction(uuid, date),
  public.admin_correct_birth_date(uuid, date, text, boolean),
  public.admin_audit_log(text, uuid, integer, integer)
  to authenticated, service_role;

commit;
