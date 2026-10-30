-- =====================================================================
-- Manual 72-hour trial + full lock without an entitlement.
--
--   * access_trials / trial_events : admin-granted, 72 h, UUID-based, audited. NOT a
--       subscription, NOT a store purchase, never revenue. Start / end are taken on the
--       server; expiry needs no job (the predicate compares ends_at with now()).
--   * Predicates: user_has_trial, family_account_trial_end, family_account_has_trial,
--       family_account_access_ok. A trial is effective for every family in which the
--       user is an active parent (same model as unlimited test access).
--   * baby_subscription_ok now also accepts a live trial (single content-write gate,
--       already used by RLS, triggers and Storage).
--   * FULL LOCK (reverses decision P-2 "read-only archive"): without a live
--       subscription, trial or test access the family can neither write NOR read its
--       archive. Profile pictures stay readable so the plan page can show the baby.
--       Only member removal (manage_members) stays available. Nothing is deleted.
--   * Invitations need an entitlement (invite_members no longer exempt). A trial family
--       invites up to the smallest current plan's family-member capacity.
--   * create_baby: the first baby of a new family is always allowed; another baby needs
--       an entitlement.
--   * baby_access_state: reason 'trial', trial_ends_at; plan_required now also covers an
--       ended / past-due subscription (the app sends the parent to the plan page).
--       plan_exempt is no longer consulted (column kept).
--
-- Nothing here turns `subscription_enforcement` on: until an operator enables that flag
-- every family keeps full access, exactly as today.
-- Rollback: supabase/rollbacks/20261030000200_access_trials_and_full_lock.down.sql
-- =====================================================================
begin;

-- 1. Trials ---------------------------------------------------------------------------------------
create table public.access_trials (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  starts_at     timestamptz not null default now(),
  ends_at       timestamptz not null,
  granted_by    uuid references auth.users (id) on delete set null,
  grant_reason  text not null check (char_length(btrim(grant_reason)) between 3 and 500),
  repeat_grant  boolean not null default false,
  revoked_at    timestamptz,
  revoked_by    uuid references auth.users (id) on delete set null,
  revoke_reason text check (revoke_reason is null or char_length(btrim(revoke_reason)) between 3 and 500),
  check (ends_at = starts_at + interval '72 hours'),
  check ((revoked_at is null and revoke_reason is null) or (revoked_at is not null and revoke_reason is not null))
);

create index access_trials_user_idx on public.access_trials (user_id, starts_at desc);

create table public.trial_events (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users (id) on delete cascade,
  trial_id  uuid,
  action    text not null check (action in ('granted', 'revoked')),
  actor_id  uuid references auth.users (id) on delete set null,
  reason    text not null check (char_length(btrim(reason)) between 3 and 500),
  created_at timestamptz not null default now()
);

create index trial_events_user_idx on public.trial_events (user_id, created_at desc, id desc);

-- A trial row only ever changes by being revoked, once.
create or replace function public.access_trials_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.revoked_at is not null
     or (new.id, new.user_id, new.starts_at, new.ends_at, new.granted_by, new.grant_reason, new.repeat_grant)
        is distinct from
        (old.id, old.user_id, old.starts_at, old.ends_at, old.granted_by, old.grant_reason, old.repeat_grant) then
    raise exception 'trials can only be revoked' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger access_trials_guard
  before update on public.access_trials
  for each row execute function public.access_trials_guard();

create or replace function public.trial_events_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'trial audit events are append-only' using errcode = '42501';
end;
$$;

create trigger trial_events_immutable
  before update on public.trial_events
  for each row execute function public.trial_events_immutable();

alter table public.access_trials enable row level security;
alter table public.trial_events enable row level security;
revoke all on table public.access_trials, public.trial_events from public, anon, authenticated;
grant all on table public.access_trials, public.trial_events to service_role;

