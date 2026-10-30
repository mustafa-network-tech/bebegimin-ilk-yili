-- Rollback of 20261030000200_access_trials_and_full_lock.sql.
-- Restores the previous function bodies (read-only archive of decision P-2, invitations
-- exempt, no trial). The trial tables are dropped with their (manual, short-lived) data.
-- No subscription, family, baby or memory row is touched.
begin;

drop function if exists public.admin_user_trials(uuid);
drop function if exists public.admin_revoke_trial(uuid, text);
drop function if exists public.admin_grant_trial(uuid, text, boolean);

drop function public.baby_access_state(uuid);
create function public.baby_access_state(p_baby_id uuid)
returns table (
  allowed boolean,
  reason text,
  is_parent boolean,
  family_account_id uuid,
  subscription_status text,
  plan_code text,
  plan_required boolean
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
  v_reason text;
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

  v_reason := case
    when v_account is not null and public.family_account_has_test_access(v_account) then 'test_access'
    when not public.subscription_enforcement_enabled() then 'enforcement_off'
    when v_account is null then 'account_unmapped'
    when v_sub.status is null then 'no_subscription'
    when public.subscription_grants_access(v_sub.status, v_sub.current_period_end) then 'ok'
    when v_sub.status = 'past_due' then 'payment_issue'
    else 'subscription_ended'
  end;

  return query select
    public.baby_subscription_ok(p_baby_id),
    v_reason,
    v_parent,
    v_account,
    v_sub.status::text,
    v_sub.plan_code::text,
    v_reason = 'no_subscription'
      and not coalesce((select a.plan_exempt from public.family_accounts a where a.id = v_account), true);
end;
$$;
revoke all on function public.baby_access_state(uuid) from public, anon;
grant execute on function public.baby_access_state(uuid) to authenticated, service_role;

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

create or replace function public.can_read_baby_object(p_name text)
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
  if v_baby is null or not public.is_baby_member(v_baby) then
    return false;
  end if;
  if v_second = 'profile' then
    return array_length(string_to_array(p_name, '/'), 1) = 3;
  end if;
  if v_second = 'capsules' then
    v_capsule := public.path_uuid(p_name, 3);
    return public.has_baby_permission(v_baby, 'view_memories') and exists (
      select 1 from public.time_capsules c
      where c.id = v_capsule and c.baby_id = v_baby and c.open_on <= current_date);
  end if;
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and (m.storage_path = p_name or m.thumb_path = p_name)
      and ((m.status = 'ready' and public.has_baby_permission(v_baby, 'view_album'))
           or m.uploader_id = auth.uid())
  );
end;
$$;

drop policy "album viewers can read ready media, uploaders their own" on public.media;
create policy "album viewers can read ready media, uploaders their own"
  on public.media for select to authenticated
  using (
    (status = 'ready' and public.has_baby_permission(baby_id, 'view_album'))
    or (uploader_id = auth.uid() and public.is_baby_member(baby_id))
  );

create or replace function public.has_baby_permission(p_baby_id uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_members fm
    where fm.baby_id = p_baby_id
      and fm.user_id = auth.uid()
      and (fm.is_admin or p_permission = any (fm.permissions))
  )
  and (p_permission in ('manage_members', 'invite_members', 'view_memories', 'view_album')
       or public.baby_subscription_ok(p_baby_id));
$$;

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

drop function if exists public.family_account_access_ok(uuid);
drop function if exists public.trial_family_member_capacity();
drop function if exists public.family_account_has_trial(uuid);
drop function if exists public.family_account_trial_end(uuid);
drop function if exists public.user_has_trial(uuid);

drop table if exists public.trial_events;
drop table if exists public.access_trials;
drop function if exists public.trial_events_immutable();
drop function if exists public.access_trials_guard();

commit;
