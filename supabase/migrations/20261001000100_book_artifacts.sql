-- =====================================================================
-- Phase 9: gate the "İlk Yılım" book and bind official PDFs to the
-- Phase 8 snapshot / job / artifact contract.
--
--   * Book configuration (book_projects / pages / items) is readable and
--     writable only for a parent of a LOCKED baby whose family account has
--     a live subscription and an active first_year_book entitlement. The
--     source archive is never written; editing touches configuration only.
--   * The PDF engine stays in the app. An official PDF is produced through a
--     verified client-render protocol:
--       book_render_start   -> seals the snapshot, freezes the book
--                              configuration (book_render_manifests) and
--                              leases a job to "book-client:<user>"
--       book_render_payload -> snapshot + manifest text for the lease owner
--       book_artifact_begin -> artifact row first, then a staging upload
--                              (Storage INSERT only on that exact path)
--       book-artifact-finalize Edge Function (service role) re-reads and
--                              hashes the staged object, moves it to its
--                              final path and calls book_artifact_publish.
--     A local file is never a licensed artifact.
--   * book_exports rows now always point at a ready output_artifacts row.
--     register_book_export without an artifact is refused.
--   * Legacy (pre-gate) projects and exports are hidden, never deleted,
--     marked legacy_quarantined and reported to Super Admins. No
--     entitlement is granted automatically.
--   * The "books" bucket loses every client policy; artifact downloads go
--     through output-download (Phase 8).
-- Kill switch: platform flag book_renderer (and output_worker).
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('book_renderer', true, 'Phase 9: parents may render official book PDFs (off = no new renders; data is kept).')
on conflict (key) do nothing;

-- Legacy markers ---------------------------------------------------------------------------------
alter table public.book_projects
  add column legacy_status text check (legacy_status in ('legacy_quarantined'));

alter table public.book_exports
  add column legacy_status text check (legacy_status in ('legacy_quarantined')),
  add column artifact_id uuid unique references public.output_artifacts (id) on delete restrict,
  add column bucket_id text not null default 'books' check (bucket_id in ('books', 'output-artifacts'));

-- Everything that exists before this migration was created without the
-- lifecycle / subscription / entitlement gate.
update public.book_projects set legacy_status = 'legacy_quarantined';
update public.book_exports set legacy_status = 'legacy_quarantined';

do $$
declare
  v_name text;
begin
  select c.conname into v_name
    from pg_constraint c
   where c.conrelid = 'public.book_exports'::regclass and c.contype = 'c'
     and pg_get_constraintdef(c.oid) like '%storage_path%';
  if v_name is not null then
    execute format('alter table public.book_exports drop constraint %I', v_name);
  end if;
end;
$$;

alter table public.book_exports add constraint book_exports_source_check check (
  (artifact_id is null and bucket_id = 'books' and legacy_status is not null
     and storage_path like baby_id::text || '/' || project_id::text || '/%')
  or (artifact_id is not null and bucket_id = 'output-artifacts' and legacy_status is null)
);

-- Access ------------------------------------------------------------------------------------------
create or replace function public.book_renderer_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select f.enabled from public.platform_flags f where f.key = 'book_renderer'), true)
         and public.output_worker_enabled();
$$;

-- null = the user may configure and render the official book; otherwise the
-- refusal hint (lifecycle first, so a Family Member of an ACTIVE baby hears
-- "premium_requires_locked", not "not_parent").
create or replace function public.book_access_block(p_baby_id uuid, p_user uuid default auth.uid())
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
  return public.output_request_block(p_baby_id, 'first_year_book', p_user);
end;
$$;

