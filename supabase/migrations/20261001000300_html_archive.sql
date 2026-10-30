-- =====================================================================
-- Phase 11: downloadable offline HTML archive (ZIP).
--
--   * Same premium gate (html_access_block): LOCKED baby, parent, live
--     family subscription, active first_year_html entitlement.
--   * The archive is the whole sealed snapshot: no settings, no editing.
--     A request for a snapshot that already has a ready archive returns it;
--     identical waiting / running work is joined.
--   * The output worker (workers/output, ADR 0005) builds the bundle from
--     the sealed snapshot and publishes it with html_artifact_publish, which
--     stores the bundle metadata (entries, content size, skipped media,
--     manifest checksum).
-- Kill switches: html_renderer (new requests), output_worker (consumption).
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('html_renderer', true, 'Phase 11: parents may request offline HTML archives (off = no new requests; data is kept).')
on conflict (key) do nothing;

-- Generic worker progress (HTML; usable by future products).
create table public.output_job_progress (
  job_id     uuid primary key references public.output_jobs (id) on delete restrict,
  percent    smallint not null default 0 check (percent between 0 and 100),
  stage      text check (stage is null or stage ~ '^[a-z_]{1,40}$'),
  updated_at timestamptz not null default now()
);

create table public.html_artifact_metadata (
  artifact_id     uuid primary key references public.output_artifacts (id) on delete restrict,
  job_id          uuid not null references public.output_jobs (id) on delete restrict,
  snapshot_id     uuid not null references public.archive_snapshots (id) on delete restrict,
  entry_count     integer not null check (entry_count > 0),
  content_bytes   bigint not null check (content_bytes > 0),
  skipped_media   integer not null default 0 check (skipped_media >= 0),
  manifest_sha256 text not null check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  created_at      timestamptz not null default now()
);

create trigger html_artifact_metadata_append_only
  before update or delete on public.html_artifact_metadata
  for each row execute function public.output_append_only();

alter table public.output_job_progress enable row level security;
alter table public.html_artifact_metadata enable row level security;
revoke all on table public.output_job_progress, public.html_artifact_metadata from public, anon, authenticated;
grant all on table public.output_job_progress, public.html_artifact_metadata to service_role;

-- Access ----------------------------------------------------------------------------------------------
create or replace function public.html_renderer_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select f.enabled from public.platform_flags f where f.key = 'html_renderer'), true);
$$;

create or replace function public.html_access_block(p_baby_id uuid, p_user uuid default auth.uid())
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_user is null or not exists (select 1 from public.family_members fm
                                    where fm.baby_id = p_baby_id and fm.user_id = p_user) then
    return 'not_found';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return 'premium_requires_locked';
  end if;
  return public.output_request_block(p_baby_id, 'first_year_html', p_user);
end;
$$;

create or replace function public.html_access_state(p_baby_id uuid)
returns table (access_block text, renderer_enabled boolean)
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
  return query select public.html_access_block(p_baby_id, auth.uid()), public.html_renderer_enabled();
end;
$$;

