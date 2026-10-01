-- =====================================================================
-- Phase 10: the first-year film (MP4, at most 600 seconds).
--
--   * Same gate as every premium product: LOCKED baby, parent, live family
--     subscription, active first_year_film entitlement (film_access_block).
--   * Scenes and their durations are computed here, deterministically, from
--     the sealed snapshot + the film project settings (film_compose). The
--     app shows the same numbers (film_plan); there is no second algorithm.
--   * Duration budget: base durations when they fit; proportional
--     compression towards per-scene minimums when they do not; a refusal
--     (film_too_long) when even the minimums exceed 600 s. 600 s is a cap,
--     never a target, and a film is never truncated.
--   * film_request_render freezes the scene manifest per job
--     (film_render_manifests); retries render the same manifest.
--   * The film worker (workers/film, ADR 0004) consumes jobs through the
--     Phase 8 API and these service-only RPCs: film_job_manifest,
--     film_job_progress_update, film_job_media_error, film_artifact_publish
--     (post-render duration / profile validation + metadata).
-- Kill switches: film_renderer (new requests), output_worker (consumption).
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('film_renderer', true, 'Phase 10: parents may request first-year films (off = no new requests; data is kept).')
on conflict (key) do nothing;

-- Labels --------------------------------------------------------------------------------------------
create or replace function public.film_date_tr(p_date date)
returns text
language sql
immutable
set search_path = ''
as $$
  select extract(day from p_date)::integer || ' '
         || (array['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim',
                   'Kasım', 'Aralık'])[extract(month from p_date)::integer]
         || ' ' || extract(year from p_date)::integer;
$$;

-- 0 = before birth, 1 = birth day, 2..13 = month 1..12, 14 = first birthday
-- and later (extension window), 15 = family letters.
create or replace function public.film_chapter(p_birth date, p_date date)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p_date < p_birth then 0
    when p_date = p_birth then 1
    when p_date < (p_birth + interval '1 year')::date
      then 2 + (extract(year from age(p_date, p_birth)) * 12 + extract(month from age(p_date, p_birth)))::integer
    else 14
  end;
$$;

