-- =====================================================================
-- Phase 8: immutable archive snapshots, output jobs and artifacts.
--
-- The shared, product-agnostic backbone for Book (PDF), Offline HTML (ZIP)
-- and Film (MP4). Product renderers arrive in phases 9-11.
--
--   * archive_snapshots: canonical JSON of a LOCKED baby's archive (author
--     names / relations copied in), sealed on insert (sha256 checksum),
--     never updated or deleted. Identical archives reuse one snapshot.
--   * output_projects / output_jobs: one project per family account + baby
--     + product; jobs are idempotent per project key and consumed by
--     workers with leases, heartbeats, exponential backoff, a max attempt
--     count and a poison (dead-letter) state.
--   * output_artifacts: staging upload -> checksum verified -> moved to
--     <baby>/<product>/<snapshot>/v<version>/<file> -> ready. Reads go
--     through the artifact row, never through a folder convention.
--   * Downloads re-check membership, lifecycle, subscription, entitlement,
--     permission and artifact state on every request; only the grant is
--     logged (no URL, no token).
--   * Only parents of a LOCKED baby with a live subscription and an active
--     entitlement can create snapshots / jobs. Nothing here changes the
--     lifecycle, the subscription or the entitlement.
--
-- This migration is intentionally re-runnable. Early Phase 8 drafts were
-- applied manually in development environments; IF NOT EXISTS plus trigger
-- replacement upgrades those databases without deleting output data.
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('output_worker', true, 'Phase 8: output workers may claim jobs (off = queued jobs wait, nothing is lost).')
on conflict (key) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('output-artifacts', 'output-artifacts', false, 2147483648,
        array['application/pdf', 'application/zip', 'video/mp4'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Helpers ---------------------------------------------------------------------------------------
create or replace function public.output_product_mime(p_product text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_product
    when 'first_year_book' then 'application/pdf'
    when 'first_year_html' then 'application/zip'
    when 'first_year_film' then 'video/mp4'
  end;
$$;

-- Timestamps are rendered in UTC so the canonical JSON never depends on the
-- session time zone.
create or replace function public.snapshot_ts(p_value timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select to_char(p_value at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
$$;

-- Error texts coming from workers never keep URLs, signatures or tokens.
create or replace function public.output_redact(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(
    regexp_replace(
      regexp_replace(
        regexp_replace(coalesce(p_text, ''), 'https?://[^[:space:]"'']+', '[url]', 'gi'),
        '(token|signature|sig|key|secret|apikey|x-amz-[a-z-]+)=[^[:space:]&"'']+', '\1=[redacted]', 'gi'),
      'bearer[[:space:]]+[A-Za-z0-9._~+/=-]+', 'Bearer [redacted]', 'gi'),
    500);
$$;

create or replace function public.output_retry_delay(p_attempts integer)
returns interval
language sql
immutable
set search_path = ''
as $$
  select make_interval(secs => least(30 * power(2, greatest(coalesce(p_attempts, 1), 1) - 1), 3600));
$$;

-- Snapshots ---------------------------------------------------------------------------------------
create table if not exists public.archive_snapshots (
  id                uuid primary key default gen_random_uuid(),
  family_account_id uuid not null references public.family_accounts (id) on delete restrict,
  baby_id           uuid not null references public.babies (id) on delete restrict,
  schema_version    smallint not null check (schema_version > 0),
  content           jsonb not null,
  checksum          text not null check (checksum ~ '^[0-9a-f]{64}$'),
  content_bytes     integer not null check (content_bytes > 0),
  item_counts       jsonb not null,
  created_by        uuid, -- no FK: a sealed row must never be touched by ON DELETE SET NULL
  sealed_at         timestamptz not null default now(),
  unique (family_account_id, baby_id, schema_version, checksum)
);

-- Sealing happens on insert: the checksum is always computed here from the
-- canonical text of the content (jsonb output is key-sorted and stable).
create or replace function public.archive_snapshots_seal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'sealed snapshots are immutable' using errcode = '42501';
  end if;
  if (new.content ->> 'schema_version')::smallint is distinct from new.schema_version then
    raise exception 'schema_version mismatch' using errcode = '22023';
  end if;
  if not exists (select 1 from public.family_account_babies fab
                  where fab.baby_id = new.baby_id and fab.family_account_id = new.family_account_id) then
    raise exception 'snapshot family and baby do not match' using errcode = '23514';
  end if;
  if new.content -> 'baby' ->> 'id' is distinct from new.baby_id::text then
    raise exception 'snapshot content belongs to another baby' using errcode = '23514';
  end if;
  new.checksum := encode(sha256(convert_to(new.content::text, 'UTF8')), 'hex');
  new.content_bytes := octet_length(convert_to(new.content::text, 'UTF8'));
  new.item_counts := jsonb_build_object(
    'members', jsonb_array_length(new.content -> 'members'),
    'milestones', jsonb_array_length(new.content -> 'milestones'),
    'memories', jsonb_array_length(new.content -> 'memories'),
    'letters', jsonb_array_length(new.content -> 'letters'),
    'media', jsonb_array_length(new.content -> 'media'),
    'comments', jsonb_array_length(new.content -> 'comments'));
  new.sealed_at := now();
  return new;
end;
$$;

drop trigger if exists archive_snapshots_seal on public.archive_snapshots;
create trigger archive_snapshots_seal
  before insert or update or delete on public.archive_snapshots
  for each row execute function public.archive_snapshots_seal();

-- Author / relation values as they are at snapshot time.
create or replace function public.archive_snapshot_person(p_baby_id uuid, p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_user is null then null else jsonb_build_object(
    'user_id', p_user,
    'name', coalesce((select nullif(btrim(p.display_name), '') from public.profiles p where p.id = p_user), ''),
    'relation', (select fm.relation from public.family_members fm where fm.baby_id = p_baby_id and fm.user_id = p_user),
    'relation_label', (select fm.relation_label from public.family_members fm where fm.baby_id = p_baby_id and fm.user_id = p_user)
  ) end;
$$;

-- Canonical archive content (schema version 1). Arrays have a total order;
-- sealed time capsules and per-user favorites are never part of an output.
create or replace function public.build_archive_snapshot_content(p_baby_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby public.babies;
  v_extension integer;
begin
  select * into v_baby from public.babies b where b.id = p_baby_id;
  if v_baby.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select coalesce(max(er.requested_days) filter (where er.status = 'approved'), 0)::integer into v_extension
    from public.baby_extension_requests er where er.baby_id = p_baby_id;

  return jsonb_build_object(
    'schema_version', 1,
    'baby', jsonb_build_object(
      'id', v_baby.id, 'first_name', v_baby.first_name, 'last_name', v_baby.last_name,
      'birth_date', v_baby.birth_date, 'birth_time', v_baby.birth_time, 'birth_place', v_baby.birth_place,
      'birth_weight_grams', v_baby.birth_weight_grams, 'birth_length_cm', v_baby.birth_length_cm,
      'avatar_path', v_baby.avatar_path, 'cover_path', v_baby.cover_path, 'story', v_baby.story),
    'lifecycle', jsonb_build_object(
      'base_close_date', v_baby.birth_date + 375,
      'extension_days', v_extension,
      'effective_close_date', v_baby.birth_date + 375 + v_extension),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', fm.user_id,
               'name', coalesce(nullif(btrim(p.display_name), ''), ''),
               'relation', fm.relation,
               'relation_label', fm.relation_label)
             order by fm.joined_at, fm.user_id)
        from public.family_members fm
        left join public.profiles p on p.id = fm.user_id
       where fm.baby_id = p_baby_id), '[]'::jsonb),
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'type_key', t.key, 'title', t.title, 'emoji', t.emoji,
               'achieved_on', m.achieved_on, 'achieved_time', m.achieved_time, 'description', m.description,
               'include_in_book', m.include_in_book,
               'author', public.archive_snapshot_person(p_baby_id, m.created_by))
             order by m.achieved_on, t.sort_order, m.id)
        from public.milestones m
        join public.milestone_types t on t.id = m.milestone_type_id
       where m.baby_id = p_baby_id), '[]'::jsonb),
    'memories', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'title', m.title, 'body', m.body, 'memory_date', m.memory_date,
               'memory_time', m.memory_time, 'category', m.category, 'milestone_id', m.milestone_id,
               'include_in_book', m.include_in_book,
               'author', public.archive_snapshot_person(p_baby_id, m.author_id))
             order by m.memory_date, m.memory_time nulls first, m.created_at, m.id)
        from public.memories m
       where m.baby_id = p_baby_id), '[]'::jsonb),
    'letters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'title', l.title, 'body', l.body, 'written_on', l.written_on,
               'include_in_book', l.include_in_book,
               'author', coalesce(public.archive_snapshot_person(p_baby_id, l.author_id), '{}'::jsonb)
                         || jsonb_strip_nulls(jsonb_build_object(
                              'name', nullif(btrim(l.author_name), ''),
                              'relation', l.author_relation,
                              'relation_label', l.author_relation_label)))
             order by l.written_on, l.created_at, l.id)
        from public.letters l
       where l.baby_id = p_baby_id), '[]'::jsonb),
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'kind', m.kind, 'storage_path', m.storage_path, 'thumb_path', m.thumb_path,
               'mime_type', m.mime_type, 'width', m.width, 'height', m.height, 'duration_ms', m.duration_ms,
               'size_bytes', m.size_bytes, 'caption', m.caption, 'taken_on', m.taken_on, 'tags', to_jsonb(m.tags),
               'include_in_book', m.include_in_book, 'sort_order', m.sort_order,
               'memory_id', m.memory_id, 'milestone_id', m.milestone_id, 'letter_id', m.letter_id,
               'uploader', public.archive_snapshot_person(p_baby_id, m.uploader_id))
             order by m.taken_on, m.sort_order, m.created_at, m.id)
        from public.media m
       where m.baby_id = p_baby_id and m.status = 'ready'), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'memory_id', c.memory_id, 'milestone_id', c.milestone_id, 'media_id', c.media_id,
               'body', c.body, 'created_at', public.snapshot_ts(c.created_at),
               'author', public.archive_snapshot_person(p_baby_id, c.author_id))
             order by c.created_at, c.id)
        from public.comments c
       where c.baby_id = p_baby_id), '[]'::jsonb)
  );