create or replace function public.book_config_access(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.book_access_block(p_baby_id, auth.uid()) is null;
$$;

create or replace function public.book_client_worker(p_user uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'book-client:' || p_user::text;
$$;

-- Configuration guards -------------------------------------------------------------------------------
create or replace function public.book_owner_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.baby_id <> old.baby_id then
    raise exception 'baby_id is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'book_projects' then
    -- only the official publish path may bump the version
    if coalesce(current_setting('bebegimin.book_version_bump', true), '') <> 'on' then
      new.current_version := old.current_version;
    end if;
    new.created_by := old.created_by;
    new.legacy_status := old.legacy_status;
  end if;
  return new;
end;
$$;

create or replace function public.book_projects_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.current_version := 0;
  new.legacy_status := null;
  return new;
end;
$$;

create trigger book_projects_insert_guard before insert on public.book_projects
  for each row execute function public.book_projects_insert_guard();

-- Exports are immutable and (from now on) always backed by a ready artifact
-- that was published through book_artifact_publish().
create or replace function public.book_exports_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
begin
  if tg_op = 'UPDATE' then
    raise exception 'book exports are immutable' using errcode = '42501';
  end if;
  if new.artifact_id is null then
    raise exception 'book exports require a verified artifact'
      using errcode = '42501', hint = 'book_export_requires_artifact';
  end if;
  if coalesce(current_setting('bebegimin.book_publish', true), '') <> 'on' then
    raise exception 'book exports are recorded by the publish step only' using errcode = '42501';
  end if;
  select * into v_art from public.output_artifacts a where a.id = new.artifact_id;
  if v_art.id is null or v_art.status <> 'ready' or v_art.product_code <> 'first_year_book'
     or v_art.baby_id <> new.baby_id or v_art.storage_path <> new.storage_path
     or v_art.size_bytes is distinct from new.size_bytes or new.bucket_id <> v_art.bucket_id then
    raise exception 'book export does not match its artifact' using errcode = '23514';
  end if;
  new.legacy_status := null;
  return new;
end;
$$;

create trigger book_exports_guard before insert or update on public.book_exports
  for each row execute function public.book_exports_guard();

-- Artifact files belong to the output pipeline (its own retention); only
-- legacy files in the "books" bucket are queued here.
create or replace function public.queue_book_file_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.artifact_id is null then
    insert into public.storage_cleanup_queue (bucket_id, path)
    values ('books', old.storage_path)
    on conflict do nothing;
  end if;
  return old;
end;
$$;

-- Legal deletion lists legacy book files only; artifact files are tracked
-- by output_artifacts.
create or replace function public.baby_storage_objects(p_baby_id uuid)
returns table (bucket_id text, path text)
language sql
stable
security definer
set search_path = ''
as $$
  select 'baby-media', m.storage_path from public.media m where m.baby_id = p_baby_id
  union all
  select 'baby-media', m.thumb_path from public.media m where m.baby_id = p_baby_id and m.thumb_path is not null
  union all
  select 'baby-media', b.avatar_path from public.babies b where b.id = p_baby_id and b.avatar_path is not null
  union all
  select 'baby-media', b.cover_path from public.babies b where b.id = p_baby_id and b.cover_path is not null
  union all
  select 'baby-media', p_baby_id::text || '/capsules/' || c.id::text || '/photo.jpg'
    from public.time_capsules c where c.baby_id = p_baby_id and c.has_photo
  union all
  select 'books', e.storage_path from public.book_exports e where e.baby_id = p_baby_id and e.artifact_id is null;
$$;

-- The pre-Phase 9 client upload path. Kept with its signature so old app
-- builds receive a clear refusal instead of "function does not exist".
create or replace function public.register_book_export(
  p_project_id uuid,
  p_storage_path text,
  p_page_count integer,
  p_size_bytes bigint,
  p_quality text default 'print'
)
returns public.book_exports
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'book exports require a verified artifact'
    using errcode = '42501', hint = 'book_export_requires_artifact';
end;
$$;

-- RLS: configuration behind the book gate; exports only through RPCs ------------------------------------
drop policy if exists "book creators and album viewers can read projects" on public.book_projects;
drop policy if exists "book creators can create projects" on public.book_projects;
drop policy if exists "book creators can update projects" on public.book_projects;
drop policy if exists "admins can delete projects" on public.book_projects;
drop policy if exists "book creators can read pages" on public.book_pages;
drop policy if exists "book creators can create pages" on public.book_pages;
drop policy if exists "book creators can update pages" on public.book_pages;
drop policy if exists "book creators can delete pages" on public.book_pages;
drop policy if exists "book creators can read items" on public.book_items;
drop policy if exists "book creators can create items" on public.book_items;
drop policy if exists "book creators can update items" on public.book_items;
drop policy if exists "book creators can delete items" on public.book_items;
drop policy if exists "album viewers can list exports" on public.book_exports;
drop policy if exists "admins can delete exports" on public.book_exports;

-- Projects are permanent configuration records (legacy ones included).
revoke delete on table public.book_projects from authenticated;
revoke select, insert, update, delete on table public.book_exports from authenticated;

create policy "entitled parents can read book projects"
  on public.book_projects for select to authenticated
  using (public.book_config_access(baby_id));
create policy "entitled parents can create book projects"
  on public.book_projects for insert to authenticated
  with check (public.book_config_access(baby_id));
create policy "entitled parents can update book projects"
  on public.book_projects for update to authenticated
  using (public.book_config_access(baby_id))
  with check (public.book_config_access(baby_id));

create policy "entitled parents can read book pages"
  on public.book_pages for select to authenticated
  using (public.book_config_access(baby_id));
create policy "entitled parents can create book pages"
  on public.book_pages for insert to authenticated
  with check (public.book_config_access(baby_id));
create policy "entitled parents can update book pages"
  on public.book_pages for update to authenticated
  using (public.book_config_access(baby_id))
  with check (public.book_config_access(baby_id));
create policy "entitled parents can delete book pages"
  on public.book_pages for delete to authenticated
  using (public.book_config_access(baby_id));

create policy "entitled parents can read book items"
  on public.book_items for select to authenticated
  using (public.book_config_access(baby_id));
create policy "entitled parents can create book items"
  on public.book_items for insert to authenticated
  with check (public.book_config_access(baby_id));
create policy "entitled parents can update book items"
  on public.book_items for update to authenticated
  using (public.book_config_access(baby_id))
  with check (public.book_config_access(baby_id));
create policy "entitled parents can delete book items"
  on public.book_items for delete to authenticated
  using (public.book_config_access(baby_id));

-- Legacy "books" bucket: no client reads, uploads or deletes. Files stay for
-- the legacy report; legal deletion still removes them via the service role.
drop policy if exists "bebegimin books read" on storage.objects;
drop policy if exists "bebegimin books insert" on storage.objects;
drop policy if exists "bebegimin books delete" on storage.objects;

-- Frozen book configuration per job ---------------------------------------------------------------------
create table public.book_render_manifests (
  job_id          uuid primary key references public.output_jobs (id) on delete restrict,
  book_project_id uuid not null, -- no FK: a sealed row is never touched by cascades
  baby_id         uuid not null,
  content         jsonb not null,
  checksum        text not null check (checksum ~ '^[0-9a-f]{64}$'),
  created_at      timestamptz not null default now()
);

create or replace function public.book_render_manifests_seal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'book manifests are immutable' using errcode = '42501';
  end if;
  if not exists (select 1 from public.output_jobs j
                  where j.id = new.job_id and j.baby_id = new.baby_id and j.product_code = 'first_year_book') then
    raise exception 'manifest and book job do not match' using errcode = '23514';
  end if;
  if new.content ->> 'id' is distinct from new.book_project_id::text
     or new.content ->> 'baby_id' is distinct from new.baby_id::text then
    raise exception 'manifest content belongs to another book' using errcode = '23514';
  end if;
  new.checksum := encode(sha256(convert_to(new.content::text, 'UTF8')), 'hex');
  new.created_at := now();
  return new;
end;
$$;

create trigger book_render_manifests_seal
  before insert or update or delete on public.book_render_manifests
  for each row execute function public.book_render_manifests_seal();

alter table public.book_render_manifests enable row level security;
revoke all on table public.book_render_manifests from public, anon, authenticated;
grant all on table public.book_render_manifests to service_role;

-- Same shape as the app's BookProject.fromJson (project + pages + items),
-- with a total order so equal configurations hash equally.
create or replace function public.build_book_manifest(p_project_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'manifest_version', 1,
    'id', p.id, 'baby_id', p.baby_id, 'kind', p.kind, 'title', p.title, 'subtitle', p.subtitle,
    'format', p.format, 'theme', p.theme, 'cover_media_id', p.cover_media_id,
    'back_cover_text', p.back_cover_text, 'current_version', p.current_version,
    'last_synced_at', public.snapshot_ts(p.last_synced_at), 'updated_at', public.snapshot_ts(p.updated_at),
    'book_pages', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pg.id, 'project_id', pg.project_id, 'page_type', pg.page_type, 'month_index', pg.month_index,
               'title', pg.title, 'body', pg.body, 'sort_order', pg.sort_order, 'is_hidden', pg.is_hidden,
               'book_items', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', i.id, 'page_id', i.page_id, 'item_type', i.item_type, 'media_id', i.media_id,
                          'memory_id', i.memory_id, 'milestone_id', i.milestone_id, 'letter_id', i.letter_id,
                          'sort_order', i.sort_order, 'is_hidden', i.is_hidden, 'caption', i.caption)
                        order by i.sort_order, i.id)
                   from public.book_items i where i.page_id = pg.id), '[]'::jsonb))
             order by pg.sort_order, pg.id)
        from public.book_pages pg where pg.project_id = p.id), '[]'::jsonb))
    from public.book_projects p
   where p.id = p_project_id;