create or replace function public.film_chapter_title(p_chapter integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_chapter
    when 0 then 'Seni beklerken'
    when 1 then 'Doğduğun gün'
    when 14 then 'Bir yaşında'
    when 15 then 'Ailemden sana'
    else (p_chapter - 1)::text || '. Ay'
  end;
$$;

create or replace function public.film_chapter_subtitle(p_birth date, p_chapter integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_chapter = 1 then public.film_date_tr(p_birth)
    when p_chapter between 2 and 13 then
      public.film_date_tr((p_birth + make_interval(months => p_chapter - 2))::date) || ' – '
      || public.film_date_tr((p_birth + make_interval(months => p_chapter - 1))::date - 1)
    when p_chapter = 14 then public.film_date_tr((p_birth + interval '1 year')::date)
  end;
$$;

-- Settings ------------------------------------------------------------------------------------------
create or replace function public.film_settings_normalized(p_settings jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'include_videos', coalesce((p_settings ->> 'include_videos')::boolean, true),
    'include_milestones', coalesce((p_settings ->> 'include_milestones')::boolean, true),
    'include_memory_texts', coalesce((p_settings ->> 'include_memory_texts')::boolean, true),
    'include_letters', coalesce((p_settings ->> 'include_letters')::boolean, true),
    'excluded_ids', coalesce((select jsonb_agg(distinct lower(x) order by lower(x))
                                from jsonb_array_elements_text(coalesce(p_settings -> 'excluded_ids', '[]'::jsonb)) x),
                             '[]'::jsonb),
    'title', nullif(btrim(p_settings ->> 'title'), ''));
$$;

create or replace function public.film_validate_settings(p_settings jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text;
begin
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'invalid film settings' using errcode = '22023';
  end if;
  for v_key in select jsonb_object_keys(p_settings) loop
    if v_key not in ('include_videos', 'include_milestones', 'include_memory_texts', 'include_letters', 'excluded_ids', 'title') then
      raise exception 'invalid film settings: %', v_key using errcode = '22023';
    end if;
    if v_key like 'include_%' and jsonb_typeof(p_settings -> v_key) <> 'boolean' then
      raise exception 'invalid film settings: %', v_key using errcode = '22023';
    end if;
  end loop;
  if p_settings ? 'excluded_ids' and (
       jsonb_typeof(p_settings -> 'excluded_ids') <> 'array'
       or jsonb_array_length(p_settings -> 'excluded_ids') > 10000
       or exists (select 1 from jsonb_array_elements(p_settings -> 'excluded_ids') e
                   where jsonb_typeof(e) <> 'string'
                      or (e #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) then
    raise exception 'invalid film settings: excluded_ids' using errcode = '22023';
  end if;
  if p_settings ? 'title' and jsonb_typeof(p_settings -> 'title') not in ('string', 'null') then
    raise exception 'invalid film settings: title' using errcode = '22023';
  end if;
  if char_length(coalesce(p_settings ->> 'title', '')) > 80 then
    raise exception 'invalid film settings: title' using errcode = '22023';
  end if;
end;
$$;

-- Composition ---------------------------------------------------------------------------------------
-- Content items of the film (no cards). rank_in_kind orders photos / videos
-- of a chapter by importance; film_suggest_settings uses it.
create or replace function public.film_candidates(p_content jsonb, p_settings jsonb)
returns table (chapter integer, sort_date date, kind_order integer, kind text, item_id uuid, base_ms integer,
               min_ms integer, payload jsonb, rank_in_kind integer)
language sql
stable
set search_path = ''
as $$
  with s as (
    select public.film_settings_normalized(p_settings) as v
  ), ex as (
    select array(select jsonb_array_elements_text(s.v -> 'excluded_ids')) as ids from s
  ), b as (
    select (p_content -> 'baby' ->> 'birth_date')::date as birth
  ), items as (
    select public.film_chapter(b.birth, (m ->> 'memory_date')::date) as chapter, (m ->> 'memory_date')::date as sort_date,
           1 as kind_order, 'memory'::text as kind, (m ->> 'id')::uuid as item_id, 3500 as base_ms, 2500 as min_ms,
           jsonb_build_object('title', m ->> 'title', 'text', left(coalesce(m ->> 'body', ''), 240),
                              'subtitle', public.film_date_tr((m ->> 'memory_date')::date)) as payload,
           0 as prio
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'memories', '[]'::jsonb)) m
     where (s.v ->> 'include_memory_texts')::boolean and coalesce((m ->> 'include_in_book')::boolean, true)
       and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select public.film_chapter(b.birth, (m ->> 'achieved_on')::date), (m ->> 'achieved_on')::date, 2, 'milestone',
           (m ->> 'id')::uuid, 3500, 2500,
           jsonb_build_object('title', coalesce(m ->> 'title', 'İlk'), 'text', left(coalesce(m ->> 'description', ''), 200),
                              'subtitle', public.film_date_tr((m ->> 'achieved_on')::date)),
           0
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'milestones', '[]'::jsonb)) m
     where (s.v ->> 'include_milestones')::boolean and coalesce((m ->> 'include_in_book')::boolean, true)
       and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select public.film_chapter(b.birth, (m ->> 'taken_on')::date), (m ->> 'taken_on')::date, 3, 'photo',
           (m ->> 'id')::uuid, 3500, 2000,
           jsonb_build_object('media_id', m ->> 'id', 'storage_path', m ->> 'storage_path',
                              'caption', nullif(btrim(coalesce(m ->> 'caption', '')), ''),
                              'subtitle', public.film_date_tr((m ->> 'taken_on')::date)),
           (case when m ->> 'memory_id' is not null or m ->> 'milestone_id' is not null then 2 else 0 end)
           + (case when nullif(btrim(coalesce(m ->> 'caption', '')), '') is not null then 1 else 0 end)
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'media', '[]'::jsonb)) m
     where m ->> 'kind' = 'photo' and coalesce((m ->> 'include_in_book')::boolean, true)
       and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select public.film_chapter(b.birth, (m ->> 'taken_on')::date), (m ->> 'taken_on')::date, 4, 'video',
           (m ->> 'id')::uuid,
           greatest(least(coalesce((m ->> 'duration_ms')::integer, 5000), 8000), 1000),
           greatest(least(coalesce((m ->> 'duration_ms')::integer, 5000), 3000), 1000),
           jsonb_build_object('media_id', m ->> 'id', 'storage_path', m ->> 'storage_path', 'clip_start_ms', 0,
                              'source_duration_ms', (m ->> 'duration_ms')::integer,
                              'caption', nullif(btrim(coalesce(m ->> 'caption', '')), ''),
                              'subtitle', public.film_date_tr((m ->> 'taken_on')::date)),
           (case when m ->> 'memory_id' is not null or m ->> 'milestone_id' is not null then 2 else 0 end)
           + (case when nullif(btrim(coalesce(m ->> 'caption', '')), '') is not null then 1 else 0 end)
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'media', '[]'::jsonb)) m
     where m ->> 'kind' = 'video' and (s.v ->> 'include_videos')::boolean
       and coalesce((m ->> 'include_in_book')::boolean, true) and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select 15, (l ->> 'written_on')::date, 5, 'letter', (l ->> 'id')::uuid, 6000, 4000,
           jsonb_build_object('title', coalesce(nullif(btrim(coalesce(l ->> 'title', '')), ''), 'Sana bir mektup'),
                              'text', left(coalesce(l ->> 'body', ''), 320),
                              'subtitle', coalesce(nullif(btrim(coalesce(l -> 'author' ->> 'name', '')), ''),
                                                   l -> 'author' ->> 'relation_label', '')),
           0
      from s, ex, jsonb_array_elements(coalesce(p_content -> 'letters', '[]'::jsonb)) l
     where (s.v ->> 'include_letters')::boolean and coalesce((l ->> 'include_in_book')::boolean, true)
       and not (lower(l ->> 'id') = any (ex.ids))
  )
  select i.chapter, i.sort_date, i.kind_order, i.kind, i.item_id, i.base_ms, i.min_ms, i.payload,
         row_number() over (partition by i.chapter, i.kind order by i.prio desc, i.sort_date, i.item_id)::integer
    from items i;