end;
$$;

-- Projects, jobs, attempts ---------------------------------------------------------------------------
create table if not exists public.output_projects (
  id                uuid primary key default gen_random_uuid(),
  family_account_id uuid not null references public.family_accounts (id) on delete restrict,
  baby_id           uuid not null references public.babies (id) on delete restrict,
  product_code      text not null check (product_code in ('first_year_book', 'first_year_html', 'first_year_film')),
  settings          jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  created_by        uuid references auth.users (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (family_account_id, baby_id, product_code)
);

drop trigger if exists output_projects_set_updated_at on public.output_projects;
create trigger output_projects_set_updated_at
  before update on public.output_projects
  for each row execute function public.set_updated_at();

create or replace function public.output_projects_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'output projects are permanent records' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and
     (new.family_account_id, new.baby_id, new.product_code, new.created_at)
       is distinct from
     (old.family_account_id, old.baby_id, old.product_code, old.created_at) then
    raise exception 'output project identity is immutable' using errcode = '42501';
  end if;
  if not exists (select 1 from public.family_account_babies fab
                  where fab.baby_id = new.baby_id and fab.family_account_id = new.family_account_id) then
    raise exception 'output project family and baby do not match' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists output_projects_guard on public.output_projects;
create trigger output_projects_guard
  before insert or update or delete on public.output_projects
  for each row execute function public.output_projects_guard();

create table if not exists public.output_jobs (
  id                uuid primary key default gen_random_uuid(),
  project_id        uuid not null references public.output_projects (id) on delete restrict,
  snapshot_id       uuid not null references public.archive_snapshots (id) on delete restrict,
  family_account_id uuid not null,
  baby_id           uuid not null,
  product_code      text not null,
  idempotency_key   text not null check (idempotency_key ~ '^[A-Za-z0-9_-]{8,100}$'),
  status            text not null default 'queued'
                      check (status in ('queued', 'running', 'succeeded', 'poison', 'canceled')),
  attempts          smallint not null default 0 check (attempts >= 0),
  max_attempts      smallint not null default 5 check (max_attempts between 1 and 20),
  available_at      timestamptz not null default now(),
  lease_owner       text,
  lease_expires_at  timestamptz,
  heartbeat_at      timestamptz,
  last_error_code   text,
  last_error        text,
  requested_by      uuid, -- no FK: finished audit rows stay immutable when an auth user is deleted
  created_at        timestamptz not null default now(),
  started_at        timestamptz,
  finished_at       timestamptz,
  updated_at        timestamptz not null default now(),
  unique (project_id, idempotency_key),
  check ((status = 'running') = (lease_owner is not null and lease_expires_at is not null)),
  check ((status in ('succeeded', 'poison', 'canceled')) = (finished_at is not null))
);

-- Older manually-applied Phase 8 drafts used ON DELETE SET NULL here. The
-- finished-job immutability trigger must not block auth-user deletion, so the
-- requestor UUID is deliberately retained as an audit value without an FK.
alter table public.output_jobs drop constraint if exists output_jobs_requested_by_fkey;

create index if not exists output_jobs_queue_idx on public.output_jobs (available_at, created_at) where status = 'queued';
create index if not exists output_jobs_lease_idx on public.output_jobs (lease_expires_at) where status = 'running';
create index if not exists output_jobs_project_idx on public.output_jobs (project_id, created_at desc);

drop trigger if exists output_jobs_set_updated_at on public.output_jobs;
create trigger output_jobs_set_updated_at
  before update on public.output_jobs
  for each row execute function public.set_updated_at();

create or replace function public.output_jobs_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'output jobs are permanent records' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and
     (new.project_id, new.snapshot_id, new.family_account_id, new.baby_id, new.product_code, new.idempotency_key, new.created_at)
     is distinct from
     (old.project_id, old.snapshot_id, old.family_account_id, old.baby_id, old.product_code, old.idempotency_key, old.created_at) then
    raise exception 'output job identity is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.status in ('succeeded', 'poison', 'canceled') then
    raise exception 'finished output jobs are immutable' using errcode = '42501';
  end if;
  if (tg_op = 'UPDATE' and new.attempts < old.attempts) or new.attempts > new.max_attempts then
    raise exception 'invalid attempt count' using errcode = '22023';
  end if;
  if not exists (select 1 from public.output_projects p
                  where p.id = new.project_id and p.family_account_id = new.family_account_id
                    and p.baby_id = new.baby_id and p.product_code = new.product_code) then
    raise exception 'output job and project do not match' using errcode = '23514';
  end if;
  if not exists (select 1 from public.archive_snapshots s
                  where s.id = new.snapshot_id and s.family_account_id = new.family_account_id
                    and s.baby_id = new.baby_id) then
    raise exception 'output job and snapshot do not match' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists output_jobs_guard on public.output_jobs;
create trigger output_jobs_guard
  before insert or update or delete on public.output_jobs
  for each row execute function public.output_jobs_guard();

create table if not exists public.output_job_attempts (
  id          bigint generated always as identity primary key,
  job_id      uuid not null references public.output_jobs (id) on delete restrict,
  attempt     smallint not null,
  worker      text not null,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  outcome     text check (outcome in ('succeeded', 'failed', 'lease_expired', 'quarantined', 'canceled')),
  error_code  text,
  duration_ms integer,
  unique (job_id, attempt),
  check ((ended_at is null) = (outcome is null))
);

create or replace function public.output_job_attempts_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or old.ended_at is not null
     or (new.job_id, new.attempt, new.worker, new.started_at) is distinct from (old.job_id, old.attempt, old.worker, old.started_at) then
    raise exception 'attempt records are append-only' using errcode = '42501';
  end if;
  if new.ended_at is not null then
    new.duration_ms := greatest(0, (extract(epoch from new.ended_at - new.started_at) * 1000)::integer);
  end if;
  return new;
end;
$$;

drop trigger if exists output_job_attempts_guard on public.output_job_attempts;
create trigger output_job_attempts_guard
  before update or delete on public.output_job_attempts
  for each row execute function public.output_job_attempts_guard();

-- Artifacts -------------------------------------------------------------------------------------------
create table if not exists public.output_artifacts (
  id                uuid primary key default gen_random_uuid(),
  job_id            uuid not null references public.output_jobs (id) on delete restrict,
  project_id        uuid not null references public.output_projects (id) on delete restrict,
  snapshot_id       uuid not null references public.archive_snapshots (id) on delete restrict,
  family_account_id uuid not null,
  baby_id           uuid not null,
  product_code      text not null,
  version           integer not null check (version > 0),
  attempt           smallint not null,
  bucket_id         text not null default 'output-artifacts' check (bucket_id = 'output-artifacts'),
  storage_path      text not null unique,
  staging_path      text not null unique,
  file_name         text not null check (file_name ~ '^[a-z0-9][a-z0-9._-]{0,80}$'),
  mime_type         text not null,
  sha256            text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  size_bytes        bigint not null check (size_bytes > 0),
  verified_sha256   text check (verified_sha256 is null or verified_sha256 ~ '^[0-9a-f]{64}$'),
  status            text not null default 'staging'
                      check (status in ('staging', 'verified', 'ready', 'quarantined', 'abandoned')),
  failure_code      text,
  created_at        timestamptz not null default now(),
  verified_at       timestamptz,
  ready_at          timestamptz,
  purged_at         timestamptz,
  unique (project_id, snapshot_id, version),
  -- a checksum mismatch can never be ready
  check (status not in ('verified', 'ready') or (verified_sha256 = sha256 and verified_at is not null)),
  check ((status = 'ready') = (ready_at is not null)),
  check (status <> 'ready' or purged_at is null)
);

create index if not exists output_artifacts_ready_idx on public.output_artifacts (baby_id, product_code, ready_at desc) where status = 'ready';

create or replace function public.output_artifacts_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'artifact records are permanent' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and
     (new.job_id, new.project_id, new.snapshot_id, new.family_account_id, new.baby_id, new.product_code, new.version,
      new.attempt, new.bucket_id, new.storage_path, new.staging_path, new.file_name, new.mime_type, new.sha256,
      new.size_bytes, new.created_at)
     is distinct from
     (old.job_id, old.project_id, old.snapshot_id, old.family_account_id, old.baby_id, old.product_code, old.version,
      old.attempt, old.bucket_id, old.storage_path, old.staging_path, old.file_name, old.mime_type, old.sha256,
      old.size_bytes, old.created_at) then
    raise exception 'artifact identity is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.status <> new.status and not (
       (old.status = 'staging' and new.status in ('verified', 'quarantined', 'abandoned'))
    or (old.status = 'verified' and new.status in ('ready', 'quarantined', 'abandoned'))
    or (old.status = 'ready' and new.status = 'quarantined')) then
    raise exception 'invalid artifact transition % -> %', old.status, new.status using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.verified_sha256 is not null and new.verified_sha256 is distinct from old.verified_sha256 then
    raise exception 'verified checksum is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.purged_at is not null and new.purged_at is distinct from old.purged_at then
    raise exception 'purged artifacts are final' using errcode = '42501';
  end if;
  if not exists (select 1 from public.output_jobs j
                  where j.id = new.job_id and j.project_id = new.project_id and j.snapshot_id = new.snapshot_id
                    and j.family_account_id = new.family_account_id and j.baby_id = new.baby_id
                    and j.product_code = new.product_code) then
    raise exception 'artifact and output job do not match' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' and not exists (select 1 from public.output_jobs j
                                      where j.id = new.job_id and j.attempts = new.attempt) then
    raise exception 'artifact belongs to another job attempt' using errcode = '23514';
  end if;
  if new.mime_type is distinct from public.output_product_mime(new.product_code) then
    raise exception 'artifact MIME type does not match the product' using errcode = '23514';
  end if;
  if new.storage_path is distinct from
       format('%s/%s/%s/v%s/%s', new.baby_id, new.product_code, new.snapshot_id, new.version, new.file_name)
     or new.staging_path is distinct from format('staging/%s/%s', new.id, new.file_name) then
    raise exception 'artifact storage path is outside its namespace' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists output_artifacts_guard on public.output_artifacts;