-- Request ---------------------------------------------------------------------------------------------
create or replace function public.html_request_render(p_baby_id uuid, p_idempotency_key text)
returns table (job_id uuid, job_status text, snapshot_id uuid, reused boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_block text;
  v_account uuid;
  v_project uuid;
  v_snapshot uuid;
  v_job public.output_jobs;
  v_other public.output_jobs;
begin
  if v_uid is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  v_block := public.html_access_block(p_baby_id, v_uid);
  if v_block = 'not_parent' then
    raise exception 'only parents can create the archive' using errcode = '42501', hint = v_block;
  elsif v_block is not null then
    raise exception 'archive is not available' using errcode = '55000', hint = v_block;
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  if not public.html_renderer_enabled() then
    raise exception 'archive building is paused' using errcode = '55000', hint = 'html_renderer_disabled';
  end if;

  v_account := public.family_account_id_for_baby(p_baby_id);
  insert into public.output_projects (family_account_id, baby_id, product_code, created_by)
  values (v_account, p_baby_id, 'first_year_html', v_uid)
  on conflict (family_account_id, baby_id, product_code) do nothing;
  select p.id into v_project from public.output_projects p
   where p.family_account_id = v_account and p.baby_id = p_baby_id and p.product_code = 'first_year_html'
   for update;

  select * into v_job from public.output_jobs j where j.project_id = v_project and j.idempotency_key = p_idempotency_key;
  if v_job.id is not null then
    return query select v_job.id, v_job.status, v_job.snapshot_id, true;
    return;
  end if;

  v_snapshot := public.output_create_snapshot(p_baby_id, 'first_year_html', v_uid);

  -- The archive of this exact snapshot already exists: it is immutable, so
  -- the ready job is returned instead of building the same thing again.
  select j.* into v_job
    from public.output_jobs j
    join public.output_artifacts a on a.job_id = j.id and a.status = 'ready'
   where j.project_id = v_project and j.snapshot_id = v_snapshot
   order by a.ready_at desc
   limit 1;
  if v_job.id is not null then
    return query select v_job.id, v_job.status, v_job.snapshot_id, true;
    return;
  end if;

  for v_other in
    select j.* from public.output_jobs j
     where j.project_id = v_project and j.status in ('queued', 'running')
     order by j.created_at
     for update
  loop
    if v_other.snapshot_id = v_snapshot then
      return query select v_other.id, v_other.status, v_other.snapshot_id, true;
      return;
    end if;
    if v_other.status = 'running' then
      raise exception 'another archive is being built' using errcode = '55000', hint = 'html_render_in_progress';
    end if;
    perform public.book_cancel_job(v_other, 'superseded');
  end loop;

  insert into public.output_jobs (project_id, snapshot_id, family_account_id, baby_id, product_code, idempotency_key,
                                  requested_by)
  values (v_project, v_snapshot, v_account, p_baby_id, 'first_year_html', p_idempotency_key, v_uid)
  returning * into v_job;
  insert into public.output_job_progress (job_id, stage) values (v_job.id, 'queued');
  return query select v_job.id, v_job.status, v_snapshot, false;
end;
$$;

-- Latest archive job + latest ready archive. ACTIVE archives return nothing.
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
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return;
  end if;
  return query
  select j.id, j.status, j.attempts::integer, j.last_error_code, pr.percent::integer, pr.stage, j.updated_at,
         a.id, a.size_bytes, a.sha256, md.entry_count, md.skipped_media, a.ready_at, a.snapshot_id,
         case when a.id is null then null else public.output_artifact_download_block(a.id, auth.uid()) end
    from public.output_projects p
    left join lateral (select * from public.output_jobs j2 where j2.project_id = p.id
                        order by j2.created_at desc limit 1) j on true
    left join public.output_job_progress pr on pr.job_id = j.id
    left join lateral (select * from public.output_artifacts a2 where a2.project_id = p.id and a2.status = 'ready'
                        order by a2.ready_at desc limit 1) a on true
    left join public.html_artifact_metadata md on md.artifact_id = a.id
   where p.baby_id = p_baby_id and p.product_code = 'first_year_html'
     and p.family_account_id = public.family_account_id_for_baby(p_baby_id);
end;
$$;

-- Worker RPCs (service role) ----------------------------------------------------------------------------
create or replace function public.html_owned_job(p_job_id uuid, p_worker text)
returns public.output_jobs
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
begin
  select * into v_job from public.output_jobs j where j.id = p_job_id;
  if v_job.id is null or v_job.product_code <> 'first_year_html' then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker or v_job.lease_expires_at <= now() then
    raise exception 'job lease lost' using errcode = '55000', hint = 'lease_lost';
  end if;
  return v_job;
end;
$$;

-- The sealed snapshot of the leased job (exact canonical text + checksum).
create or replace function public.html_job_payload(p_job_id uuid, p_worker text)
returns table (snapshot_id uuid, snapshot_content text, snapshot_checksum text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job public.output_jobs := public.html_owned_job(p_job_id, p_worker);
begin
  return query select s.id, s.content::text, s.checksum from public.archive_snapshots s where s.id = v_job.snapshot_id;
end;
$$;

create or replace function public.output_job_progress_update(p_job_id uuid, p_worker text, p_percent integer, p_stage text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
begin
  select * into v_job from public.output_jobs j where j.id = p_job_id;
  if v_job.id is null or v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker
     or v_job.lease_expires_at <= now() then
    return false;
  end if;
  insert into public.output_job_progress (job_id, percent, stage, updated_at)
  values (p_job_id, least(greatest(coalesce(p_percent, 0), 0), 100), p_stage, now())
  on conflict (job_id) do update set percent = excluded.percent, stage = excluded.stage, updated_at = now();
  return true;
end;
$$;

-- Publish after the worker verified the ZIP against its own manifest.
create or replace function public.html_artifact_publish(
  p_artifact_id uuid,
  p_worker text,
  p_entry_count integer,
  p_content_bytes bigint,
  p_skipped_media integer,
  p_manifest_sha256 text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
  v_result text;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id for update;
  if v_art.id is null or v_art.product_code <> 'first_year_html' then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  perform public.html_owned_job(v_art.job_id, p_worker);
  if p_entry_count is null or p_entry_count < 5 or coalesce(p_content_bytes, 0) <= 0 or coalesce(p_skipped_media, -1) < 0
     or p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid archive metadata' using errcode = '22023';
  end if;
  v_result := public.output_artifact_publish(p_artifact_id, p_worker);
  if v_result = 'ready' then
    insert into public.html_artifact_metadata (artifact_id, job_id, snapshot_id, entry_count, content_bytes, skipped_media,
                                               manifest_sha256)
    values (v_art.id, v_art.job_id, v_art.snapshot_id, p_entry_count, p_content_bytes, p_skipped_media, p_manifest_sha256);
    insert into public.output_job_progress (job_id, percent, stage, updated_at)
    values (v_art.job_id, 100, 'ready', now())
    on conflict (job_id) do update set percent = 100, stage = 'ready', updated_at = now();
  end if;
  return v_result;
end;
$$;

-- Grants ------------------------------------------------------------------------------------------------------
revoke all on function public.html_renderer_enabled(),
  public.html_access_block(uuid, uuid),
  public.html_owned_job(uuid, text),
  public.html_job_payload(uuid, text),
  public.output_job_progress_update(uuid, text, integer, text),
  public.html_artifact_publish(uuid, text, integer, bigint, integer, text)
  from public, anon, authenticated;
grant execute on function public.html_renderer_enabled(),
  public.html_access_block(uuid, uuid),
  public.html_owned_job(uuid, text),
  public.html_job_payload(uuid, text),
  public.output_job_progress_update(uuid, text, integer, text),
  public.html_artifact_publish(uuid, text, integer, bigint, integer, text)
  to service_role;

revoke all on function public.html_access_state(uuid), public.html_request_render(uuid, text), public.html_state(uuid)
  from public, anon;
grant execute on function public.html_access_state(uuid), public.html_request_render(uuid, text), public.html_state(uuid)
  to authenticated, service_role;

commit;