$$;

-- Every scene in film order: title, per chapter a card + its items, end.
create or replace function public.film_scene_rows(p_content jsonb, p_settings jsonb)
returns table (ord bigint, chapter integer, kind text, item_id uuid, base_ms integer, min_ms integer, payload jsonb)
language sql
stable
set search_path = ''
as $$
  with v as (
    select public.film_settings_normalized(p_settings) as s,
           (p_content -> 'baby' ->> 'birth_date')::date as birth,
           p_content -> 'baby' ->> 'first_name' as name
  ), c as (
    select * from public.film_candidates(p_content, p_settings)
  ), rows as (
    select 0 as grp, -1 as chapter, 1 as card, null::date as sort_date, 0 as kind_order, 'title'::text as kind,
           null::uuid as item_id, 4000 as base_ms, 3000 as min_ms,
           jsonb_build_object('title', coalesce(v.s ->> 'title', public.tr_suffix(v.name, 'genitive') || ' İlk Yılı'),
                              'subtitle', public.film_date_tr(v.birth) || ' – '
                                          || public.film_date_tr((v.birth + interval '1 year')::date)) as payload
      from v
    union all
    select 1, k.chapter, 1, null, 0, 'chapter', null, 2500, 1500,
           jsonb_strip_nulls(jsonb_build_object('title', public.film_chapter_title(k.chapter),
                                                'subtitle', public.film_chapter_subtitle(v.birth, k.chapter)))
      from v, (select distinct c.chapter from c) k
    union all
    select 1, c.chapter, 0, c.sort_date, c.kind_order, c.kind, c.item_id, c.base_ms, c.min_ms, c.payload from c
    union all
    select 2, 99, 1, null, 0, 'end', null, 4000, 3000,
           jsonb_build_object('title', 'Seni çok seviyoruz', 'subtitle', v.name)
      from v
  )
  select row_number() over (order by r.grp, r.chapter, r.card desc, r.sort_date nulls first, r.kind_order, r.item_id),
         r.chapter, r.kind, r.item_id, r.base_ms, r.min_ms, r.payload
    from rows r;
$$;