create trigger output_artifacts_guard
  before insert or update or delete on public.output_artifacts
  for each row execute function public.output_artifacts_guard();

-- Download grants: who, which artifact, when. Never the URL or token.
create table if not exists public.output_artifact_downloads (
  id           bigint generated always as identity primary key,
  artifact_id  uuid not null references public.output_artifacts (id) on delete restrict,
  user_id      uuid not null,
  requested_at timestamptz not null default now()
);

create index if not exists output_artifact_downloads_artifact_idx on public.output_artifact_downloads (artifact_id, requested_at desc);

create or replace function public.output_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end;
$$;

drop trigger if exists output_artifact_downloads_append_only on public.output_artifact_downloads;
create trigger output_artifact_downloads_append_only
  before update or delete on public.output_artifact_downloads
  for each row execute function public.output_append_only();

create table if not exists public.output_maintenance_runs (
  id     bigint generated always as identity primary key,
  ran_at timestamptz not null default now(),
  result jsonb not null
);

-- RLS: service-only tables; clients use the RPCs below.
alter table public.archive_snapshots enable row level security;
alter table public.output_projects enable row level security;
alter table public.output_jobs enable row level security;
alter table public.output_job_attempts enable row level security;
alter table public.output_artifacts enable row level security;
alter table public.output_artifact_downloads enable row level security;
alter table public.output_maintenance_runs enable row level security;
revoke all on table public.archive_snapshots, public.output_projects, public.output_jobs, public.output_job_attempts,
  public.output_artifacts, public.output_artifact_downloads, public.output_maintenance_runs
  from public, anon, authenticated;
