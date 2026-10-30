-- =====================================================================
-- Phase 3: enforce the 375/405-day lifecycle on every write path of the
-- source archive (table writes, SECURITY DEFINER RPCs and Storage).
--
-- Rules
--   * A LOCKED baby's source archive (profile fields, memories, milestones,
--     custom milestone types, letters, media, comments, time capsules and
--     their Storage objects) is read-only for end users.
--   * Family membership, invitations, favorites, book/output tables and
--     privileged service paths (legal deletion, scheduled jobs) are NOT
--     part of this lock.
--   * birth_date is a lifecycle input: it only changes through the audited
--     correct_baby_birth_date() RPC.
--
-- "End-user context" = a request carrying a user identity (auth.uid()) or
-- running as the anon/authenticated API role. SECURITY DEFINER functions
-- keep both, so definer RPCs cannot bypass the guard. Trusted contexts
-- (service_role, pg_cron, GoTrue cascades) have neither.
-- =====================================================================
begin;

-- Kill switch -------------------------------------------------------------------
-- Rollback lever for an emergency: turning the lock off is a trusted,
-- audited operation instead of loosening policies in a hurry.
create table public.platform_flags (
  key        text primary key check (key ~ '^[a-z_]{3,60}$'),
  enabled    boolean not null,
  note       text check (note is null or char_length(note) <= 2000),
  updated_at timestamptz not null default now()
);

create table public.platform_flag_events (
  id         bigint generated always as identity primary key,
  key        text not null,
  old_value  boolean,
  new_value  boolean,
  note       text,
  changed_by text not null default current_user,
  changed_at timestamptz not null default now()
);

alter table public.platform_flags enable row level security;
alter table public.platform_flag_events enable row level security;
revoke all on table public.platform_flags, public.platform_flag_events from public, anon, authenticated;
grant all on table public.platform_flags, public.platform_flag_events to service_role;

create or replace function public.platform_flags_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  insert into public.platform_flag_events (key, old_value, new_value, note)
  values (new.key, case when tg_op = 'UPDATE' then old.enabled end, new.enabled, new.note);
  return new;
end;
$$;

create trigger platform_flags_audit
  before insert or update on public.platform_flags
  for each row execute function public.platform_flags_audit();

insert into public.platform_flags (key, enabled, note)
values ('lifecycle_write_lock', true, 'Phase 3: LOCKED source archives are read-only.');

create or replace function public.lifecycle_write_lock_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select f.enabled from public.platform_flags f where f.key = 'lifecycle_write_lock'), true);
$$;