-- 2. Predicates ------------------------------------------------------------------------------------
create or replace function public.user_has_trial(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null and exists (
    select 1 from public.access_trials t
     where t.user_id = p_user and t.revoked_at is null and t.starts_at <= now() and t.ends_at > now());
$$;

create or replace function public.family_account_trial_end(p_account uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select max(t.ends_at)
    from public.access_trials t
    join public.family_account_members m on m.user_id = t.user_id
   where m.family_account_id = p_account and m.role = 'parent' and m.status = 'active'
     and t.revoked_at is null and t.starts_at <= now() and t.ends_at > now();
$$;

create or replace function public.family_account_has_trial(p_account uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_account is not null and public.family_account_trial_end(p_account) is not null;
$$;

-- Family-member capacity of a trial = the smallest current plan (never hard-coded).
create or replace function public.trial_family_member_capacity()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select min(p.max_family_members)::integer from public.current_subscription_plans() p;
$$;

-- Account level twin of baby_subscription_ok().
create or replace function public.family_account_access_ok(p_account uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.subscription_enforcement_enabled()
      or public.family_account_has_test_access(p_account)
      or public.family_account_has_trial(p_account)
      or exists (
        select 1 from public.subscriptions s
         where s.family_account_id = p_account
           and public.subscription_grants_access(s.status, s.current_period_end));
$$;

create or replace function public.baby_subscription_ok(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.subscription_enforcement_enabled()
      or exists (
        select 1 from public.family_account_babies fab
         where fab.baby_id = p_baby_id
           and public.family_account_access_ok(fab.family_account_id));
$$;

revoke all on function public.user_has_trial(uuid), public.family_account_trial_end(uuid),
  public.family_account_has_trial(uuid), public.trial_family_member_capacity(),
  public.family_account_access_ok(uuid), public.access_trials_guard(), public.trial_events_immutable()
  from public, anon, authenticated;
grant execute on function public.user_has_trial(uuid), public.family_account_trial_end(uuid),
  public.family_account_has_trial(uuid), public.trial_family_member_capacity(),
  public.family_account_access_ok(uuid)
  to service_role;

-- 3. Full lock: reads need the entitlement too (reverses the read exemption of P-2) ---------------------
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
  -- Only member removal stays open without an entitlement (invitations no longer are).
  and (p_permission = 'manage_members' or public.baby_subscription_ok(p_baby_id));
$$;

drop policy "album viewers can read ready media, uploaders their own" on public.media;
create policy "album viewers can read ready media, uploaders their own"
  on public.media for select to authenticated
  using (
    (status = 'ready' and public.has_baby_permission(baby_id, 'view_album'))
    or (uploader_id = auth.uid() and public.baby_member_with_access(baby_id))
  );

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
  -- Profile pictures stay readable so the plan page can show the baby.
  if v_second = 'profile' then
    return array_length(string_to_array(p_name, '/'), 1) = 3;
  end if;
  if not public.baby_subscription_ok(v_baby) then
    return false;
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

-- 4. Joining: a trial family takes family members up to the smallest plan's capacity ----------------------
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
    elsif public.family_account_has_trial(p_account) then
      if public.family_account_active_member_count(p_account) >= public.trial_family_member_capacity() then
        raise exception 'family plan capacity is full' using errcode = 'P0001', hint = 'family_capacity_full';
      end if;
    elsif public.subscription_enforcement_enabled() then
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

-- 5. create_baby: the first baby of a family is free, another one needs an entitlement ----------------------
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

  if exists (select 1 from public.family_account_babies fab where fab.family_account_id = v_account)
     and not public.family_account_access_ok(v_account) then
    raise exception 'an active family plan is required to add another baby'
      using errcode = 'P0001', hint = 'subscription_required';
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

-- 6. What the app sees ------------------------------------------------------------------------------------------
drop function public.baby_access_state(uuid);

create function public.baby_access_state(p_baby_id uuid)
returns table (
  allowed boolean,
  reason text,
  is_parent boolean,
  family_account_id uuid,
  subscription_status text,
  plan_code text,
  plan_required boolean,
  trial_ends_at timestamptz
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
  v_trial_end timestamptz;
  v_reason text;
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  v_parent := v_account is not null and public.family_account_is_parent(v_account);
  v_trial_end := public.family_account_trial_end(v_account);
  select s.status, s.plan_code, s.current_period_end into v_sub
    from public.subscriptions s
   where s.family_account_id = v_account
   order by public.subscription_grants_access(s.status, s.current_period_end) desc, s.updated_at desc
   limit 1;

  v_reason := case
    when v_account is not null and public.family_account_has_test_access(v_account) then 'test_access'
    when not public.subscription_enforcement_enabled() then 'enforcement_off'
    when v_account is null then 'account_unmapped'
    when v_sub.status is not null and public.subscription_grants_access(v_sub.status, v_sub.current_period_end) then 'ok'
    when v_trial_end is not null then 'trial'
    when v_sub.status is null then 'no_subscription'
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
    v_reason in ('no_subscription', 'subscription_ended', 'payment_issue'),
    case when v_reason = 'trial' then v_trial_end end;
end;
$$;

revoke all on function public.baby_access_state(uuid) from public, anon;
grant execute on function public.baby_access_state(uuid) to authenticated, service_role;

-- 7. Admin: grant / revoke / read trials -----------------------------------------------------------------------
create or replace function public.admin_grant_trial(
  p_user_id uuid,
  p_reason text,
  p_allow_repeat boolean default false
)
returns table (trial_id uuid, starts_at timestamptz, ends_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := nullif(btrim(p_reason), '');
  v_start timestamptz := now();
  v_prior boolean;
  v_id uuid;
begin
  perform public.assert_admin_console('write', 30);
  if p_user_id is null then
    raise exception 'user is required' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) not between 3 and 500 then
    raise exception 'reason must be between 3 and 500 characters' using errcode = '22023';
  end if;
  -- Serialises concurrent grants for the same user.
  perform 1 from auth.users u where u.id = p_user_id for update;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  if public.user_has_test_access(p_user_id) then
    raise exception 'user already has unlimited test access' using errcode = 'P0001', hint = 'test_access_included';
  end if;
  if public.user_has_trial(p_user_id) then
    raise exception 'user already has a running trial' using errcode = 'P0001', hint = 'trial_already_active';
  end if;
  if exists (
    select 1 from public.subscriptions s
     where s.family_account_id in (select public.user_events_parent_accounts(p_user_id))
       and public.subscription_grants_access(s.status, s.current_period_end)
  ) then
    raise exception 'the family already has an active subscription' using errcode = 'P0001', hint = 'subscription_active';
  end if;
  v_prior := exists (select 1 from public.access_trials t where t.user_id = p_user_id);
  if v_prior and not coalesce(p_allow_repeat, false) then
    raise exception 'this user already used a trial' using errcode = 'P0001', hint = 'trial_already_used';
  end if;

  insert into public.access_trials (user_id, starts_at, ends_at, granted_by, grant_reason, repeat_grant)
  values (p_user_id, v_start, v_start + interval '72 hours', v_actor, v_reason, v_prior)
  returning id into v_id;
  insert into public.trial_events (user_id, trial_id, action, actor_id, reason)
  values (p_user_id, v_id, 'granted', v_actor, v_reason);

  return query select v_id, v_start, v_start + interval '72 hours';
end;
$$;

create or replace function public.admin_revoke_trial(p_user_id uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := nullif(btrim(p_reason), '');
  v_id uuid;
begin
  perform public.assert_admin_console('write', 30);
  if p_user_id is null then
    raise exception 'user is required' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) not between 3 and 500 then
    raise exception 'reason must be between 3 and 500 characters' using errcode = '22023';
  end if;
  perform 1 from auth.users u where u.id = p_user_id for update;
  if not found then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  update public.access_trials t
     set revoked_at = now(), revoked_by = v_actor, revoke_reason = v_reason
   where t.user_id = p_user_id and t.revoked_at is null and t.starts_at <= now() and t.ends_at > now()
  returning t.id into v_id;
  if v_id is null then
    return 'unchanged';
  end if;
  insert into public.trial_events (user_id, trial_id, action, actor_id, reason)
  values (p_user_id, v_id, 'revoked', v_actor, v_reason);
  return 'revoked';
end;
$$;

create or replace function public.admin_user_trials(p_user_id uuid)
returns table (
  trial_id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  status text,
  granted_by_name text,
  grant_reason text,
  repeat_grant boolean,
  revoked_at timestamptz,
  revoked_by_name text,
  revoke_reason text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('read', 120);
  return query
  select t.id, t.starts_at, t.ends_at,
         case when t.revoked_at is not null then 'revoked'
              when t.ends_at <= now() then 'expired'
              else 'live' end,
         coalesce(nullif(gp.display_name, ''), gu.email::text, 'Yönetici'),
         t.grant_reason, t.repeat_grant, t.revoked_at,
         coalesce(nullif(rp.display_name, ''), ru.email::text),
         t.revoke_reason
    from public.access_trials t
    left join auth.users gu on gu.id = t.granted_by
    left join public.profiles gp on gp.id = t.granted_by
    left join auth.users ru on ru.id = t.revoked_by
    left join public.profiles rp on rp.id = t.revoked_by
   where t.user_id = p_user_id
   order by t.starts_at desc;
end;
$$;

revoke all on function public.admin_grant_trial(uuid, text, boolean),
  public.admin_revoke_trial(uuid, text),
  public.admin_user_trials(uuid)
  from public, anon;
grant execute on function public.admin_grant_trial(uuid, text, boolean),
  public.admin_revoke_trial(uuid, text),
  public.admin_user_trials(uuid)
  to authenticated, service_role;

commit;