grant all on table public.archive_snapshots, public.output_projects, public.output_jobs, public.output_job_attempts,
  public.output_artifacts, public.output_artifact_downloads, public.output_maintenance_runs
  to service_role;

-- Eligibility -----------------------------------------------------------------------------------------
-- Creating snapshots / jobs: active parent of the baby's family account,
-- LOCKED baby, live subscription, active entitlement for the product.
create or replace function public.output_request_block(p_baby_id uuid, p_product text, p_user uuid default auth.uid())
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
begin
  if public.output_product_mime(p_product) is null then
    raise exception 'unknown product' using errcode = '22023';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null or not public.family_account_is_parent(v_account, p_user) then
    return 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return 'premium_requires_locked';
  end if;
  if not exists (select 1 from public.subscriptions s
                  where s.family_account_id = v_account
                    and public.subscription_grants_access(s.status, s.current_period_end)) then
    return 'subscription_required';
  end if;
  if not exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_account and e.baby_id = p_baby_id
                    and e.product_code = p_product and e.status = 'active') then
    return 'entitlement_required';
  end if;
  return null;
end;
$$;

-- Seals (or reuses) the snapshot of a LOCKED baby for an entitled product.
-- Enforced for every caller, the service role included.
create or replace function public.output_create_snapshot(p_baby_id uuid, p_product text, p_user uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_content jsonb;
  v_checksum text;
  v_id uuid;
begin
  if public.output_product_mime(p_product) is null then
    raise exception 'unknown product' using errcode = '22023';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_user is not null and not public.family_account_is_parent(v_account, p_user) then
    raise exception 'only parents can create output snapshots'
      using errcode = '42501', hint = 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    raise exception 'snapshots are taken after the archive is locked'
      using errcode = '55000', hint = 'premium_requires_locked';
  end if;
  if not exists (select 1 from public.subscriptions s
                  where s.family_account_id = v_account
                    and public.subscription_grants_access(s.status, s.current_period_end)) then
    raise exception 'an active subscription is required'
      using errcode = '55000', hint = 'subscription_required';
  end if;
  if not exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_account and e.baby_id = p_baby_id
                    and e.product_code = p_product and e.status = 'active') then
    raise exception 'no active entitlement for this product' using errcode = '42501', hint = 'entitlement_required';
  end if;

  v_content := public.build_archive_snapshot_content(p_baby_id);
  v_checksum := encode(sha256(convert_to(v_content::text, 'UTF8')), 'hex');
  insert into public.archive_snapshots (family_account_id, baby_id, schema_version, content, checksum, content_bytes,
                                        item_counts, created_by)
  values (v_account, p_baby_id, 1, v_content, v_checksum, 1,
          jsonb_build_object(
            'members', jsonb_array_length(v_content -> 'members'),
            'milestones', jsonb_array_length(v_content -> 'milestones'),
            'memories', jsonb_array_length(v_content -> 'memories'),
            'letters', jsonb_array_length(v_content -> 'letters'),
            'media', jsonb_array_length(v_content -> 'media'),
            'comments', jsonb_array_length(v_content -> 'comments')),
          p_user)
  on conflict (family_account_id, baby_id, schema_version, checksum) do nothing
  returning id into v_id;
  if v_id is null then
    select s.id into v_id from public.archive_snapshots s
     where s.family_account_id = v_account and s.baby_id = p_baby_id and s.schema_version = 1 and s.checksum = v_checksum;
  end if;
  return v_id;
end;
$$;

-- Parent request: ensure the project, seal the snapshot, enqueue once.
create or replace function public.request_output_job(p_baby_id uuid, p_product_code text, p_idempotency_key text)
returns table (job_id uuid, job_status text, snapshot_id uuid, reused boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_block text;
  v_account uuid;
  v_project uuid;
  v_snapshot uuid;
  v_job public.output_jobs;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  v_block := public.output_request_block(p_baby_id, p_product_code);
  if v_block = 'not_parent' then
    raise exception 'only parents can create outputs' using errcode = '42501', hint = v_block;
  elsif v_block is not null then
    raise exception 'output is not available' using errcode = '55000', hint = v_block;
  end if;

  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  insert into public.output_projects (family_account_id, baby_id, product_code, created_by)
  values (v_account, p_baby_id, p_product_code, auth.uid())
  on conflict (family_account_id, baby_id, product_code) do nothing;
  -- The project row lock serialises concurrent requests for this product.
  select p.id into v_project from public.output_projects p
   where p.family_account_id = v_account and p.baby_id = p_baby_id and p.product_code = p_product_code
   for update;

  select * into v_job from public.output_jobs j where j.project_id = v_project and j.idempotency_key = p_idempotency_key;
  if v_job.id is not null then
    return query select v_job.id, v_job.status, v_job.snapshot_id, true;
    return;
  end if;

  v_snapshot := public.output_create_snapshot(p_baby_id, p_product_code, auth.uid());

  -- Same work already queued or running: never a second job.
  select * into v_job from public.output_jobs j
   where j.project_id = v_project and j.snapshot_id = v_snapshot and j.status in ('queued', 'running')
   order by j.created_at desc limit 1;
  if v_job.id is not null then
    return query select v_job.id, v_job.status, v_job.snapshot_id, true;
    return;
  end if;

  insert into public.output_jobs (project_id, snapshot_id, family_account_id, baby_id, product_code, idempotency_key,
                                  requested_by)
  values (v_project, v_snapshot, v_account, p_baby_id, p_product_code, p_idempotency_key, auth.uid())
  returning * into v_job;
  return query select v_job.id, v_job.status, v_job.snapshot_id, false;
end;
$$;

-- Worker API (service role) -----------------------------------------------------------------------------
create or replace function public.output_worker_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select f.enabled from public.platform_flags f where f.key = 'output_worker'), true);
$$;

