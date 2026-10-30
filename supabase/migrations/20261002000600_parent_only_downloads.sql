-- =====================================================================
-- Decisions P-12 / P-13 (2026-10-02, GELISTIRME.MD "Karar kaydı"): the
-- Book, Film and offline HTML outputs are downloaded by the parents only.
-- Family Members never download them and the app never hands the data to
-- third parties; a parent may share a downloaded file themselves (the
-- parents are the baby's legal guardians and heirs). Phase 12 had added
-- parent-granted Family Member downloads; they are retired here.
--
--   * Existing grants are revoked with an audit reason, never deleted.
--   * member_downloads flag off (kept for history).
--   * output_artifact_download_block(): non-parents get 'not_parent' before
--     any other check; the member capacity / grant branch is gone.
--   * set_artifact_download_permission(): sharing is refused; revoking
--     still works (idempotent clean-up).
-- =====================================================================
begin;

alter table public.artifact_download_permissions drop constraint artifact_download_permissions_revoke_reason_check;
alter table public.artifact_download_permissions add constraint artifact_download_permissions_revoke_reason_check
  check (revoke_reason in ('parent_revoked', 'membership_ended', 'parents_only_decision'));

update public.artifact_download_permissions
   set revoked_at = now(), revoke_reason = 'parents_only_decision'
 where revoked_at is null;

update public.platform_flags
   set enabled = false, note = 'P-12 (2026-10-02): outputs are downloaded by parents only; member downloads retired.'
 where key = 'member_downloads';

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
  -- Decision P-12: only Anne / Baba download the outputs, under every
  -- other condition below; Family Members never do.
  if not v_parent then
    return 'not_parent';
  end if;
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
  if v_art.status <> 'ready' then
    return 'artifact_not_ready';
  end if;
  return null;
end;
$$;

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
    -- Decision P-12: Family Members never download; nothing new is shared.
    raise exception 'member downloads are retired' using errcode = '55000', hint = 'member_downloads_disabled';
  end if;
  update public.artifact_download_permissions
     set revoked_at = now(), revoked_by = v_uid, revoke_reason = 'parent_revoked'
   where family_account_id = v_account and baby_id = p_baby_id and product_code = p_product_code
     and member_user_id = p_member_user_id and revoked_at is null;
  return p_allowed;
end;
$$;

-- Family Members do not see the outputs at all (decision P-12).
create or replace function public.book_versions(p_baby_id uuid)
returns table (export_id uuid, version integer, format text, page_count integer, size_bytes bigint,
               created_at timestamptz, artifact_id uuid, sha256 text, download_block text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return;
  end if;
  return query
  select v.* from (
    select e.id as e_id, e.version as e_version, e.format as e_format, e.page_count as e_pages,
           e.size_bytes as e_size, e.created_at as e_created, a.id as a_id, a.sha256 as a_sha,
           public.output_artifact_download_block(a.id, auth.uid()) as block
      from public.book_exports e
      join public.output_artifacts a on a.id = e.artifact_id
     where e.baby_id = p_baby_id and a.status = 'ready'
  ) v
  where v.block is null or v.block not in ('not_found', 'membership_inactive', 'permission_denied', 'not_parent')
  order by v.e_version desc;
end;
$$;

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
                          or a0.block not in ('not_found', 'membership_inactive', 'permission_denied', 'not_parent')) a on true
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
                          or a0.block not in ('not_found', 'membership_inactive', 'permission_denied', 'not_parent')) a on true
    left join public.html_artifact_metadata md on md.artifact_id = a.id
   where p.baby_id = p_baby_id and p.product_code = 'first_year_html'
     and p.family_account_id = public.family_account_id_for_baby(p_baby_id);
end;
$$;

commit;