-- The duration budget. Returns the full manifest body (scenes + totals).
create or replace function public.film_compose(p_content jsonb, p_settings jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_max constant bigint := 600000;
  v_base bigint;
  v_min bigint;
  v_factor numeric;
  v_scenes jsonb;
  v_total bigint;
  v_counts jsonb;
begin
  select coalesce(sum(r.base_ms), 0), coalesce(sum(r.min_ms), 0) into v_base, v_min
    from public.film_scene_rows(p_content, p_settings) r;
  if v_base > c_max and v_min <= c_max then
    v_factor := (c_max - v_min)::numeric / (v_base - v_min);
  end if;

  select jsonb_agg(r.payload || jsonb_build_object(
                     'index', r.ord - 1, 'kind', r.kind, 'chapter', r.chapter,
                     'duration_ms', case when v_base <= c_max then r.base_ms
                                         when v_factor is not null then r.min_ms + floor((r.base_ms - r.min_ms) * v_factor)::integer
                                         else r.min_ms end)
                   order by r.ord)
    into v_scenes
    from public.film_scene_rows(p_content, p_settings) r;
  select coalesce(sum((e ->> 'duration_ms')::bigint), 0) into v_total from jsonb_array_elements(v_scenes) e;

  select jsonb_build_object(
           'photos', count(*) filter (where c.kind = 'photo'),
           'videos', count(*) filter (where c.kind = 'video'),
           'memories', count(*) filter (where c.kind = 'memory'),
           'milestones', count(*) filter (where c.kind = 'milestone'),
           'letters', count(*) filter (where c.kind = 'letter'),
           'chapters', count(distinct c.chapter))
    into v_counts
    from public.film_candidates(p_content, p_settings) c;

  return jsonb_build_object(
    'settings', public.film_settings_normalized(p_settings),
    'output', jsonb_build_object('width', 1920, 'height', 1080, 'fps', 30, 'video_codec', 'h264',
                                 'audio_codec', 'aac', 'audio_rate', 48000),
    'max_duration_ms', c_max,
    'base_duration_ms', v_base,
    'min_duration_ms', v_min,
    'total_duration_ms', v_total,
    'over_limit', v_min > c_max,
    'excess_ms', greatest(v_min - c_max, 0),
    'counts', v_counts,
    'scenes', coalesce(v_scenes, '[]'::jsonb));
end;
$$;

create or replace function public.build_film_manifest(p_snapshot_id uuid, p_settings jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snap public.archive_snapshots;
begin
  select * into v_snap from public.archive_snapshots s where s.id = p_snapshot_id;
  if v_snap.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  return public.film_compose(v_snap.content, p_settings) || jsonb_build_object(
    'manifest_version', 1, 'product', 'first_year_film', 'baby_id', v_snap.baby_id,
    'snapshot_id', v_snap.id, 'snapshot_checksum', v_snap.checksum);
end;
$$;

-- Tables --------------------------------------------------------------------------------------------
create table public.film_render_manifests (
  job_id            uuid primary key references public.output_jobs (id) on delete restrict,
  snapshot_id       uuid not null references public.archive_snapshots (id) on delete restrict,
  baby_id           uuid not null,
  content           jsonb not null,
  checksum          text not null check (checksum ~ '^[0-9a-f]{64}$'),
  total_duration_ms integer not null check (total_duration_ms between 1 and 600000),
  created_at        timestamptz not null default now()
);

create or replace function public.film_render_manifests_seal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    raise exception 'film manifests are immutable' using errcode = '42501';
  end if;
  if not exists (select 1 from public.output_jobs j
                  where j.id = new.job_id and j.product_code = 'first_year_film'
                    and j.snapshot_id = new.snapshot_id and j.baby_id = new.baby_id) then
    raise exception 'manifest and film job do not match' using errcode = '23514';
  end if;
  if new.content ->> 'snapshot_id' is distinct from new.snapshot_id::text
     or new.content ->> 'baby_id' is distinct from new.baby_id::text then
    raise exception 'manifest content belongs to another snapshot' using errcode = '23514';
  end if;
  if coalesce((new.content ->> 'over_limit')::boolean, true) then
    raise exception 'film is longer than ten minutes' using errcode = '23514', hint = 'film_too_long';
  end if;
  new.total_duration_ms := (new.content ->> 'total_duration_ms')::integer;
  new.checksum := encode(sha256(convert_to(new.content::text, 'UTF8')), 'hex');
  new.created_at := now();
  return new;
end;
$$;

create trigger film_render_manifests_seal
  before insert or update or delete on public.film_render_manifests
  for each row execute function public.film_render_manifests_seal();

create table public.film_job_progress (
  job_id          uuid primary key references public.output_jobs (id) on delete restrict,
  percent         smallint not null default 0 check (percent between 0 and 100),
  stage           text check (stage is null or stage ~ '^[a-z_]{1,40}$'),
  failure_code    text,
  failed_media_id uuid,
  updated_at      timestamptz not null default now()
);

create table public.film_artifact_metadata (
  artifact_id       uuid primary key references public.output_artifacts (id) on delete restrict,
  job_id            uuid not null references public.output_jobs (id) on delete restrict,
  snapshot_id       uuid not null references public.archive_snapshots (id) on delete restrict,
  manifest_checksum text not null check (manifest_checksum ~ '^[0-9a-f]{64}$'),
  duration_ms       integer not null check (duration_ms between 1 and 600000),
  width             integer not null check (width > 0),
  height            integer not null check (height > 0),
  fps               numeric(6, 3) not null check (fps > 0),
  video_codec       text not null,
  audio_codec       text not null,
  created_at        timestamptz not null default now()
);

create trigger film_artifact_metadata_append_only
  before update or delete on public.film_artifact_metadata
  for each row execute function public.output_append_only();

alter table public.film_render_manifests enable row level security;
alter table public.film_job_progress enable row level security;
alter table public.film_artifact_metadata enable row level security;
revoke all on table public.film_render_manifests, public.film_job_progress, public.film_artifact_metadata
  from public, anon, authenticated;
grant all on table public.film_render_manifests, public.film_job_progress, public.film_artifact_metadata to service_role;

-- Access ----------------------------------------------------------------------------------------------
create or replace function public.film_renderer_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select f.enabled from public.platform_flags f where f.key = 'film_renderer'), true);
$$;