-- Internal lifecycle helpers ------------------------------------------------------
-- Same formula as baby_is_active() (Phase 2) without the membership gate so
-- triggers, Storage policies and trusted jobs can evaluate any baby. Not
-- executable by API roles: it must not become a lifecycle oracle.
create or replace function public.baby_lifecycle_active_internal(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.business_date_istanbul()
         < b.birth_date + 375 + coalesce((
             select er.requested_days::integer
               from public.baby_extension_requests er
              where er.baby_id = b.id and er.status = 'approved'
           ), 0)
    from public.babies b
   where b.id = p_baby_id;
$$;

create or replace function public.lifecycle_enforced_context()
returns boolean
language sql
stable
set search_path = ''
as $$
  select auth.uid() is not null
      or coalesce(nullif(current_setting('role', true), ''), 'none') in ('authenticated', 'anon');
$$;

-- True when an end-user write to this baby's source archive is allowed by
-- the lifecycle. Unknown babies are treated as not writable.
create or replace function public.baby_source_writable(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.lifecycle_write_lock_enabled()
      or coalesce(public.baby_lifecycle_active_internal(p_baby_id), false);
$$;

create or replace function public.assert_baby_source_writable(p_baby_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.baby_source_writable(p_baby_id) then
    raise exception 'baby lifecycle is locked' using errcode = '55000', hint = 'lifecycle_locked';
  end if;
end;
$$;

revoke all on function public.lifecycle_write_lock_enabled(),
  public.baby_lifecycle_active_internal(uuid),
  public.lifecycle_enforced_context(),
  public.baby_source_writable(uuid),
  public.assert_baby_source_writable(uuid)
  from public, anon, authenticated;
grant execute on function public.lifecycle_write_lock_enabled(),
  public.baby_lifecycle_active_internal(uuid),
  public.lifecycle_enforced_context(),
  public.baby_source_writable(uuid),
  public.assert_baby_source_writable(uuid)
  to service_role;

-- Source content guard ------------------------------------------------------------
-- Runs for table writes and for writes made inside SECURITY DEFINER RPCs.
-- Non-members are left to RLS / the RPC's own checks so the error never
-- reveals whether a foreign baby exists or is locked.
create or replace function public.lifecycle_source_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_baby uuid;
  v_new_baby uuid;
begin
  if tg_op = 'DELETE' then
    v_baby := old.baby_id;
  elsif tg_op = 'UPDATE' then
    v_baby := old.baby_id;
    v_new_baby := new.baby_id;
  else
    v_baby := new.baby_id;
  end if;

  if public.lifecycle_enforced_context() then
    if v_baby is not null and public.is_baby_member(v_baby) then
      perform public.assert_baby_source_writable(v_baby);
    end if;
    if v_new_baby is distinct from v_baby and v_new_baby is not null
       and public.is_baby_member(v_new_baby) then
      perform public.assert_baby_source_writable(v_new_baby);
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.lifecycle_source_guard() from public, anon, authenticated;

-- Trigger names sort before the existing *_owner_guard / *_path_guard
-- triggers so the lifecycle decision is made first.
create trigger memories_lifecycle_guard before insert or update or delete on public.memories
  for each row execute function public.lifecycle_source_guard();
create trigger milestones_lifecycle_guard before insert or update or delete on public.milestones
  for each row execute function public.lifecycle_source_guard();
create trigger milestone_types_lifecycle_guard before insert or update or delete on public.milestone_types
  for each row execute function public.lifecycle_source_guard();
create trigger letters_lifecycle_guard before insert or update or delete on public.letters
  for each row execute function public.lifecycle_source_guard();
create trigger media_lifecycle_guard before insert or update or delete on public.media
  for each row execute function public.lifecycle_source_guard();
create trigger comments_lifecycle_guard before insert or update or delete on public.comments
  for each row execute function public.lifecycle_source_guard();
create trigger time_capsules_lifecycle_guard before insert or update or delete on public.time_capsules
  for each row execute function public.lifecycle_source_guard();
create trigger time_capsule_contents_lifecycle_guard before insert or update or delete on public.time_capsule_contents
  for each row execute function public.lifecycle_source_guard();

-- Baby profile guard -----------------------------------------------------------------
create or replace function public.babies_lifecycle_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.lifecycle_enforced_context() then
    return new;
  end if;
  if new.birth_date is distinct from old.birth_date
     and coalesce(current_setting('app.birth_date_correction', true), '') <> 'on' then
    raise exception 'birth_date can only be changed through correct_baby_birth_date()'
      using errcode = '42501', hint = 'birth_date_rpc_only';
  end if;
  if (new.first_name, new.last_name, new.birth_time, new.birth_place, new.birth_weight_grams,
      new.birth_length_cm, new.avatar_path, new.cover_path, new.story)
     is distinct from
     (old.first_name, old.last_name, old.birth_time, old.birth_place, old.birth_weight_grams,
      old.birth_length_cm, old.avatar_path, old.cover_path, old.story) then
    perform public.assert_baby_source_writable(old.id);
  end if;
  return new;
end;
$$;

revoke all on function public.babies_lifecycle_guard() from public, anon, authenticated;

create trigger babies_lifecycle_guard before update on public.babies
  for each row execute function public.babies_lifecycle_guard();

-- Birth date correction (master plan 3.5) --------------------------------------------
--   * Anne/Baba admins: only while ACTIVE and before any content exists.
--   * Super Admin: any time, with a mandatory reason; reopening a LOCKED
--     profile additionally needs p_confirm_reopen and is logged as a
--     security event.
--   * Never touches baby_extension_requests: no new extension right.
create or replace function public.correct_baby_birth_date(
  p_baby_id uuid,
  p_birth_date date,
  p_reason text default null,
  p_confirm_reopen boolean default false
)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_super boolean := public.is_super_admin();
  v_old date;
  v_was_active boolean;
  v_now_active boolean;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if not v_super and not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_birth_date is null then
    raise exception 'birth_date is required' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 2000 then
    raise exception 'reason is too long' using errcode = '22023';
  end if;

  select b.birth_date into v_old from public.babies b where b.id = p_baby_id for update;
  if v_old is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if v_old = p_birth_date then
    return v_old;
  end if;

  v_was_active := coalesce(public.baby_lifecycle_active_internal(p_baby_id), false);

  if v_super then
    if v_reason is null then
      raise exception 'a reason is required for an administrative correction'
        using errcode = '22023', hint = 'birth_date_reason_required';
    end if;
  else
    if not exists (
      select 1 from public.family_members fm
       where fm.baby_id = p_baby_id and fm.user_id = v_user
         and fm.is_admin and fm.relation in ('anne', 'baba')
    ) then
      raise exception 'not authorized' using errcode = '42501';
    end if;
    if not v_was_active then
      raise exception 'baby lifecycle is locked' using errcode = '55000', hint = 'lifecycle_locked';
    end if;
    if exists (select 1 from public.memories where baby_id = p_baby_id)
       or exists (select 1 from public.milestones where baby_id = p_baby_id)
       or exists (select 1 from public.letters where baby_id = p_baby_id)
       or exists (select 1 from public.media where baby_id = p_baby_id)
       or exists (select 1 from public.comments where baby_id = p_baby_id)
       or exists (select 1 from public.time_capsules where baby_id = p_baby_id)
       or exists (select 1 from public.milestone_types where baby_id = p_baby_id) then
      raise exception 'birth date can only be corrected by support once content exists'
        using errcode = '55000', hint = 'birth_date_requires_admin';
    end if;
  end if;

  perform set_config('app.birth_date_correction', 'on', true);
  update public.babies set birth_date = p_birth_date where id = p_baby_id;
  perform set_config('app.birth_date_correction', '', true);

  v_now_active := coalesce(public.baby_lifecycle_active_internal(p_baby_id), false);
  if not v_was_active and v_now_active then
    if not coalesce(p_confirm_reopen, false) then
      raise exception 'correction would reopen a locked profile'
        using errcode = '55000', hint = 'reopen_confirmation_required';
    end if;
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (p_baby_id, v_user, 'lifecycle_reopened', 'baby', p_baby_id,
            jsonb_build_object('reason', v_reason, 'birth_date_before', v_old,
                               'birth_date_after', p_birth_date, 'security_event', true));
  end if;

  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
  values (p_baby_id, v_user, 'birth_date_corrected', 'baby', p_baby_id,
          jsonb_build_object(
            'birth_date_before', v_old,
            'birth_date_after', p_birth_date,
            'reason', v_reason,
            'actor_role', case when v_super then 'super_admin' else 'parent' end,
            'was_active', v_was_active,
            'is_active', v_now_active));
  return p_birth_date;
end;
$$;

revoke all on function public.correct_baby_birth_date(uuid, date, text, boolean) from public, anon;
grant execute on function public.correct_baby_birth_date(uuid, date, text, boolean) to authenticated, service_role;

-- create_time_capsule: explicit lifecycle check (the row guard also fires) ----------------
create or replace function public.create_time_capsule(
  p_baby_id uuid,
  p_title text,
  p_body text,
  p_open_on date,
  p_occasion text default 'custom',
  p_has_photo boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if not public.has_baby_permission(p_baby_id, 'write_letter') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  perform public.assert_baby_source_writable(p_baby_id);
  if p_open_on <= current_date then
    raise exception 'open date must be in the future' using errcode = '22023', hint = 'open_date_not_future';
  end if;
  if p_open_on > current_date + interval '100 years' then
    raise exception 'open date is too far' using errcode = '22023';
  end if;

  insert into public.time_capsules (baby_id, author_id, author_name, author_relation, author_relation_label,
                                    title, occasion, open_on, has_photo)
  select p_baby_id, v_uid, coalesce(nullif(p.display_name, ''), 'Aile üyesi'), fm.relation, fm.relation_label,
         btrim(p_title), p_occasion, p_open_on, coalesce(p_has_photo, false)
  from public.family_members fm
  left join public.profiles p on p.id = fm.user_id
  where fm.baby_id = p_baby_id and fm.user_id = v_uid
  returning id into v_id;

  insert into public.time_capsule_contents (capsule_id, baby_id, body)
  values (v_id, p_baby_id, p_body);

  return v_id;
end;
$$;

-- Storage: no new, replaced or deleted source objects for a LOCKED baby -------------------
create or replace function public.can_write_baby_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby uuid := public.path_uuid(p_name, 1);
  v_second text := public.path_segment(p_name, 2);
  v_capsule uuid;
begin
  if v_baby is null or not public.baby_source_writable(v_baby) then
    return false;
  end if;
  if v_second = 'profile' then
    return array_length(string_to_array(p_name, '/'), 1) = 3
       and public.has_baby_permission(v_baby, 'manage_baby');
  end if;
  if v_second = 'capsules' then
    v_capsule := public.path_uuid(p_name, 3);
    return public.path_segment(p_name, 4) = 'photo.jpg'
       and array_length(string_to_array(p_name, '/'), 1) = 4
       and exists (
         select 1 from public.time_capsules c
         where c.id = v_capsule and c.baby_id = v_baby and c.author_id = auth.uid()
           and c.has_photo and c.open_on > current_date
           and c.created_at > now() - interval '1 day');
  end if;
  -- media: the DB row (created first, status 'uploading') authorises the upload
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and m.uploader_id = auth.uid()
      and m.status = 'uploading'
      and (m.storage_path = p_name or m.thumb_path = p_name)
      and public.is_baby_member(v_baby)
  );
end;
$$;

create or replace function public.can_delete_baby_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby uuid := public.path_uuid(p_name, 1);
  v_second text := public.path_segment(p_name, 2);
begin
  if v_baby is null or not public.baby_source_writable(v_baby) then
    return false;
  end if;
  if v_second = 'profile' then
    return public.has_baby_permission(v_baby, 'manage_baby');
  end if;
  if v_second = 'capsules' then
    return exists (
      select 1 from public.time_capsules c
      where c.id = public.path_uuid(p_name, 3) and c.baby_id = v_baby
        and (c.author_id = auth.uid() or public.is_baby_admin(v_baby)));
  end if;
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and (m.uploader_id = auth.uid() or public.has_baby_permission(v_baby, 'manage_content'))
  );
end;
$$;

-- Compensating cleanup for capsule photos: clients delete the row first
-- (authorisation + lifecycle are decided by the database), the file is
-- then removed by the storage-cleanup function.
create or replace function public.queue_capsule_photo_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.has_photo then
    insert into public.storage_cleanup_queue (bucket_id, path)
    values ('baby-media', old.baby_id::text || '/capsules/' || old.id::text || '/photo.jpg')
    on conflict do nothing;
  end if;
  return old;
end;
$$;

revoke all on function public.queue_capsule_photo_cleanup() from public, anon, authenticated;

create trigger time_capsules_queue_cleanup after delete on public.time_capsules
  for each row execute function public.queue_capsule_photo_cleanup();

-- Lifecycle job: also quarantine uploads left half-way when the lock hits ----------------
-- Quarantined rows become 'failed' (no finalize, no Storage write). The
-- existing daily job deletes stale failed rows, whose delete trigger queues
-- the files for the storage-cleanup function.
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
  v_quarantined integer := 0;
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

  with quarantined as (
    update public.media m
       set status = 'failed'
      from public.babies b
     where b.id = m.baby_id
       and m.status = 'uploading'
       and p_business_date >= b.birth_date + 375
             + coalesce((
                 select er.requested_days::integer
                   from public.baby_extension_requests er
                  where er.baby_id = b.id and er.status = 'approved'
               ), 0)
    returning m.id, m.baby_id, m.uploader_id
  ), logged as (
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    select q.baby_id, null, 'upload_quarantined', 'media', q.id,
           jsonb_build_object('reason', 'lifecycle_locked', 'uploader_id', q.uploader_id)
      from quarantined q
    returning 1
  )
  select count(*) into v_quarantined from logged;

  return jsonb_build_object(
    'expired_requests', v_expired,
    'locked_profiles', v_locked,
    'quarantined_uploads', v_quarantined
  );
end;
$$;

revoke all on function public.run_baby_lifecycle_jobs(date) from public, anon, authenticated;
grant execute on function public.run_baby_lifecycle_jobs(date) to service_role;

commit;
