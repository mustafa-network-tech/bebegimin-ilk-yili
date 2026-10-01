-- =====================================================================
-- Phase 12: parent-controlled Family Member downloads and one re-download
-- policy for Book / Film / HTML.
--
--   * artifact_download_permissions: per family account + baby + product +
--     member. Only an active parent grants / revokes; revocations are kept
--     (audit). Leaving the baby or the family account revokes automatically,
--     so a returning member never silently regains access.
--   * output_artifact_download_block (every download, every product):
--       parent:        baby member + active parent, LOCKED, live
--                      subscription, active entitlement, ready artifact.
--       Family Member: active member + LOCKED + live subscription within the
--                      plan capacity + parent grant for this baby / product +
--                      active entitlement + ready artifact.
--     view_album no longer decides downloads.
--   * authorize_artifact_download: the endpoint used by output-download.
--     Never raises for a policy refusal; grants and refusals are audited,
--     grants are rate limited (10 per artifact and 30 per user per 10 min).
--   * Members see only artifacts they may download (film / html state are
--     masked; book_versions already filters).
-- Kill switch: platform flag member_downloads (parents are not affected).
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('member_downloads', true, 'Phase 12: Family Members may download parent-shared final artifacts (off = parents only).')
on conflict (key) do nothing;

create table public.artifact_download_permissions (
  id                uuid primary key default gen_random_uuid(),
  family_account_id uuid not null references public.family_accounts (id) on delete cascade,
  baby_id           uuid not null references public.babies (id) on delete cascade,
  product_code      text not null check (product_code in ('first_year_book', 'first_year_html', 'first_year_film')),
  member_user_id    uuid not null references auth.users (id) on delete cascade,
  granted_by        uuid references auth.users (id) on delete set null,
  granted_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  revoked_by        uuid references auth.users (id) on delete set null,
  revoke_reason     text check (revoke_reason in ('parent_revoked', 'membership_ended')),
  check ((revoked_at is null) = (revoke_reason is null))
);

create unique index artifact_download_permissions_active_idx
  on public.artifact_download_permissions (family_account_id, baby_id, product_code, member_user_id)
  where revoked_at is null;

-- Grants are audit records: only the one-time revocation may change.
create or replace function public.artifact_download_permissions_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Identity never changes; a revocation is final. The only other change
  -- allowed is ON DELETE SET NULL of granted_by / revoked_by (user deletion).
  if (new.id, new.family_account_id, new.baby_id, new.product_code, new.member_user_id, new.granted_at)
       is distinct from (old.id, old.family_account_id, old.baby_id, old.product_code, old.member_user_id, old.granted_at)
     or (old.revoked_at is not null
         and (new.revoked_at, new.revoke_reason) is distinct from (old.revoked_at, old.revoke_reason))
     or (new.granted_by is distinct from old.granted_by and new.granted_by is not null)
     or (old.revoked_at is not null and new.revoked_by is distinct from old.revoked_by and new.revoked_by is not null) then
    raise exception 'download permissions are append-only' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger artifact_download_permissions_guard
  before update on public.artifact_download_permissions
  for each row execute function public.artifact_download_permissions_guard();

alter table public.artifact_download_permissions enable row level security;
revoke all on table public.artifact_download_permissions from public, anon, authenticated;
grant all on table public.artifact_download_permissions to service_role;

-- Leaving a baby or the family account ends the member's grants.
create or replace function public.artifact_permissions_revoke_on_leave()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'family_members' then
    update public.artifact_download_permissions
       set revoked_at = now(), revoke_reason = 'membership_ended'
     where baby_id = old.baby_id and member_user_id = old.user_id and revoked_at is null;
    return old;
  end if;
  if (new.status <> 'active' and old.status = 'active') or new.role <> old.role then
    update public.artifact_download_permissions
       set revoked_at = now(), revoke_reason = 'membership_ended'
     where family_account_id = new.family_account_id and member_user_id = new.user_id and revoked_at is null;
  end if;
  return new;
end;
$$;

create trigger family_members_revoke_downloads
  after delete on public.family_members
  for each row execute function public.artifact_permissions_revoke_on_leave();
create trigger family_account_members_revoke_downloads
  after update of status, role on public.family_account_members
  for each row execute function public.artifact_permissions_revoke_on_leave();

-- Audit ---------------------------------------------------------------------------------------------
alter table public.output_artifact_downloads
  add column role text check (role in ('parent', 'family_member')),
  add column product_code text;
create index output_artifact_downloads_user_idx on public.output_artifact_downloads (user_id, requested_at desc);

create table public.output_download_denials (
  id           bigint generated always as identity primary key,
  artifact_id  uuid, -- no FK: refused ids may not exist
  user_id      uuid,
  reason       text not null,
  requested_at timestamptz not null default now()
);
create index output_download_denials_time_idx on public.output_download_denials (requested_at desc);