create or replace function public.film_access_block(p_baby_id uuid, p_user uuid default auth.uid())
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
  return public.output_request_block(p_baby_id, 'first_year_film', p_user);
end;
$$;

create or replace function public.film_require_access(p_baby_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_block text;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  v_block := public.film_access_block(p_baby_id, auth.uid());
  if v_block = 'not_parent' then
    raise exception 'only parents can create the film' using errcode = '42501', hint = v_block;
  elsif v_block is not null then
    raise exception 'film is not available' using errcode = '55000', hint = v_block;
  end if;
end;
$$;

create or replace function public.film_project_settings(p_baby_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.film_settings_normalized(coalesce((
    select p.settings from public.output_projects p
     where p.baby_id = p_baby_id and p.product_code = 'first_year_film'
       and p.family_account_id = public.family_account_id_for_baby(p_baby_id)), '{}'::jsonb));
$$;

-- App RPCs --------------------------------------------------------------------------------------------
create or replace function public.film_access_state(p_baby_id uuid)
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
  return query select public.film_access_block(p_baby_id, auth.uid()), public.film_renderer_enabled();
end;
$$;

create or replace function public.film_settings(p_baby_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.film_require_access(p_baby_id);
  return public.film_project_settings(p_baby_id);
end;
$$;

create or replace function public.film_update_settings(p_baby_id uuid, p_settings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings jsonb;
begin
  perform public.film_require_access(p_baby_id);
  perform public.film_validate_settings(p_settings);
  v_settings := public.film_settings_normalized(p_settings);
  insert into public.output_projects (family_account_id, baby_id, product_code, settings, created_by)
  values (public.family_account_id_for_baby(p_baby_id), p_baby_id, 'first_year_film', v_settings, auth.uid())
  on conflict (family_account_id, baby_id, product_code) do update set settings = excluded.settings;
  return v_settings;
end;
$$;

-- Server-computed estimate for the current settings (same algorithm as the
-- render request; the archive is LOCKED, so the live content equals the
-- content a snapshot would seal).
create or replace function public.film_plan(p_baby_id uuid)
returns table (total_duration_ms bigint, base_duration_ms bigint, min_duration_ms bigint, max_duration_ms bigint,
               over_limit boolean, excess_ms bigint, photos integer, videos integer, memories integer,
               milestones integer, letters integer, chapters integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_plan jsonb;
begin
  perform public.film_require_access(p_baby_id);
  v_plan := public.film_compose(public.build_archive_snapshot_content(p_baby_id), public.film_project_settings(p_baby_id));
  return query select (v_plan ->> 'total_duration_ms')::bigint, (v_plan ->> 'base_duration_ms')::bigint,
                      (v_plan ->> 'min_duration_ms')::bigint, (v_plan ->> 'max_duration_ms')::bigint,
                      (v_plan ->> 'over_limit')::boolean, (v_plan ->> 'excess_ms')::bigint,
                      (v_plan -> 'counts' ->> 'photos')::integer, (v_plan -> 'counts' ->> 'videos')::integer,
                      (v_plan -> 'counts' ->> 'memories')::integer, (v_plan -> 'counts' ->> 'milestones')::integer,
                      (v_plan -> 'counts' ->> 'letters')::integer, (v_plan -> 'counts' ->> 'chapters')::integer;
end;
$$;

-- A selection that fits: keep the k most important photos (and k/4 videos)
-- of every chapter, with the largest k whose minimum duration fits. The
-- user's toggles are kept; text scenes are dropped only if photos alone
-- cannot fit. Nothing is saved; the app applies it with film_update_settings.
create or replace function public.film_suggest_settings(p_baby_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_max constant bigint := 600000;
  v_content jsonb;
  v_base jsonb;
  v_try jsonb;
  v_lo integer;
  v_hi integer;
  v_mid integer;
  v_best jsonb;
  v_step integer;
begin
  perform public.film_require_access(p_baby_id);
  v_content := public.build_archive_snapshot_content(p_baby_id);
  v_base := public.film_project_settings(p_baby_id) || jsonb_build_object('excluded_ids', '[]'::jsonb);

  for v_step in 0..3 loop
    if v_step = 1 then v_base := v_base || '{"include_memory_texts": false}'::jsonb; end if;
    if v_step = 2 then v_base := v_base || '{"include_letters": false}'::jsonb; end if;
    if v_step = 3 then v_base := v_base || '{"include_videos": false}'::jsonb; end if;
    if (public.film_compose(v_content, v_base) ->> 'min_duration_ms')::bigint <= c_max then
      return public.film_settings_normalized(v_base);
    end if;
    select coalesce(max(c.rank_in_kind), 0) into v_hi
      from public.film_candidates(v_content, v_base) c where c.kind in ('photo', 'video');
    v_lo := 1;
    v_best := null;
    while v_lo <= v_hi loop
      v_mid := (v_lo + v_hi) / 2;
      v_try := v_base || jsonb_build_object('excluded_ids', coalesce((
        select jsonb_agg(c.item_id::text)
          from public.film_candidates(v_content, v_base) c
         where (c.kind = 'photo' and c.rank_in_kind > v_mid)
            or (c.kind = 'video' and c.rank_in_kind > greatest(ceil(v_mid / 4.0)::integer, 1))), '[]'::jsonb));
      if (public.film_compose(v_content, v_try) ->> 'min_duration_ms')::bigint <= c_max then
        v_best := v_try;
        v_lo := v_mid + 1;
      else
        v_hi := v_mid - 1;
      end if;
    end loop;
    if v_best is not null then
      return public.film_settings_normalized(v_best);
    end if;
  end loop;
  raise exception 'film is longer than ten minutes' using errcode = '55000', hint = 'film_too_long';
end;
$$;

-- Preflight + enqueue. The manifest is frozen with the job; identical
-- requests (same snapshot + settings) join the queued / running job.
create or replace function public.film_request_render(p_baby_id uuid, p_idempotency_key text)
returns table (job_id uuid, job_status text, snapshot_id uuid, total_duration_ms integer, reused boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_account uuid;
  v_project uuid;
  v_snapshot uuid;
  v_manifest jsonb;
  v_checksum text;
  v_job public.output_jobs;
  v_other public.output_jobs;
begin
  perform public.film_require_access(p_baby_id);
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9_-]{8,100}$' then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  if not public.film_renderer_enabled() then
    raise exception 'film rendering is paused' using errcode = '55000', hint = 'film_renderer_disabled';
  end if;

  v_account := public.family_account_id_for_baby(p_baby_id);
  insert into public.output_projects (family_account_id, baby_id, product_code, created_by)
  values (v_account, p_baby_id, 'first_year_film', v_uid)
  on conflict (family_account_id, baby_id, product_code) do nothing;
  select p.id into v_project from public.output_projects p
   where p.family_account_id = v_account and p.baby_id = p_baby_id and p.product_code = 'first_year_film'
   for update;

  select * into v_job from public.output_jobs j where j.project_id = v_project and j.idempotency_key = p_idempotency_key;
  if v_job.id is not null then
    return query select v_job.id, v_job.status, v_job.snapshot_id,
                        (select m.total_duration_ms from public.film_render_manifests m where m.job_id = v_job.id), true;
    return;
  end if;

  v_snapshot := public.output_create_snapshot(p_baby_id, 'first_year_film', v_uid);
  v_manifest := public.build_film_manifest(v_snapshot, public.film_project_settings(p_baby_id));
  if not exists (select 1 from jsonb_array_elements(v_manifest -> 'scenes') e
                  where e ->> 'kind' not in ('title', 'chapter', 'end')) then
    raise exception 'the film has no content' using errcode = '55000', hint = 'film_empty';
  end if;
  if (v_manifest ->> 'over_limit')::boolean then
    raise exception 'film is longer than ten minutes by % ms', v_manifest ->> 'excess_ms'
      using errcode = '55000', hint = 'film_too_long';
  end if;
  v_checksum := encode(sha256(convert_to(v_manifest::text, 'UTF8')), 'hex');

  for v_other in
    select j.* from public.output_jobs j
     where j.project_id = v_project and j.status in ('queued', 'running')
     order by j.created_at
     for update
  loop
    if exists (select 1 from public.film_render_manifests m where m.job_id = v_other.id and m.checksum = v_checksum) then
      return query select v_other.id, v_other.status, v_other.snapshot_id, (v_manifest ->> 'total_duration_ms')::integer, true;
      return;
    end if;
    if v_other.status = 'running' then
      raise exception 'another film render is in progress' using errcode = '55000', hint = 'film_render_in_progress';
    end if;
    -- A waiting job with older settings is replaced by this request.
    perform public.book_cancel_job(v_other, 'superseded');
  end loop;

  insert into public.output_jobs (project_id, snapshot_id, family_account_id, baby_id, product_code, idempotency_key,
                                  requested_by)
  values (v_project, v_snapshot, v_account, p_baby_id, 'first_year_film', p_idempotency_key, v_uid)
  returning * into v_job;
  insert into public.film_render_manifests (job_id, snapshot_id, baby_id, content, checksum, total_duration_ms)
  values (v_job.id, v_snapshot, p_baby_id, v_manifest, repeat('0', 64), 1);
  insert into public.film_job_progress (job_id, stage) values (v_job.id, 'queued');
  return query select v_job.id, v_job.status, v_snapshot, (v_manifest ->> 'total_duration_ms')::integer, false;
end;
$$;

-- Latest film job + latest ready film of the baby. ACTIVE archives return
-- nothing; the download state is evaluated for the caller.
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
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return;
  end if;
  return query
  select j.id, j.status, j.attempts::integer, j.last_error_code, pr.failed_media_id, pr.percent::integer, pr.stage,
         j.created_at, j.updated_at, fm.total_duration_ms, a.id, a.size_bytes, a.sha256, md.duration_ms, md.width,
         md.height, a.ready_at, a.snapshot_id,
         case when a.id is null then null else public.output_artifact_download_block(a.id, auth.uid()) end
    from public.output_projects p
    left join lateral (select * from public.output_jobs j2 where j2.project_id = p.id
                        order by j2.created_at desc limit 1) j on true
    left join public.film_job_progress pr on pr.job_id = j.id
    left join public.film_render_manifests fm on fm.job_id = j.id
    left join lateral (select * from public.output_artifacts a2 where a2.project_id = p.id and a2.status = 'ready'
                        order by a2.ready_at desc limit 1) a on true
    left join public.film_artifact_metadata md on md.artifact_id = a.id
   where p.baby_id = p_baby_id and p.product_code = 'first_year_film'
     and p.family_account_id = public.family_account_id_for_baby(p_baby_id);
end;
$$;

-- Worker RPCs (service role) ----------------------------------------------------------------------------
create or replace function public.film_owned_job(p_job_id uuid, p_worker text)
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
  if v_job.id is null or v_job.product_code <> 'first_year_film' then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker or v_job.lease_expires_at <= now() then
    raise exception 'job lease lost' using errcode = '55000', hint = 'lease_lost';
  end if;
  return v_job;
end;
$$;

create or replace function public.film_job_manifest(p_job_id uuid, p_worker text)
returns table (manifest_content text, manifest_checksum text, snapshot_id uuid, total_duration_ms integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job public.output_jobs := public.film_owned_job(p_job_id, p_worker);
begin
  if not exists (select 1 from public.film_render_manifests m where m.job_id = v_job.id) then
    raise exception 'film job has no manifest' using errcode = 'P0002', hint = 'manifest_missing';
  end if;
  return query select m.content::text, m.checksum, m.snapshot_id, m.total_duration_ms
                 from public.film_render_manifests m where m.job_id = v_job.id;
end;
$$;

create or replace function public.film_job_progress_update(p_job_id uuid, p_worker text, p_percent integer, p_stage text)
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
  insert into public.film_job_progress (job_id, percent, stage, updated_at)
  values (p_job_id, least(greatest(coalesce(p_percent, 0), 0), 100), p_stage, now())
  on conflict (job_id) do update set percent = excluded.percent, stage = excluded.stage, updated_at = now();
  return true;
end;
$$;

-- Deterministic media failures are not retried; the app offers to exclude
-- the reported media and render again.
create or replace function public.film_job_media_error(p_job_id uuid, p_worker text, p_code text, p_media_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.output_jobs;
begin
  if p_code is null or p_code not in ('media_corrupt', 'media_missing', 'media_unsupported') then
    raise exception 'invalid error code' using errcode = '22023';
  end if;
  select * into v_job from public.output_jobs j where j.id = p_job_id for update;
  if v_job.id is null or v_job.status <> 'running' or v_job.lease_owner is distinct from p_worker
     or v_job.lease_expires_at <= now() then
    return 'lease_lost';
  end if;
  insert into public.film_job_progress (job_id, stage, failure_code, failed_media_id, updated_at)
  values (p_job_id, 'failed', p_code, p_media_id, now())
  on conflict (job_id) do update set stage = 'failed', failure_code = excluded.failure_code,
                                     failed_media_id = excluded.failed_media_id, updated_at = now();
  return public.output_job_fail(p_job_id, p_worker, p_code, 'media ' || coalesce(p_media_id::text, '?'), false);
end;
$$;

-- Post-render validation: duration probe (never above 600 s, within 2 s of
-- the manifest), output profile; then publish and store the metadata.
create or replace function public.film_artifact_publish(
  p_artifact_id uuid,
  p_worker text,
  p_duration_ms integer,
  p_width integer,
  p_height integer,
  p_fps numeric,
  p_video_codec text,
  p_audio_codec text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_art public.output_artifacts;
  v_manifest public.film_render_manifests;
  v_code text;
  v_result text;
begin
  select * into v_art from public.output_artifacts a where a.id = p_artifact_id for update;
  if v_art.id is null or v_art.product_code <> 'first_year_film' then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select * into v_manifest from public.film_render_manifests m where m.job_id = v_art.job_id;
  if v_manifest.job_id is null then
    raise exception 'film job has no manifest' using errcode = 'P0002', hint = 'manifest_missing';
  end if;
  perform public.film_owned_job(v_art.job_id, p_worker);

  if p_duration_ms is null or p_duration_ms <= 0 then
    v_code := 'probe_failed';
  elsif p_duration_ms > 600000 then
    v_code := 'duration_exceeded';
  elsif abs(p_duration_ms - v_manifest.total_duration_ms) > 2000 then
    v_code := 'duration_mismatch';
  elsif p_width is distinct from (v_manifest.content -> 'output' ->> 'width')::integer
     or p_height is distinct from (v_manifest.content -> 'output' ->> 'height')::integer
     or p_video_codec is distinct from (v_manifest.content -> 'output' ->> 'video_codec')
     or p_audio_codec is distinct from (v_manifest.content -> 'output' ->> 'audio_codec') then
    v_code := 'profile_mismatch';
  end if;
  if v_code is not null then
    if v_art.status in ('staging', 'verified', 'ready') then
      update public.output_artifacts set status = 'quarantined', failure_code = v_code where id = v_art.id;
    end if;
    perform public.output_job_fail(v_art.job_id, p_worker, v_code, 'film failed post-render validation', false);
    return v_code;
  end if;

  v_result := public.output_artifact_publish(p_artifact_id, p_worker);
  if v_result = 'ready' then
    insert into public.film_artifact_metadata (artifact_id, job_id, snapshot_id, manifest_checksum, duration_ms, width,
                                               height, fps, video_codec, audio_codec)
    values (v_art.id, v_art.job_id, v_art.snapshot_id, v_manifest.checksum, p_duration_ms, p_width, p_height, p_fps,
            p_video_codec, p_audio_codec);
    update public.film_job_progress set percent = 100, stage = 'ready', updated_at = now() where job_id = v_art.job_id;
  end if;
  return v_result;
end;
$$;

-- Grants ------------------------------------------------------------------------------------------------------
revoke all on function public.film_date_tr(date),
  public.film_chapter(date, date),
  public.film_chapter_title(integer),
  public.film_chapter_subtitle(date, integer),
  public.film_settings_normalized(jsonb),
  public.film_validate_settings(jsonb),
  public.film_candidates(jsonb, jsonb),
  public.film_scene_rows(jsonb, jsonb),
  public.film_compose(jsonb, jsonb),
  public.build_film_manifest(uuid, jsonb),
  public.film_render_manifests_seal(),
  public.film_renderer_enabled(),
  public.film_access_block(uuid, uuid),
  public.film_require_access(uuid),
  public.film_project_settings(uuid),
  public.film_owned_job(uuid, text),
  public.film_job_manifest(uuid, text),
  public.film_job_progress_update(uuid, text, integer, text),
  public.film_job_media_error(uuid, text, text, uuid),
  public.film_artifact_publish(uuid, text, integer, integer, integer, numeric, text, text)
  from public, anon, authenticated;
grant execute on function public.film_date_tr(date),
  public.film_chapter(date, date),
  public.film_chapter_title(integer),
  public.film_chapter_subtitle(date, integer),
  public.film_settings_normalized(jsonb),
  public.film_validate_settings(jsonb),
  public.film_candidates(jsonb, jsonb),
  public.film_scene_rows(jsonb, jsonb),
  public.film_compose(jsonb, jsonb),
  public.build_film_manifest(uuid, jsonb),
  public.film_renderer_enabled(),
  public.film_access_block(uuid, uuid),
  public.film_require_access(uuid),
  public.film_project_settings(uuid),
  public.film_owned_job(uuid, text),
  public.film_job_manifest(uuid, text),
  public.film_job_progress_update(uuid, text, integer, text),
  public.film_job_media_error(uuid, text, text, uuid),
  public.film_artifact_publish(uuid, text, integer, integer, integer, numeric, text, text)
  to service_role;

revoke all on function public.film_access_state(uuid),
  public.film_settings(uuid),
  public.film_update_settings(uuid, jsonb),
  public.film_plan(uuid),
  public.film_suggest_settings(uuid),
  public.film_request_render(uuid, text),
  public.film_state(uuid)
  from public, anon;
grant execute on function public.film_access_state(uuid),
  public.film_settings(uuid),
  public.film_update_settings(uuid, jsonb),
  public.film_plan(uuid),
  public.film_suggest_settings(uuid),
  public.film_request_render(uuid, text),
  public.film_state(uuid)
  to authenticated, service_role;

commit;