-- Staging objects of a failed / abandoned attempt are queued for removal.
create or replace function public.output_abandon_staging(p_job_id uuid, p_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with gone as (
    update public.output_artifacts a
       set status = 'abandoned', failure_code = coalesce(a.failure_code, p_code), purged_at = now()
     where a.job_id = p_job_id and a.status in ('staging', 'verified')
    returning a.staging_path, a.storage_path
  ), queued as (
    insert into public.storage_cleanup_queue (bucket_id, path)
    select 'output-artifacts', x.path from gone g cross join lateral (values (g.staging_path), (g.storage_path)) x(path)
    on conflict do nothing
  )
  select count(*) into v_count from gone;
  return v_count;
end;
$$;

-- Leases that ran out go back to the queue with backoff, or to poison.
create or replace function public.output_expire_leases()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
  v_count integer := 0;
begin
  for v_job in
    select * from public.output_jobs j
     where j.status = 'running' and j.lease_expires_at < now()
     for update skip locked
  loop
    update public.output_job_attempts
       set ended_at = now(), outcome = 'lease_expired', error_code = 'lease_expired'
     where job_id = v_job.id and attempt = v_job.attempts and ended_at is null;
    perform public.output_abandon_staging(v_job.id, 'lease_expired');
    if v_job.attempts >= v_job.max_attempts then
      update public.output_jobs
         set status = 'poison', lease_owner = null, lease_expires_at = null, last_error_code = 'lease_expired',
             last_error = 'worker lease expired', finished_at = now()
       where id = v_job.id;
    else
      update public.output_jobs
         set status = 'queued', lease_owner = null, lease_expires_at = null, last_error_code = 'lease_expired',
             last_error = 'worker lease expired', available_at = now() + public.output_retry_delay(v_job.attempts)
       where id = v_job.id;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.output_claim_jobs(
  p_worker text,
  p_products text[],
  p_limit integer default 1,
  p_lease_seconds integer default 120
)
returns table (
  job_id uuid,
  snapshot_id uuid,
  project_id uuid,
  baby_id uuid,
  product_code text,
  attempt integer,
  lease_expires_at timestamptz,
  settings jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_worker is null or p_worker !~ '^[A-Za-z0-9._:-]{1,80}$' then
    raise exception 'invalid worker id' using errcode = '22023';
  end if;
  if p_lease_seconds not between 30 and 900 or p_limit not between 1 and 10 then
    raise exception 'invalid lease or limit' using errcode = '22023';
  end if;
  if not public.output_worker_enabled() or coalesce(cardinality(p_products), 0) = 0 then
    return;
  end if;
  perform public.output_expire_leases();

  -- Refunded / revoked products are not rendered.
  update public.output_jobs j
     set status = 'canceled', last_error_code = 'entitlement_revoked', finished_at = now()
   where j.status = 'queued'
     and not exists (select 1 from public.product_entitlements e
                      where e.family_account_id = j.family_account_id and e.baby_id = j.baby_id
                        and e.product_code = j.product_code and e.status = 'active');

  -- Access can end while a job waits in the queue. Keep the sealed snapshot,
  -- but never spend renderer capacity after the family subscription closes.
  update public.output_jobs j
     set status = 'canceled', last_error_code = 'subscription_inactive', finished_at = now()
   where j.status = 'queued'
     and not exists (select 1 from public.subscriptions s
                      where s.family_account_id = j.family_account_id
                        and public.subscription_grants_access(s.status, s.current_period_end));

  -- A later extension can temporarily reopen a previously locked archive.
  -- Its old snapshot must not be rendered while the source is mutable.
  update public.output_jobs j
     set status = 'canceled', last_error_code = 'lifecycle_reopened', finished_at = now()
   where j.status = 'queued' and coalesce(public.baby_lifecycle_active_internal(j.baby_id), true);

  return query
  with picked as (
    select j.id from public.output_jobs j
     where j.status = 'queued' and j.available_at <= now() and j.product_code = any (p_products)
     order by j.available_at, j.created_at
     limit p_limit
     for update skip locked
  ), claimed as (
    update public.output_jobs j
       set status = 'running', attempts = j.attempts + 1, lease_owner = p_worker,
           lease_expires_at = now() + make_interval(secs => p_lease_seconds), heartbeat_at = now(),
           started_at = coalesce(j.started_at, now())
      from picked
     where j.id = picked.id
    returning j.id, j.snapshot_id, j.project_id, j.baby_id, j.product_code, j.attempts, j.lease_expires_at
  ), logged as (
    insert into public.output_job_attempts (job_id, attempt, worker)
    select c.id, c.attempts, p_worker from claimed c
  )
  select c.id, c.snapshot_id, c.project_id, c.baby_id, c.product_code, c.attempts::integer, c.lease_expires_at, p.settings
    from claimed c
    join public.output_projects p on p.id = c.project_id;
end;
$$;

create or replace function public.output_job_heartbeat(p_job_id uuid, p_worker text, p_lease_seconds integer default 120)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_lease_seconds not between 30 and 900 then
    raise exception 'invalid lease' using errcode = '22023';
  end if;
  update public.output_jobs
     set lease_expires_at = now() + make_interval(secs => p_lease_seconds), heartbeat_at = now()
   where id = p_job_id and status = 'running' and lease_owner = p_worker and lease_expires_at > now();
  return found;
end;
$$;

-- The exact canonical text the checksum was computed from, so the worker
-- can verify the snapshot before rendering it.
create or replace function public.output_snapshot_payload(p_snapshot_id uuid)
returns table (content text, checksum text, schema_version smallint)
language sql
stable
security definer
set search_path = ''
as $$
  select s.content::text, s.checksum, s.schema_version from public.archive_snapshots s where s.id = p_snapshot_id;
$$;

create or replace function public.output_job_fail(
  p_job_id uuid,
  p_worker text,
  p_error_code text,
  p_error text default null,
  p_retryable boolean default true
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
  v_outcome text := case when p_error_code in ('checksum_mismatch', 'object_missing', 'size_mismatch')
                         then 'quarantined' else 'failed' end;
begin
  if p_error_code is null or p_error_code !~ '^[a-z0-9_]{1,60}$' then
    raise exception 'invalid error code' using errcode = '22023';
  end if;
  select * into v_job from public.output_jobs j where j.id = p_job_id for update;
  if v_job.id is null or v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker
     or v_job.lease_expires_at <= now() then
    return 'lease_lost';
  end if;
  update public.output_job_attempts
     set ended_at = now(), outcome = v_outcome, error_code = p_error_code
   where job_id = v_job.id and attempt = v_job.attempts and ended_at is null;
  perform public.output_abandon_staging(v_job.id, p_error_code);
  if not coalesce(p_retryable, true) or v_job.attempts >= v_job.max_attempts then
    update public.output_jobs
       set status = 'poison', lease_owner = null, lease_expires_at = null, last_error_code = p_error_code,
           last_error = public.output_redact(p_error), finished_at = now()
     where id = v_job.id;
    return 'poison';
  end if;
  update public.output_jobs
     set status = 'queued', lease_owner = null, lease_expires_at = null, last_error_code = p_error_code,
         last_error = public.output_redact(p_error), available_at = now() + public.output_retry_delay(v_job.attempts)
   where id = v_job.id;
  return 'retry_scheduled';
end;
$$;

-- Step 1: the artifact row exists before any byte is uploaded.
create or replace function public.output_artifact_begin(
  p_job_id uuid,
  p_worker text,
  p_file_name text,
  p_mime_type text,
  p_sha256 text,
  p_size_bytes bigint
)
returns table (artifact_id uuid, staging_path text, storage_path text, version integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job public.output_jobs;
  v_id uuid := gen_random_uuid();
  v_version integer;
  v_path text;
  v_staging text;
begin
  select * into v_job from public.output_jobs j where j.id = p_job_id for update;
  if v_job.id is null or v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker
     or v_job.lease_expires_at <= now() then
    raise exception 'job lease lost' using errcode = '55000', hint = 'lease_lost';
  end if;
  if p_mime_type is distinct from public.output_product_mime(v_job.product_code) then
    raise exception 'wrong file type for this product' using errcode = '22023';
  end if;
  if p_file_name is null or p_file_name !~ '^[a-z0-9][a-z0-9._-]{0,80}$' then
    raise exception 'invalid file name' using errcode = '22023';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' or coalesce(p_size_bytes, 0) <= 0 then
    raise exception 'checksum and size are required' using errcode = '22023';
  end if;
  if p_size_bytes > (select b.file_size_limit from storage.buckets b where b.id = 'output-artifacts') then
    raise exception 'artifact is too large' using errcode = '22023';
  end if;

  select coalesce(max(a.version), 0) + 1 into v_version
    from public.output_artifacts a
   where a.project_id = v_job.project_id and a.snapshot_id = v_job.snapshot_id;
  v_path := format('%s/%s/%s/v%s/%s', v_job.baby_id, v_job.product_code, v_job.snapshot_id, v_version, p_file_name);
  v_staging := format('staging/%s/%s', v_id, p_file_name);
  insert into public.output_artifacts (id, job_id, project_id, snapshot_id, family_account_id, baby_id, product_code,
                                       version, attempt, storage_path, staging_path, file_name, mime_type, sha256,
                                       size_bytes)
  values (v_id, v_job.id, v_job.project_id, v_job.snapshot_id, v_job.family_account_id, v_job.baby_id,
          v_job.product_code, v_version, v_job.attempts, v_path, v_staging, p_file_name, p_mime_type, p_sha256,
          p_size_bytes);
  return query select v_id, v_staging, v_path, v_version;
end;
$$;

-- Step 2: the worker re-read the staged object and hashed it. A mismatch
-- (or a missing / resized object) quarantines the artifact and fails the
-- attempt; it can never become ready.
create or replace function public.output_artifact_verify(p_artifact_id uuid, p_worker text, p_verified_sha256 text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
  v_job public.output_jobs;
  v_size bigint;
  v_found boolean;
  v_code text;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id for update;
  if v_art.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select * into v_job from public.output_jobs j where j.id = v_art.job_id for update;
  if v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker or v_art.status <> 'staging'
     or v_art.attempt <> v_job.attempts or v_job.lease_expires_at <= now() then
    return 'lease_lost';
  end if;

  select true, (o.metadata ->> 'size')::bigint into v_found, v_size
    from storage.objects o where o.bucket_id = 'output-artifacts' and o.name = v_art.staging_path;
  if not coalesce(v_found, false) then
    v_code := 'object_missing';
  elsif v_size is not null and v_size <> v_art.size_bytes then
    v_code := 'size_mismatch';
  elsif p_verified_sha256 is null or p_verified_sha256 !~ '^[0-9a-f]{64}$' or p_verified_sha256 <> v_art.sha256 then
    v_code := 'checksum_mismatch';
  end if;

  if v_code is not null then
    -- Quarantined files are kept for inspection, then purged by maintenance.
    update public.output_artifacts set status = 'quarantined', failure_code = v_code where id = v_art.id;
    perform public.output_job_fail(v_job.id, p_worker, v_code, 'artifact failed verification', true);
    return 'quarantined';
  end if;

  update public.output_artifacts
     set status = 'verified', verified_sha256 = p_verified_sha256, verified_at = now()
   where id = v_art.id;
  return 'verified';
end;
$$;

-- Step 3: the verified object was moved to its final path; the DB record
-- turns ready and the job succeeds.
create or replace function public.output_artifact_publish(p_artifact_id uuid, p_worker text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
  v_job public.output_jobs;
  v_size bigint;
  v_found boolean;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id for update;
  if v_art.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select * into v_job from public.output_jobs j where j.id = v_art.job_id for update;
  if v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker or v_art.status <> 'verified'
     or v_job.lease_expires_at <= now() then
    return 'lease_lost';
  end if;
  select true, (o.metadata ->> 'size')::bigint into v_found, v_size
    from storage.objects o where o.bucket_id = 'output-artifacts' and o.name = v_art.storage_path;
  if not coalesce(v_found, false) or (v_size is not null and v_size <> v_art.size_bytes) then
    update public.output_artifacts set status = 'quarantined', failure_code = 'object_missing' where id = v_art.id;
    perform public.output_job_fail(v_job.id, p_worker, 'object_missing', 'published object missing or resized', true);
    return 'quarantined';
  end if;

  update public.output_artifacts set status = 'ready', ready_at = now() where id = v_art.id;
  update public.output_job_attempts
     set ended_at = now(), outcome = 'succeeded'
   where job_id = v_job.id and attempt = v_job.attempts and ended_at is null;
  update public.output_jobs
     set status = 'succeeded', lease_owner = null, lease_expires_at = null, finished_at = now(),
         last_error_code = null, last_error = null
   where id = v_job.id;
  return 'ready';
end;
$$;

-- Maintenance: expired leases, stale staging uploads, quarantine retention
-- and orphan objects (files without a live artifact row).
create or replace function public.output_pipeline_maintenance(
  p_staging_ttl interval default interval '2 hours',
  p_quarantine_retention interval default interval '7 days'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_leases integer;
  v_stale integer;
  v_purged integer;
  v_orphans integer;
  v_result jsonb;
begin
  v_leases := public.output_expire_leases();

  with stale as (
    update public.output_artifacts a
       set status = 'abandoned', failure_code = coalesce(a.failure_code, 'staging_timeout'), purged_at = now()
     where a.status in ('staging', 'verified') and a.created_at < now() - p_staging_ttl
       and not exists (select 1 from public.output_jobs j
                        where j.id = a.job_id and j.status = 'running' and j.lease_expires_at > now()
                          and j.attempts = a.attempt)
    returning a.staging_path, a.storage_path
  ), queued as (
    insert into public.storage_cleanup_queue (bucket_id, path)
    select 'output-artifacts', x.path from stale s cross join lateral (values (s.staging_path), (s.storage_path)) x(path)
    on conflict do nothing
  )
  select count(*) into v_stale from stale;

  with purge as (
    update public.output_artifacts a
       set purged_at = now()
     where a.status = 'quarantined' and a.purged_at is null
       and coalesce(a.verified_at, a.created_at) < now() - p_quarantine_retention
    returning a.staging_path, a.storage_path
  ), queued as (
    insert into public.storage_cleanup_queue (bucket_id, path)
    select 'output-artifacts', x.path from purge p cross join lateral (values (p.staging_path), (p.storage_path)) x(path)
    on conflict do nothing
  )
  select count(*) into v_purged from purge;

  with orphans as (
    insert into public.storage_cleanup_queue (bucket_id, path)
    select 'output-artifacts', o.name
      from storage.objects o
     where o.bucket_id = 'output-artifacts'
       and o.created_at < now() - p_staging_ttl
       and not exists (select 1 from public.output_artifacts a
                        where a.purged_at is null and (a.storage_path = o.name or a.staging_path = o.name))
    on conflict do nothing
    returning 1
  )
  select count(*) into v_orphans from orphans;

  v_result := jsonb_build_object('expired_leases', v_leases, 'abandoned_staging', v_stale,
                                 'purged_quarantine', v_purged, 'orphan_objects', v_orphans);
  insert into public.output_maintenance_runs (result) values (v_result);
  return v_result;
end;
$$;

-- Reclaim expired leases, quarantine stale uploads and queue orphan files
-- hourly. The existing storage-cleanup Edge Function performs the physical
-- Storage deletes from storage_cleanup_queue.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.schedule(
        'bebegimin-output-pipeline-maintenance',
        '7 * * * *',
        'select public.output_pipeline_maintenance()'
      );
    exception when others then
      raise notice 'pg_cron output pipeline scheduling skipped: %', sqlerrm;
    end;
  else
    raise notice 'pg_cron is not available; schedule public.output_pipeline_maintenance() hourly.';
  end if;
end;
$$;

-- Downloads ------------------------------------------------------------------------------------------------
-- null = allowed; otherwise the refusal hint. Checked on every request and
-- by the Storage read policy.
create or replace function public.output_artifact_download_block(p_artifact_id uuid, p_user uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
  v_fm public.family_members;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id;
  if v_art.id is null or p_user is null then
    return 'not_found';
  end if;
  select * into v_fm from public.family_members fm where fm.baby_id = v_art.baby_id and fm.user_id = p_user;
  if v_fm.id is null or not exists (select 1 from public.family_account_babies fab
                                     where fab.baby_id = v_art.baby_id
                                       and fab.family_account_id = v_art.family_account_id) then
    return 'not_found';
  end if;
  if not public.family_account_is_member(v_art.family_account_id, p_user) then
    return 'membership_inactive';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(v_art.baby_id), true) then
    return 'premium_requires_locked';
  end if;
  if not exists (select 1 from public.subscriptions s
                  where s.family_account_id = v_art.family_account_id
                    and public.subscription_grants_access(s.status, s.current_period_end)) then
    return 'subscription_required';
  end if;
  if not exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_art.family_account_id and e.baby_id = v_art.baby_id
                    and e.product_code = v_art.product_code and e.status = 'active') then
    return 'entitlement_required';
  end if;
  if not (v_fm.is_admin or 'view_album' = any (v_fm.permissions)) then
    return 'permission_denied';
  end if;
  if v_art.status <> 'ready' then
    return 'artifact_not_ready';
  end if;
  return null;
end;
$$;

-- Storage policy helper: a file is readable only through a ready artifact
-- row that passes every download check.
create or replace function public.can_read_output_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.output_artifacts a
     where a.storage_path = p_name and a.status = 'ready'
       and public.output_artifact_download_block(a.id, auth.uid()) is null
  );
$$;

-- The client signs a short-lived URL for the returned path (the Storage
-- policy re-checks); only the grant itself is logged.
create or replace function public.request_output_download(p_artifact_id uuid)
returns table (bucket_id text, storage_path text, file_name text, mime_type text, size_bytes bigint, sha256 text,
               expires_in integer)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_block text := public.output_artifact_download_block(p_artifact_id, auth.uid());
begin
  if v_block = 'not_found' then
    raise exception 'resource not found' using errcode = 'P0002';
  elsif v_block = 'permission_denied' then
    raise exception 'download not allowed' using errcode = '42501', hint = v_block;
  elsif v_block is not null then
    raise exception 'download not available' using errcode = '55000', hint = v_block;
  end if;
  insert into public.output_artifact_downloads (artifact_id, user_id) values (p_artifact_id, auth.uid());
  return query
  select a.bucket_id, a.storage_path, a.file_name, a.mime_type, a.size_bytes, a.sha256, 60
    from public.output_artifacts a where a.id = p_artifact_id;
end;
$$;

-- Per-product output state of a baby for its members (the Phase 9-11 UIs).
create or replace function public.baby_output_status(p_baby_id uuid)
returns table (
  product_code text,
  job_id uuid,
  job_status text,
  job_updated_at timestamptz,
  artifact_id uuid,
  artifact_size_bytes bigint,
  artifact_ready_at timestamptz,
  download_block text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  return query
  select p.product_code, j.id, j.status, j.updated_at, a.id, a.size_bytes, a.ready_at,
         case when a.id is null then null else public.output_artifact_download_block(a.id, auth.uid()) end
    from public.output_projects p
    join public.family_account_babies fab on fab.baby_id = p.baby_id and fab.family_account_id = p.family_account_id
    left join lateral (select * from public.output_jobs j2 where j2.project_id = p.id
                        order by j2.created_at desc limit 1) j on true
    left join lateral (select * from public.output_artifacts a2 where a2.project_id = p.id and a2.status = 'ready'
                        order by a2.ready_at desc limit 1) a on true
   where p.baby_id = p_baby_id
   order by p.product_code;
end;
$$;

-- Observability -----------------------------------------------------------------------------------------
-- Per product: job states, retries, attempt durations, failure codes and
-- artifact sizes since p_since.
create or replace function public.output_pipeline_metrics(p_since timestamptz default now() - interval '7 days')
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_object_agg(pc.code, jsonb_build_object(
    'jobs', coalesce((select jsonb_object_agg(s.status, s.n)
                        from (select j.status, count(*) as n from public.output_jobs j
                               where j.product_code = pc.code and j.created_at >= p_since group by j.status) s),
                     '{}'::jsonb),
    'retries', (select coalesce(sum(greatest(j.attempts - 1, 0)), 0) from public.output_jobs j
                 where j.product_code = pc.code and j.created_at >= p_since),
    'duration_ms_avg', (select round(avg(a.duration_ms)) from public.output_job_attempts a
                          join public.output_jobs j on j.id = a.job_id
                         where j.product_code = pc.code and a.outcome = 'succeeded' and a.started_at >= p_since),
    'duration_ms_p95', (select round(percentile_cont(0.95) within group (order by a.duration_ms)::numeric)
                          from public.output_job_attempts a
                          join public.output_jobs j on j.id = a.job_id
                         where j.product_code = pc.code and a.outcome = 'succeeded' and a.started_at >= p_since),
    'failure_codes', coalesce((select jsonb_object_agg(f.error_code, f.n)
                                 from (select a.error_code, count(*) as n from public.output_job_attempts a
                                         join public.output_jobs j on j.id = a.job_id
                                        where j.product_code = pc.code and a.outcome <> 'succeeded'
                                          and a.started_at >= p_since
                                        group by a.error_code) f),
                              '{}'::jsonb),
    'artifacts_ready', (select count(*) from public.output_artifacts a
                         where a.product_code = pc.code and a.status = 'ready' and a.ready_at >= p_since),
    'artifact_bytes_avg', (select round(avg(a.size_bytes)) from public.output_artifacts a
                            where a.product_code = pc.code and a.status = 'ready' and a.ready_at >= p_since),
    'artifact_bytes_max', (select max(a.size_bytes) from public.output_artifacts a
                            where a.product_code = pc.code and a.status = 'ready' and a.ready_at >= p_since)
  ))
  from (values ('first_year_book'), ('first_year_html'), ('first_year_film')) as pc(code);
$$;

create or replace function public.admin_output_metrics(p_days integer default 7)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('read', 120);
  return public.output_pipeline_metrics(now() - make_interval(days => least(greatest(coalesce(p_days, 7), 1), 90)));
end;
$$;

-- Storage policy ---------------------------------------------------------------------------------------------
-- Authenticated clients get no direct bucket SELECT. The output-download Edge
-- Function calls request_output_download with the user's JWT, then signs the
-- authorized path as service_role for exactly the returned 60 seconds. This
-- prevents clients from choosing a longer signed-URL lifetime.
drop policy if exists "bebegimin output-artifacts read" on storage.objects;

-- Grants ------------------------------------------------------------------------------------------------------
revoke all on function public.output_product_mime(text),
  public.snapshot_ts(timestamptz),
  public.output_redact(text),
  public.output_retry_delay(integer),
  public.archive_snapshots_seal(),
  public.output_append_only(),
  public.archive_snapshot_person(uuid, uuid),
  public.build_archive_snapshot_content(uuid),
  public.output_projects_guard(),
  public.output_jobs_guard(),
  public.output_job_attempts_guard(),
  public.output_artifacts_guard(),
  public.output_request_block(uuid, text, uuid),
  public.output_create_snapshot(uuid, text, uuid),
  public.output_worker_enabled(),
  public.output_abandon_staging(uuid, text),
  public.output_expire_leases(),
  public.output_claim_jobs(text, text[], integer, integer),
  public.output_job_heartbeat(uuid, text, integer),
  public.output_snapshot_payload(uuid),
  public.output_job_fail(uuid, text, text, text, boolean),
  public.output_artifact_begin(uuid, text, text, text, text, bigint),
  public.output_artifact_verify(uuid, text, text),
  public.output_artifact_publish(uuid, text),
  public.output_pipeline_maintenance(interval, interval),
  public.output_artifact_download_block(uuid, uuid),
  public.can_read_output_object(text),
  public.output_pipeline_metrics(timestamptz)
  from public, anon, authenticated;
grant execute on function public.output_product_mime(text),
  public.snapshot_ts(timestamptz),
  public.output_redact(text),
  public.output_retry_delay(integer),
  public.archive_snapshot_person(uuid, uuid),
  public.build_archive_snapshot_content(uuid),
  public.output_request_block(uuid, text, uuid),
  public.output_create_snapshot(uuid, text, uuid),
  public.output_worker_enabled(),
  public.output_abandon_staging(uuid, text),
  public.output_expire_leases(),
  public.output_claim_jobs(text, text[], integer, integer),
  public.output_job_heartbeat(uuid, text, integer),
  public.output_snapshot_payload(uuid),
  public.output_job_fail(uuid, text, text, text, boolean),
  public.output_artifact_begin(uuid, text, text, text, text, bigint),
  public.output_artifact_verify(uuid, text, text),
  public.output_artifact_publish(uuid, text),
  public.output_pipeline_maintenance(interval, interval),
  public.output_artifact_download_block(uuid, uuid),
  public.can_read_output_object(text),
  public.output_pipeline_metrics(timestamptz)
  to service_role;

revoke all on function public.request_output_job(uuid, text, text),
  public.request_output_download(uuid),
  public.baby_output_status(uuid),
  public.admin_output_metrics(integer)
  from public, anon;
grant execute on function public.request_output_job(uuid, text, text),
  public.request_output_download(uuid),
  public.baby_output_status(uuid),
  public.admin_output_metrics(integer)
  to authenticated, service_role;

commit;