create trigger output_download_denials_append_only
  before update or delete on public.output_download_denials
  for each row execute function public.output_append_only();

alter table public.output_download_denials enable row level security;
revoke all on table public.output_download_denials from public, anon, authenticated;
grant all on table public.output_download_denials to service_role;

-- The six-condition check (every product, every request) -----------------------------------------------
create or replace function public.output_artifact_download_block(p_artifact_id uuid, p_user uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
  v_parent boolean;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id;
  if v_art.id is null or p_user is null then
    return 'not_found';
  end if;
  -- 1. Membership of this baby in this family account.
  if not exists (select 1 from public.family_members fm where fm.baby_id = v_art.baby_id and fm.user_id = p_user)
     or not exists (select 1 from public.family_account_babies fab
                     where fab.baby_id = v_art.baby_id and fab.family_account_id = v_art.family_account_id) then
    return 'not_found';
  end if;
  if not public.family_account_is_member(v_art.family_account_id, p_user) then
    return 'membership_inactive';
  end if;
  v_parent := public.family_account_is_parent(v_art.family_account_id, p_user);
  -- 2. LOCKED archive.
  if coalesce(public.baby_lifecycle_active_internal(v_art.baby_id), true) then
    return 'premium_requires_locked';
  end if;
  -- 3. Live family subscription (no separate member subscription).
  if not exists (select 1 from public.subscriptions s
                  where s.family_account_id = v_art.family_account_id
                    and public.subscription_grants_access(s.status, s.current_period_end)) then
    return 'subscription_required';
  end if;
  -- 4. Active entitlement for this baby + product.
  if not exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_art.family_account_id and e.baby_id = v_art.baby_id
                    and e.product_code = v_art.product_code and e.status = 'active') then
    return 'entitlement_required';
  end if;
  if not v_parent then
    if not coalesce((select f.enabled from public.platform_flags f where f.key = 'member_downloads'), true) then
      return 'member_downloads_disabled';
    end if;
    -- 5. Within the plan capacity.
    if not exists (select 1 from public.subscriptions s
                     join public.subscription_plans p on p.id = s.plan_id
                    where s.family_account_id = v_art.family_account_id
                      and public.subscription_grants_access(s.status, s.current_period_end)
                      and public.family_account_active_member_count(v_art.family_account_id) <= p.max_family_members) then
      return 'capacity_exceeded';
    end if;
    -- 6. A parent shared this product of this baby with the member.
    if not exists (select 1 from public.artifact_download_permissions g
                    where g.family_account_id = v_art.family_account_id and g.baby_id = v_art.baby_id
                      and g.product_code = v_art.product_code and g.member_user_id = p_user
                      and g.revoked_at is null) then
      return 'permission_denied';
    end if;
  end if;
  if v_art.status <> 'ready' then
    return 'artifact_not_ready';
  end if;
  return null;
end;
$$;