$$;

-- Client render protocol ----------------------------------------------------------------------------------
-- Ends a running attempt of this book job without a retry.
create or replace function public.book_cancel_job(p_job public.output_jobs, p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.output_job_attempts
     set ended_at = now(), outcome = 'canceled', error_code = p_code
   where job_id = p_job.id and attempt = p_job.attempts and ended_at is null;
  perform public.output_abandon_staging(p_job.id, p_code);
  update public.output_jobs
     set status = 'canceled', lease_owner = null, lease_expires_at = null, last_error_code = p_code,
         finished_at = now()
   where id = p_job.id and status in ('queued', 'running');
end;
$$;

create or replace function public.book_render_start(p_baby_id uuid, p_idempotency_key text)
returns table (job_id uuid, job_status text, snapshot_id uuid, attempt integer, lease_expires_at timestamptz,
               reused boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_worker text;
  v_block text;
  v_account uuid;
  v_book public.book_projects;
  v_project uuid;
  v_snapshot uuid;
  v_job public.output_jobs;
  v_other public.output_jobs;
  v_reused boolean := false;
begin
  if v_uid is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  v_block := public.book_access_block(p_baby_id, v_uid);
  if v_block = 'not_parent' then
    raise exception 'only parents can create the book' using errcode = '42501', hint = v_block;
  elsif v_block is not null then
    raise exception 'book is not available' using errcode = '55000', hint = v_block;
  end if;
  if not public.book_renderer_enabled() then
    raise exception 'book rendering is paused' using errcode = '55000', hint = 'book_renderer_disabled';
  end if;

  -- The book project row lock serialises renders of this book.
  select * into v_book from public.book_projects b where b.baby_id = p_baby_id and b.kind = 'first_year' for update;
  if v_book.id is null then
    raise exception 'book project not found' using errcode = 'P0002', hint = 'book_project_missing';
  end if;
  v_worker := public.book_client_worker(v_uid);

  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  insert into public.output_projects (family_account_id, baby_id, product_code, created_by)
  values (v_account, p_baby_id, 'first_year_book', v_uid)
  on conflict (family_account_id, baby_id, product_code) do nothing;
  select p.id into v_project from public.output_projects p
   where p.family_account_id = v_account and p.baby_id = p_baby_id and p.product_code = 'first_year_book'
   for update;
  perform public.output_expire_leases();

  select * into v_job from public.output_jobs j where j.project_id = v_project and j.idempotency_key = p_idempotency_key;
  if v_job.id is not null then
    v_reused := true;
    if v_job.status <> 'queued' and not (v_job.status = 'running' and v_job.lease_owner is distinct from v_worker) then
      -- Same request again: still ours, or already finished.
      return query select v_job.id, v_job.status, v_job.snapshot_id, v_job.attempts::integer, v_job.lease_expires_at, true;
      return;
    end if;
    if v_job.status = 'running' or not exists (select 1 from public.book_render_manifests m where m.job_id = v_job.id) then
      raise exception 'another render of this book is in progress' using errcode = '55000', hint = 'book_render_in_progress';
    end if;
  end if;

  -- One renderer per book: our own stale attempt is superseded, someone
  -- else's live lease blocks.
  for v_other in
    select * from public.output_jobs j where j.project_id = v_project and j.status = 'running' for update
  loop
    if v_other.lease_owner is distinct from v_worker then
      raise exception 'another render of this book is in progress' using errcode = '55000', hint = 'book_render_in_progress';
    end if;
    perform public.book_cancel_job(v_other, 'superseded');
  end loop;

  if v_job.id is null then
    -- Older client jobs waiting after an expired lease carry an outdated
    -- configuration.
    for v_other in
      select j.* from public.output_jobs j
       where j.project_id = v_project and j.status = 'queued'
         and exists (select 1 from public.book_render_manifests m where m.job_id = j.id)
       for update
    loop
      perform public.book_cancel_job(v_other, 'superseded');
    end loop;

    v_snapshot := public.output_create_snapshot(p_baby_id, 'first_year_book', v_uid);
    insert into public.output_jobs (project_id, snapshot_id, family_account_id, baby_id, product_code, idempotency_key,
                                    requested_by)
    values (v_project, v_snapshot, v_account, p_baby_id, 'first_year_book', p_idempotency_key, v_uid)
    returning * into v_job;
    insert into public.book_render_manifests (job_id, book_project_id, baby_id, content, checksum)
    values (v_job.id, v_book.id, p_baby_id, public.build_book_manifest(v_book.id), repeat('0', 64));
  end if;

  update public.output_jobs j
     set status = 'running', attempts = j.attempts + 1, lease_owner = v_worker,
         lease_expires_at = now() + interval '15 minutes', heartbeat_at = now(),
         started_at = coalesce(j.started_at, now()), available_at = now()
   where j.id = v_job.id
  returning * into v_job;
  insert into public.output_job_attempts (job_id, attempt, worker) values (v_job.id, v_job.attempts, v_worker);
  return query select v_job.id, v_job.status, v_job.snapshot_id, v_job.attempts::integer, v_job.lease_expires_at, v_reused;
end;
$$;

-- The running client job of the caller (or a refusal).
create or replace function public.book_owned_job(p_job_id uuid)
returns public.output_jobs
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
  v_block text;
begin
  select * into v_job from public.output_jobs j where j.id = p_job_id;
  if v_job.id is null or auth.uid() is null
     or not exists (select 1 from public.book_render_manifests m where m.job_id = v_job.id)
     or v_job.requested_by is distinct from auth.uid() then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if v_job.status <> 'running' or v_job.lease_owner is distinct from public.book_client_worker(auth.uid())
     or v_job.lease_expires_at <= now() then
    raise exception 'render lease lost' using errcode = '55000', hint = 'lease_lost';
  end if;
  v_block := public.book_access_block(v_job.baby_id, auth.uid());
  if v_block is not null then
    raise exception 'book is not available' using errcode = '55000', hint = v_block;
  end if;
  return v_job;
end;
$$;

-- Exact canonical texts the checksums were computed from; the app verifies
-- both before rendering.
create or replace function public.book_render_payload(p_job_id uuid)
returns table (snapshot_id uuid, snapshot_content text, snapshot_checksum text, manifest_content text,
               manifest_checksum text)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job public.output_jobs := public.book_owned_job(p_job_id);
begin
  return query
  select s.id, s.content::text, s.checksum, m.content::text, m.checksum
    from public.archive_snapshots s
    join public.book_render_manifests m on m.job_id = v_job.id
   where s.id = v_job.snapshot_id;
end;
$$;

create or replace function public.book_render_heartbeat(p_job_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs := public.book_owned_job(p_job_id);
begin
  return public.output_job_heartbeat(v_job.id, public.book_client_worker(auth.uid()), 900);
end;
$$;

-- The artifact row exists before the app uploads a single byte.
create or replace function public.book_artifact_begin(p_job_id uuid, p_sha256 text, p_size_bytes bigint)
returns table (artifact_id uuid, staging_path text, storage_path text, version integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job public.output_jobs := public.book_owned_job(p_job_id);
begin
  return query
  select b.artifact_id, b.staging_path, b.storage_path, b.version
    from public.output_artifact_begin(v_job.id, public.book_client_worker(auth.uid()), 'ilk-yil-kitabi.pdf',
                                      'application/pdf', p_sha256, p_size_bytes) b;
end;
$$;

-- The app reports a render / upload failure; the attempt is retried later
-- with the same frozen snapshot and manifest.
create or replace function public.book_render_fail(p_job_id uuid, p_error_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
begin
  if p_error_code is null or p_error_code not in ('render_failed', 'image_failed', 'upload_failed', 'client_aborted') then
    raise exception 'invalid error code' using errcode = '22023';
  end if;
  select * into v_job from public.output_jobs j where j.id = p_job_id;
  if v_job.id is null or v_job.requested_by is distinct from auth.uid()
     or not exists (select 1 from public.book_render_manifests m where m.job_id = v_job.id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  return public.output_job_fail(v_job.id, public.book_client_worker(auth.uid()), p_error_code, null, true);
end;
$$;

-- Storage INSERT is possible for exactly one path: the staging object of the
-- caller's live book attempt.
create or replace function public.can_upload_book_staging(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.output_artifacts a
      join public.output_jobs j on j.id = a.job_id
     where a.staging_path = p_name and a.status = 'staging' and a.product_code = 'first_year_book'
       and j.status = 'running' and j.attempts = a.attempt and j.lease_expires_at > now()
       and j.lease_owner = public.book_client_worker(auth.uid())
  );
$$;

drop policy if exists "bebegimin output-artifacts book staging insert" on storage.objects;
create policy "bebegimin output-artifacts book staging insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'output-artifacts' and public.can_upload_book_staging(name));

-- Service role (book-artifact-finalize): after the verified object was moved
-- to its final path, publish the artifact and record the book version in
-- the same transaction.
create or replace function public.book_artifact_publish(p_artifact_id uuid, p_worker text, p_page_count integer)
returns table (status text, export_id uuid, book_version integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_art public.output_artifacts;
  v_job public.output_jobs;
  v_manifest public.book_render_manifests;
  v_book public.book_projects;
  v_export public.book_exports;
  v_result text;
begin
  if p_page_count is null or p_page_count not between 1 and 5000 then
    raise exception 'invalid page count' using errcode = '22023';
  end if;
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id;
  select * into v_manifest from public.book_render_manifests m where m.job_id = v_art.job_id;
  if v_art.id is null or v_manifest.job_id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  v_result := public.output_artifact_publish(p_artifact_id, p_worker);
  if v_result <> 'ready' then
    return query select v_result, null::uuid, null::integer;
    return;
  end if;

  select * into v_job from public.output_jobs j where j.id = v_art.job_id;
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id;
  select * into v_book from public.book_projects b where b.id = v_manifest.book_project_id for update;
  if v_book.id is null then
    raise exception 'book project of this render is gone' using errcode = '23514';
  end if;
  perform set_config('bebegimin.book_version_bump', 'on', true);
  update public.book_projects b set current_version = b.current_version + 1 where b.id = v_book.id
  returning * into v_book;
  perform set_config('bebegimin.book_version_bump', '', true);

  perform set_config('bebegimin.book_publish', 'on', true);
  insert into public.book_exports (project_id, baby_id, version, format, quality, storage_path, page_count, size_bytes,
                                   created_by, artifact_id, bucket_id)
  values (v_book.id, v_book.baby_id, v_book.current_version, v_manifest.content ->> 'format', 'print',
          v_art.storage_path, p_page_count, v_art.size_bytes, v_job.requested_by, v_art.id, v_art.bucket_id)
  returning * into v_export;
  perform set_config('bebegimin.book_publish', '', true);
  return query select 'ready'::text, v_export.id, v_export.version;
end;
$$;

-- App state -------------------------------------------------------------------------------------------------
create or replace function public.book_access_state(p_baby_id uuid)
returns table (access_block text, renderer_enabled boolean, has_project boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_block text;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  v_block := public.book_access_block(p_baby_id, auth.uid());
  return query
  select v_block, public.book_renderer_enabled(),
         v_block is null and exists (select 1 from public.book_projects b where b.baby_id = p_baby_id);
end;
$$;

-- Official versions of the baby's book with the caller's download state.
-- ACTIVE archives list nothing; legacy exports are never listed.
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
  where v.block is null or v.block not in ('not_found', 'membership_inactive', 'permission_denied')
  order by v.e_version desc;
end;
$$;

-- Super Admin: legacy (pre-gate) book data, never shown to families.
create or replace function public.admin_legacy_book_report()
returns table (baby_id uuid, project_id uuid, project_legacy boolean, legacy_exports bigint, official_exports bigint,
               lifecycle_active boolean, first_legacy_export_at timestamptz, last_legacy_export_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.assert_admin_console('read', 120);
  return query
  select p.baby_id, p.id, p.legacy_status is not null,
         count(e.id) filter (where e.legacy_status is not null),
         count(e.id) filter (where e.artifact_id is not null),
         coalesce(public.baby_lifecycle_active_internal(p.baby_id), true),
         min(e.created_at) filter (where e.legacy_status is not null),
         max(e.created_at) filter (where e.legacy_status is not null)
    from public.book_projects p
    left join public.book_exports e on e.project_id = p.id
   where p.legacy_status is not null or e.legacy_status is not null
   group by p.id
   order by p.baby_id, p.id;
end;
$$;

-- Grants ------------------------------------------------------------------------------------------------------
revoke all on function public.book_renderer_enabled(),
  public.book_access_block(uuid, uuid),
  public.book_client_worker(uuid),
  public.book_projects_insert_guard(),
  public.book_exports_guard(),
  public.book_render_manifests_seal(),
  public.build_book_manifest(uuid),
  public.book_cancel_job(public.output_jobs, text),
  public.book_owned_job(uuid),
  public.book_artifact_publish(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.book_renderer_enabled(),
  public.book_access_block(uuid, uuid),
  public.book_client_worker(uuid),
  public.build_book_manifest(uuid),
  public.book_cancel_job(public.output_jobs, text),
  public.book_owned_job(uuid),
  public.book_artifact_publish(uuid, text, integer)
  to service_role;

-- RLS / Storage policy helpers run as the calling role.
revoke all on function public.book_config_access(uuid), public.can_upload_book_staging(text) from public, anon;
grant execute on function public.book_config_access(uuid), public.can_upload_book_staging(text)
  to authenticated, service_role;

revoke all on function public.book_render_start(uuid, text),
  public.book_render_payload(uuid),
  public.book_render_heartbeat(uuid),
  public.book_artifact_begin(uuid, text, bigint),
  public.book_render_fail(uuid, text),
  public.book_access_state(uuid),
  public.book_versions(uuid),
  public.admin_legacy_book_report()
  from public, anon;
grant execute on function public.book_render_start(uuid, text),
  public.book_render_payload(uuid),
  public.book_render_heartbeat(uuid),
  public.book_artifact_begin(uuid, text, bigint),
  public.book_render_fail(uuid, text),
  public.book_access_state(uuid),
  public.book_versions(uuid),
  public.admin_legacy_book_report()
  to authenticated, service_role;

commit;
