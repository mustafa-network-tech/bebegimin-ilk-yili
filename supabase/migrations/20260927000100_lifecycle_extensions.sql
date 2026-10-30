-- =====================================================================
-- Phase 2: server-authoritative 375/405-day lifecycle, one-time
-- extension requests, and the Super Admin security boundary.
-- =====================================================================
begin;

create table public.platform_user_roles (
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null check (role = 'super_admin'),
  granted_by uuid references auth.users (id) on delete set null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (user_id, role),
  check (revoked_at is null or revoked_at >= granted_at)
);

comment on table public.platform_user_roles is
  'Platform-wide privileged roles. Only trusted service operations may write this table.';

alter table public.platform_user_roles enable row level security;
revoke all on table public.platform_user_roles from public, anon, authenticated;
grant select on table public.platform_user_roles to authenticated;
grant all on table public.platform_user_roles to service_role;

create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_user_roles pur
    where pur.user_id = auth.uid()
      and pur.role = 'super_admin'
      and pur.revoked_at is null
  );
$$;

revoke all on function public.is_super_admin() from public, anon;
grant execute on function public.is_super_admin() to authenticated, service_role;

create policy "super admins read platform roles"
  on public.platform_user_roles for select to authenticated
  using (public.is_super_admin());

create table public.baby_extension_requests (
  id             uuid primary key default gen_random_uuid(),
  baby_id        uuid not null references public.babies (id) on delete cascade,
  requested_by   uuid references auth.users (id) on delete set null,
  requested_days smallint not null check (requested_days between 1 and 30),
  status         text not null default 'pending'
                   check (status in ('pending', 'approved', 'rejected', 'expired')),
  decided_by     uuid references auth.users (id) on delete set null,
  decided_at     timestamptz,
  decision_note  text check (decision_note is null or char_length(decision_note) <= 2000),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (baby_id),
  check (
    (status = 'pending' and decided_by is null and decided_at is null and decision_note is null)
    or (status in ('approved', 'rejected') and decided_by is not null and decided_at is not null)
    or (status = 'expired' and decided_by is null and decided_at is not null)
  )
);

create index baby_extension_requests_status_idx
  on public.baby_extension_requests (status, created_at);

comment on table public.baby_extension_requests is
  'Exactly one lifetime extension request per baby, including rejected and expired requests.';

alter table public.baby_extension_requests enable row level security;
revoke all on table public.baby_extension_requests from public, anon, authenticated;
grant select on table public.baby_extension_requests to authenticated;
grant all on table public.baby_extension_requests to service_role;

create policy "members read their baby extension request"
  on public.baby_extension_requests for select to authenticated
  using (public.is_baby_member(baby_id) or public.is_super_admin());

create or replace function public.baby_extension_requests_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.requested_by is null
       or new.status <> 'pending'
       or new.decided_by is not null
       or new.decided_at is not null
       or new.decision_note is not null then
      raise exception 'extension request must start pending' using errcode = '42501';
    end if;
    return new;
  end if;

  -- Legal account deletion anonymises actor references without changing the
  -- request or its immutable decision.
  if new.baby_id is not distinct from old.baby_id
     and new.requested_days is not distinct from old.requested_days
     and new.status is not distinct from old.status
     and new.decided_at is not distinct from old.decided_at
     and new.decision_note is not distinct from old.decision_note
     and new.created_at is not distinct from old.created_at
     and new.updated_at is not distinct from old.updated_at
     and (new.requested_by is not distinct from old.requested_by or new.requested_by is null)
     and (new.decided_by is not distinct from old.decided_by or new.decided_by is null)
     and (new.requested_by is distinct from old.requested_by or new.decided_by is distinct from old.decided_by) then
    return new;
  end if;

  if current_setting('app.lifecycle_extension_write', true) is distinct from 'on' then
    raise exception 'extension decisions are RPC-only' using errcode = '42501';
  end if;
  if old.status <> 'pending' then
    raise exception 'extension decision is immutable' using errcode = '42501';
  end if;
  if new.baby_id is distinct from old.baby_id
     or new.requested_by is distinct from old.requested_by
     or new.requested_days is distinct from old.requested_days
     or new.created_at is distinct from old.created_at then
    raise exception 'extension request fields are immutable' using errcode = '42501';
  end if;
  if new.status not in ('approved', 'rejected', 'expired') then
    raise exception 'invalid extension transition' using errcode = '22023';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger baby_extension_requests_guard
  before insert or update on public.baby_extension_requests
  for each row execute function public.baby_extension_requests_guard();