-- Download endpoint: audited, rate limited, never raises for refusals.
create or replace function public.authorize_artifact_download(p_artifact_id uuid)
returns table (allowed boolean, reason text, bucket_id text, storage_path text, file_name text, mime_type text,
               size_bytes bigint, sha256 text, expires_in integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_block text := public.output_artifact_download_block(p_artifact_id, auth.uid());
  v_art public.output_artifacts;
begin
  if v_block is null and (
       (select count(*) from public.output_artifact_downloads d
         where d.user_id = v_uid and d.artifact_id = p_artifact_id and d.requested_at > now() - interval '10 minutes') >= 10
    or (select count(*) from public.output_artifact_downloads d
         where d.user_id = v_uid and d.requested_at > now() - interval '10 minutes') >= 30) then
    v_block := 'rate_limited';
  end if;
  if v_block is not null then
    insert into public.output_download_denials (artifact_id, user_id, reason) values (p_artifact_id, v_uid, v_block);
    return query select false, v_block, null::text, null::text, null::text, null::text, null::bigint, null::text, null::integer;
    return;
  end if;
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id;
  insert into public.output_artifact_downloads (artifact_id, user_id, role, product_code)
  values (p_artifact_id, v_uid,
          case when public.family_account_is_parent(v_art.family_account_id, v_uid) then 'parent' else 'family_member' end,
          v_art.product_code);
  return query select true, null::text, v_art.bucket_id, v_art.storage_path, v_art.file_name, v_art.mime_type,
                      v_art.size_bytes, v_art.sha256, 60;
end;
$$;

-- Phase 8 RPC kept for compatibility: same checks, refusals raise.
create or replace function public.request_output_download(p_artifact_id uuid)
returns table (bucket_id text, storage_path text, file_name text, mime_type text, size_bytes bigint, sha256 text,
               expires_in integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_row record;
begin
  select * into v_row from public.authorize_artifact_download(p_artifact_id);
  if not v_row.allowed then
    if v_row.reason = 'not_found' then
      raise exception 'resource not found' using errcode = 'P0002';
    elsif v_row.reason = 'permission_denied' then
      raise exception 'download not allowed' using errcode = '42501', hint = v_row.reason;
    end if;
    raise exception 'download not available' using errcode = '55000', hint = v_row.reason;
  end if;
  return query select v_row.bucket_id, v_row.storage_path, v_row.file_name, v_row.mime_type, v_row.size_bytes,
                      v_row.sha256, v_row.expires_in;
end;
$$;

-- Parent controls -----------------------------------------------------------------------------------------
create or replace function public.set_artifact_download_permission(
  p_baby_id uuid,
  p_member_user_id uuid,
  p_product_code text,
  p_allowed boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_account uuid;
begin
  if v_uid is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  v_account := public.family_account_id_for_baby(p_baby_id);
  if v_account is null or not public.family_account_is_parent(v_account, v_uid) then
    raise exception 'only parents can share downloads' using errcode = '42501', hint = 'not_parent';
  end if;
  if public.output_product_mime(p_product_code) is null or p_allowed is null then
    raise exception 'invalid download permission' using errcode = '22023';
  end if;
  if not exists (select 1 from public.family_account_members m
                  where m.family_account_id = v_account and m.user_id = p_member_user_id
                    and m.role = 'family_member' and m.status = 'active')
     or not exists (select 1 from public.family_members fm where fm.baby_id = p_baby_id and fm.user_id = p_member_user_id) then
    raise exception 'family member not found' using errcode = 'P0002', hint = 'member_not_found';
  end if;

  if p_allowed then
    insert into public.artifact_download_permissions (family_account_id, baby_id, product_code, member_user_id, granted_by)
    values (v_account, p_baby_id, p_product_code, p_member_user_id, v_uid)
    on conflict (family_account_id, baby_id, product_code, member_user_id) where revoked_at is null do nothing;
  else
    update public.artifact_download_permissions
       set revoked_at = now(), revoked_by = v_uid, revoke_reason = 'parent_revoked'
     where family_account_id = v_account and baby_id = p_baby_id and product_code = p_product_code
       and member_user_id = p_member_user_id and revoked_at is null;
  end if;
  return p_allowed;
end;
$$;

-- Family Members of the baby × products, with the current grant (parents).
create or replace function public.artifact_download_permission_list(p_baby_id uuid)
returns table (member_user_id uuid, display_name text, relation text, relation_label text, product_code text,
               granted boolean, granted_at timestamptz, product_owned boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_account uuid;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  v_account := public.family_account_id_for_baby(p_baby_id);
  if v_account is null or not public.family_account_is_parent(v_account, auth.uid()) then
    raise exception 'only parents can share downloads' using errcode = '42501', hint = 'not_parent';
  end if;
  return query
  select m.user_id, coalesce(nullif(btrim(pr.display_name), ''), ''), fm.relation, fm.relation_label, pc.code,
         g.id is not null, g.granted_at,
         exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_account and e.baby_id = p_baby_id
                    and e.product_code = pc.code and e.status = 'active')
    from public.family_account_members m
    join public.family_members fm on fm.baby_id = p_baby_id and fm.user_id = m.user_id
    left join public.profiles pr on pr.id = m.user_id
    cross join (values ('first_year_book'), ('first_year_film'), ('first_year_html')) pc(code)
    left join public.artifact_download_permissions g
           on g.family_account_id = v_account and g.baby_id = p_baby_id and g.product_code = pc.code
          and g.member_user_id = m.user_id and g.revoked_at is null
   where m.family_account_id = v_account and m.role = 'family_member' and m.status = 'active'
   order by fm.joined_at, m.user_id, pc.code;
end;
$$;

-- Members see only what they may download -------------------------------------------------------------------
create or replace function public.film_state(p_baby_id uuid)
returns table (job_id uuid, job_status text, attempts integer, last_error_code text, failed_media_id uuid,
               progress_percent integer, progress_stage text, job_created_at timestamptz, job_updated_at timestamptz,
               planned_duration_ms integer, artifact_id uuid, artifact_size_bytes bigint, artifact_sha256 text,
               duration_ms integer, width integer, height integer, ready_at timestamptz, artifact_snapshot_id uuid,
               download_block text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_parent boolean;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return;
  end if;
  v_parent := public.family_account_is_parent(public.family_account_id_for_baby(p_baby_id), auth.uid());
  return query
  select case when v_parent then j.id end, case when v_parent then j.status end,
         case when v_parent then j.attempts::integer end, case when v_parent then j.last_error_code end,
         case when v_parent then pr.failed_media_id end, case when v_parent then pr.percent::integer end,
         case when v_parent then pr.stage end, case when v_parent then j.created_at end,
         case when v_parent then j.updated_at end, case when v_parent then fm.total_duration_ms end,
         a.id, a.size_bytes, a.sha256, md.duration_ms, md.width, md.height, a.ready_at, a.snapshot_id, a.block
    from public.output_projects p
    left join lateral (select * from public.output_jobs j2 where j2.project_id = p.id
                        order by j2.created_at desc limit 1) j on true
    left join public.film_job_progress pr on pr.job_id = j.id
    left join public.film_render_manifests fm on fm.job_id = j.id
    left join lateral (
      select a2.*, public.output_artifact_download_block(a2.id, auth.uid()) as block
        from public.output_artifacts a2
       where a2.project_id = p.id and a2.status = 'ready'
       order by a2.ready_at desc limit 1) a0 on true
    left join lateral (select a0.* where v_parent or a0.block is null
                          or a0.block not in ('not_found', 'membership_inactive', 'permission_denied')) a on true
    left join public.film_artifact_metadata md on md.artifact_id = a.id
   where p.baby_id = p_baby_id and p.product_code = 'first_year_film'
     and p.family_account_id = public.family_account_id_for_baby(p_baby_id);
end;
$$;

create or replace function public.html_state(p_baby_id uuid)
returns table (job_id uuid, job_status text, attempts integer, last_error_code text, progress_percent integer,
               progress_stage text, job_updated_at timestamptz, artifact_id uuid, artifact_size_bytes bigint,
               artifact_sha256 text, entry_count integer, skipped_media integer, ready_at timestamptz,
               artifact_snapshot_id uuid, download_block text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_parent boolean;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return;
  end if;
  v_parent := public.family_account_is_parent(public.family_account_id_for_baby(p_baby_id), auth.uid());
  return query
  select case when v_parent then j.id end, case when v_parent then j.status end,
         case when v_parent then j.attempts::integer end, case when v_parent then j.last_error_code end,
         case when v_parent then pr.percent::integer end, case when v_parent then pr.stage end,
         case when v_parent then j.updated_at end,
         a.id, a.size_bytes, a.sha256, md.entry_count, md.skipped_media, a.ready_at, a.snapshot_id, a.block
    from public.output_projects p
    left join lateral (select * from public.output_jobs j2 where j2.project_id = p.id
                        order by j2.created_at desc limit 1) j on true
    left join public.output_job_progress pr on pr.job_id = j.id
    left join lateral (
      select a2.*, public.output_artifact_download_block(a2.id, auth.uid()) as block
        from public.output_artifacts a2
       where a2.project_id = p.id and a2.status = 'ready'
       order by a2.ready_at desc limit 1) a0 on true
    left join lateral (select a0.* where v_parent or a0.block is null
                          or a0.block not in ('not_found', 'membership_inactive', 'permission_denied')) a on true
    left join public.html_artifact_metadata md on md.artifact_id = a.id
   where p.baby_id = p_baby_id and p.product_code = 'first_year_html'
     and p.family_account_id = public.family_account_id_for_baby(p_baby_id);
end;
$$;

-- Super Admin: download grants and refusals per product / reason.
create or replace function public.admin_download_audit(p_days integer default 7)
returns table (product_code text, outcome text, n bigint)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_since timestamptz := now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 90));
begin
  perform public.assert_admin_console('read', 120);
  return query
  select coalesce(d.product_code, a.product_code), 'granted:' || coalesce(d.role, 'unknown'), count(*)
    from public.output_artifact_downloads d
    left join public.output_artifacts a on a.id = d.artifact_id
   where d.requested_at >= v_since
   group by 1, 2
  union all
  select coalesce(a.product_code, 'unknown'), 'denied:' || x.reason, count(*)
    from public.output_download_denials x
    left join public.output_artifacts a on a.id = x.artifact_id
   where x.requested_at >= v_since
   group by 1, 2
   order by 1, 2;
end;
$$;

-- Grants ------------------------------------------------------------------------------------------------------
revoke all on function public.artifact_download_permissions_guard(),
  public.artifact_permissions_revoke_on_leave()
  from public, anon, authenticated;

revoke all on function public.authorize_artifact_download(uuid),
  public.set_artifact_download_permission(uuid, uuid, text, boolean),
  public.artifact_download_permission_list(uuid),
  public.admin_download_audit(integer)
  from public, anon;
grant execute on function public.authorize_artifact_download(uuid),
  public.set_artifact_download_permission(uuid, uuid, text, boolean),
  public.artifact_download_permission_list(uuid),
  public.admin_download_audit(integer)
  to authenticated, service_role;

commit;