create or replace function public.can_read_baby_lifecycle(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_baby_member(p_baby_id) or public.is_super_admin();
$$;

revoke all on function public.can_read_baby_lifecycle(uuid) from public, anon, authenticated;
grant execute on function public.can_read_baby_lifecycle(uuid) to service_role;

create or replace function public.business_date_istanbul()
returns date
language sql
stable
set search_path = ''
as $$
  select timezone('Europe/Istanbul', statement_timestamp())::date;
$$;

create or replace function public.baby_base_close_date(p_baby_id uuid)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_close date;
begin
  if not public.can_read_baby_lifecycle(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select b.birth_date + 375 into v_close from public.babies b where b.id = p_baby_id;
  if v_close is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  return v_close;
end;
$$;

create or replace function public.baby_approved_extension_days(p_baby_id uuid)
returns smallint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days smallint;
begin
  if not public.can_read_baby_lifecycle(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select coalesce(max(r.requested_days) filter (where r.status = 'approved'), 0)::smallint
    into v_days
    from public.baby_extension_requests r
   where r.baby_id = p_baby_id;
  return coalesce(v_days, 0);
end;
$$;

create or replace function public.baby_effective_close_date(p_baby_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select public.baby_base_close_date(p_baby_id)
         + public.baby_approved_extension_days(p_baby_id)::integer;
$$;

create or replace function public.baby_is_active(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.business_date_istanbul() < public.baby_effective_close_date(p_baby_id);
$$;

create or replace function public.baby_is_locked(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.baby_is_active(p_baby_id);
$$;

create or replace function public.baby_lifecycle_summary(p_baby_id uuid)
returns table (
  baby_id uuid,
  status text,
  business_date date,
  base_close_date date,
  effective_close_date date,
  remaining_days integer,
  extension_status text,
  approved_extension_days smallint,
  can_request_extension boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.business_date_istanbul();
  v_base date;
  v_extension_days smallint;
  v_effective date;
  v_extension_status text;
begin
  if not public.can_read_baby_lifecycle(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  v_base := public.baby_base_close_date(p_baby_id);
  v_extension_days := public.baby_approved_extension_days(p_baby_id);
  v_effective := v_base + v_extension_days::integer;
  select case
           when r.status = 'pending' and v_today >= v_base then 'expired'
           else r.status
         end
    into v_extension_status
    from public.baby_extension_requests r
   where r.baby_id = p_baby_id;

  return query
  select p_baby_id,
         case when v_today < v_effective then 'ACTIVE' else 'LOCKED' end,
         v_today,
         v_base,
         v_effective,
         greatest(v_effective - v_today, 0),
         v_extension_status,
         v_extension_days,
         v_today < v_base
           and not exists (
             select 1 from public.baby_extension_requests r where r.baby_id = p_baby_id
           );
end;
$$;

create or replace function public.assert_baby_active(p_baby_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.baby_is_active(p_baby_id) then
    raise exception 'baby lifecycle is locked' using errcode = '55000';
  end if;
end;
$$;

revoke all on function public.business_date_istanbul() from public, anon;
revoke all on function public.baby_base_close_date(uuid) from public, anon;
revoke all on function public.baby_approved_extension_days(uuid) from public, anon;
revoke all on function public.baby_effective_close_date(uuid) from public, anon;
revoke all on function public.baby_is_active(uuid) from public, anon;
revoke all on function public.baby_is_locked(uuid) from public, anon;
revoke all on function public.baby_lifecycle_summary(uuid) from public, anon;
revoke all on function public.assert_baby_active(uuid) from public, anon;

grant execute on function public.business_date_istanbul() to authenticated, service_role;
grant execute on function public.baby_base_close_date(uuid) to authenticated, service_role;
grant execute on function public.baby_approved_extension_days(uuid) to authenticated, service_role;
grant execute on function public.baby_effective_close_date(uuid) to authenticated, service_role;
grant execute on function public.baby_is_active(uuid) to authenticated, service_role;
grant execute on function public.baby_is_locked(uuid) to authenticated, service_role;
grant execute on function public.baby_lifecycle_summary(uuid) to authenticated, service_role;
grant execute on function public.assert_baby_active(uuid) to authenticated, service_role;

-- Lifecycle notifications are explicit types so they can be deduplicated and
-- routed independently from ordinary family activity.
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type in (
  'family_activity', 'member_joined', 'anniversary', 'birthday',
  'memories_of_the_day', 'book_ready', 'book_generated', 'time_capsule_opened',
  'extension_requested', 'extension_approved', 'extension_rejected',
  'extension_expired', 'profile_locked'
));

create unique index activity_logs_profile_locked_once_idx
  on public.activity_logs (baby_id, action)
  where action = 'profile_locked';

create or replace function public.request_baby_extension(p_baby_id uuid, p_days integer)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_birth_date date;
  v_request_id uuid;
  v_baby_name text;
begin
  if v_user is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_days is null or p_days < 1 or p_days > 30 then
    raise exception 'requested_days must be between 1 and 30' using errcode = '22023';
  end if;

  select b.birth_date, b.first_name
    into v_birth_date, v_baby_name
    from public.babies b
   where b.id = p_baby_id
   for update;
  if v_birth_date is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if public.business_date_istanbul() >= v_birth_date + 375 then
    raise exception 'extension can only be requested before base close' using errcode = '55000';
  end if;

  begin
    insert into public.baby_extension_requests (baby_id, requested_by, requested_days)
      values (p_baby_id, v_user, p_days)
      returning id into v_request_id;
  exception when unique_violation then
    raise exception 'extension already requested' using errcode = '23505';
  end;

  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (
      p_baby_id, v_user, 'extension_requested', 'baby_extension_request', v_request_id,
      jsonb_build_object('requested_days', p_days)
    );
  perform public.notify_family(
    p_baby_id, v_user, 'extension_requested',
    v_baby_name || ' için uzatma talebi oluşturuldu',
    p_days || ' günlük talep Super Admin değerlendirmesini bekliyor.',
    jsonb_build_object('request_id', v_request_id, 'requested_days', p_days),
    null,
    'extension_requested:' || v_request_id::text
  );
  return v_request_id;
end;
$$;

create or replace function public.decide_baby_extension(
  p_request_id uuid,
  p_decision text,
  p_note text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  r record;
  v_baby_name text;
  v_action text;
begin
  if not public.is_super_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'decision must be approved or rejected' using errcode = '22023';
  end if;
  if p_note is not null and char_length(p_note) > 2000 then
    raise exception 'decision note is too long' using errcode = '22023';
  end if;

  select er.*, b.birth_date, b.first_name
    into r
    from public.baby_extension_requests er
    join public.babies b on b.id = er.baby_id
   where er.id = p_request_id
   for update of er;
  if not found then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if r.status <> 'pending' then
    raise exception 'extension decision is immutable' using errcode = '55000';
  end if;

  perform set_config('app.lifecycle_extension_write', 'on', true);
  if public.business_date_istanbul() >= r.birth_date + 375 then
    update public.baby_extension_requests
       set status = 'expired', decided_by = null, decided_at = now(),
           decision_note = 'Base close date reached before decision.'
     where id = p_request_id;
    v_action := 'extension_expired';
  else
    update public.baby_extension_requests
       set status = p_decision, decided_by = v_user, decided_at = now(),
           decision_note = nullif(btrim(p_note), '')
     where id = p_request_id;
    v_action := 'extension_' || p_decision;
  end if;

  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (
      r.baby_id,
      case when v_action = 'extension_expired' then null else v_user end,
      v_action,
      'baby_extension_request',
      p_request_id,
      jsonb_build_object('requested_days', r.requested_days, 'note', p_note)
    );
  perform public.notify_family(
    r.baby_id,
    case when v_action = 'extension_expired' then null else v_user end,
    v_action,
    case v_action
      when 'extension_approved' then r.first_name || ' için uzatma onaylandı'
      when 'extension_rejected' then r.first_name || ' için uzatma reddedildi'
      else r.first_name || ' için uzatma talebinin süresi doldu'
    end,
    case v_action
      when 'extension_approved' then r.requested_days || ' günlük ek süre tanımlandı.'
      when 'extension_rejected' then 'Profil standart kapanış tarihinde kilitlenecek.'
      else 'Profil yeniden açılmadan kilitli kaldı.'
    end,
    jsonb_build_object('request_id', p_request_id, 'requested_days', r.requested_days),
    null,
    v_action || ':' || p_request_id::text
  );
  return replace(v_action, 'extension_', '');
end;
$$;

revoke all on function public.request_baby_extension(uuid, integer) from public, anon;
revoke all on function public.decide_baby_extension(uuid, text, text) from public, anon;
grant execute on function public.request_baby_extension(uuid, integer) to authenticated, service_role;
grant execute on function public.decide_baby_extension(uuid, text, text) to authenticated, service_role;

create or replace function public.run_baby_lifecycle_jobs(
  p_business_date date default public.business_date_istanbul()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_expired integer := 0;
  v_locked integer := 0;
begin
  if p_business_date is null then
    raise exception 'business date is required' using errcode = '22023';
  end if;
  perform set_config('app.lifecycle_extension_write', 'on', true);

  for r in
    update public.baby_extension_requests er
       set status = 'expired', decided_by = null, decided_at = now(),
           decision_note = 'Base close date reached before decision.'
      from public.babies b
     where b.id = er.baby_id
       and er.status = 'pending'
       and p_business_date >= b.birth_date + 375
    returning er.id, er.baby_id, er.requested_days,
              (select first_name from public.babies where id = er.baby_id) as first_name
  loop
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
      values (
        r.baby_id, null, 'extension_expired', 'baby_extension_request', r.id,
        jsonb_build_object('requested_days', r.requested_days)
      );
    perform public.notify_family(
      r.baby_id, null, 'extension_expired',
      r.first_name || ' için uzatma talebinin süresi doldu',
      'Profil yeniden açılmadan kilitli kaldı.',
      jsonb_build_object('request_id', r.id, 'requested_days', r.requested_days),
      null,
      'extension_expired:' || r.id::text
    );
    v_expired := v_expired + 1;
  end loop;

  for r in
    with due as (
      select b.id as baby_id,
             b.first_name,
             b.birth_date + 375
               + coalesce((
                   select er.requested_days::integer
                     from public.baby_extension_requests er
                    where er.baby_id = b.id and er.status = 'approved'
                 ), 0) as effective_close_date
        from public.babies b
    ), inserted as (
      insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
      select d.baby_id, null, 'profile_locked', 'baby', d.baby_id,
             jsonb_build_object('effective_close_date', d.effective_close_date)
        from due d
       where p_business_date >= d.effective_close_date
      on conflict (baby_id, action) where action = 'profile_locked' do nothing
      returning baby_id, details
    )
    select i.baby_id, d.first_name, (i.details ->> 'effective_close_date')::date as effective_close_date
      from inserted i
      join due d on d.baby_id = i.baby_id
  loop
    perform public.notify_family(
      r.baby_id, null, 'profile_locked',
      r.first_name || ' için ilk yıl arşivi kilitlendi',
      'Kaynak arşiv artık salt okunur.',
      jsonb_build_object('effective_close_date', r.effective_close_date),
      null,
      'profile_locked:' || r.baby_id::text || ':' || r.effective_close_date::text
    );
    v_locked := v_locked + 1;
  end loop;

  return jsonb_build_object('expired_requests', v_expired, 'locked_profiles', v_locked);
end;
$$;

revoke all on function public.run_baby_lifecycle_jobs(date) from public, anon, authenticated;
grant execute on function public.run_baby_lifecycle_jobs(date) to service_role;

-- Europe/Istanbul is permanently UTC+3; 21:00 UTC is local midnight.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.schedule(
        'bebegimin-lifecycle-jobs',
        '0 21 * * *',
        'select public.run_baby_lifecycle_jobs()'
      );
    exception when others then
      raise notice 'pg_cron lifecycle scheduling skipped: %', sqlerrm;
    end;
  else
    raise notice 'pg_cron is not available; schedule public.run_baby_lifecycle_jobs() manually.';
  end if;
end;
$$;

commit;
