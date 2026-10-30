-- =====================================================================
-- Phase 13: legacy data policy, release health, quotas, minimum client
-- version and privilege hardening for the production rollout.
--
--   * Legacy cutoff: content dated after birth + 405 days (only possible for
--     pre-lifecycle legacy data) stays in the read-only archive but is not
--     part of an official snapshot unless a Super Admin records an explicit,
--     reasoned, audited grandfather decision. Nothing is deleted.
--   * admin_legacy_rollout_report: babies locked by the new lifecycle,
--     post-cutoff content, grandfather decisions, legacy book data, orphan
--     baby-media objects (reported, never deleted) and ambiguous family
--     account mappings (reported, never merged).
--   * admin_release_health: the rollout metrics with ok / warn / critical.
--   * Output job quotas per baby + product + day (cost control).
--   * app_config: minimum supported client build (forced, safe upgrade).
--   * The "book ready" reminder now fires when the archive is LOCKED.
--   * anon loses EXECUTE on internal helper / trigger functions.
-- =====================================================================
begin;

-- Settings ------------------------------------------------------------------------------------------
create table public.platform_settings (
  key        text primary key check (key ~ '^[a-z_]{3,60}$'),
  value      jsonb not null,
  note       text,
  updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;
revoke all on table public.platform_settings from public, anon, authenticated;
grant all on table public.platform_settings to service_role;

insert into public.platform_settings (key, value, note) values
  ('client_min_build', '1', 'Phase 13: clients below this build must upgrade before using the app.'),
  ('client_latest_build', '1', 'Phase 13: newest published build (optional upgrade hint).'),
  ('output_daily_quota', '{"first_year_book": 30, "first_year_film": 12, "first_year_html": 6}',
   'Phase 13: output jobs per baby and product in 24 hours.')
on conflict (key) do nothing;

create or replace function public.platform_setting_int(p_key text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value #>> '{}')::integer from public.platform_settings s where s.key = p_key), p_default);
$$;

-- Public, read-only client configuration (also before sign-in).
create or replace function public.app_config()
returns table (min_supported_build integer, latest_build integer)
language sql
stable
security definer
set search_path = ''
as $$
  select public.platform_setting_int('client_min_build', 1), public.platform_setting_int('client_latest_build', 1);
$$;

-- Quotas --------------------------------------------------------------------------------------------
create or replace function public.output_jobs_quota()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_limit integer;
begin
  v_limit := coalesce((select (s.value ->> new.product_code)::integer from public.platform_settings s
                        where s.key = 'output_daily_quota'), 1000);
  if (select count(*) from public.output_jobs j
       where j.baby_id = new.baby_id and j.product_code = new.product_code
         and j.created_at > now() - interval '24 hours') >= v_limit then
    raise exception 'daily output quota reached' using errcode = '55000', hint = 'quota_exceeded';
  end if;
  return new;
end;
$$;

create trigger output_jobs_quota before insert on public.output_jobs
  for each row execute function public.output_jobs_quota();

-- Legacy cutoff ---------------------------------------------------------------------------------------
create table public.legacy_grandfather_decisions (
  id          bigint generated always as identity primary key,
  baby_id     uuid not null references public.babies (id) on delete cascade,
  include     boolean not null,
  reason      text not null check (char_length(btrim(reason)) between 10 and 1000),
  decided_by  uuid references auth.users (id) on delete set null,
  decided_at  timestamptz not null default now()
);
create index legacy_grandfather_decisions_baby_idx on public.legacy_grandfather_decisions (baby_id, decided_at desc);

create trigger legacy_grandfather_decisions_append_only
  before update or delete on public.legacy_grandfather_decisions
  for each row execute function public.output_append_only();

alter table public.legacy_grandfather_decisions enable row level security;
revoke all on table public.legacy_grandfather_decisions from public, anon, authenticated;
grant all on table public.legacy_grandfather_decisions to service_role;

-- Latest decision wins; no decision = cutoff applies.
create or replace function public.legacy_content_included(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select d.include from public.legacy_grandfather_decisions d
                    where d.baby_id = p_baby_id order by d.decided_at desc, d.id desc limit 1), false);
$$;

create or replace function public.admin_set_legacy_grandfather(p_baby_id uuid, p_include boolean, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('write', 20);
  if p_include is null or char_length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'a reason of at least 10 characters is required' using errcode = '22023', hint = 'decision_note_required';
  end if;
  if not exists (select 1 from public.babies b where b.id = p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  insert into public.legacy_grandfather_decisions (baby_id, include, reason, decided_by)
  values (p_baby_id, p_include, btrim(p_reason), auth.uid());
  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
  values (p_baby_id, auth.uid(), case when p_include then 'legacy_grandfathered' else 'legacy_grandfather_revoked' end,
          'baby', p_baby_id, jsonb_build_object('reason', btrim(p_reason)));
  return p_include;
end;
$$;

-- Phase 8 snapshot content with the legacy cutoff (birth + 405 days).
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
  v_cutoff date;
begin
  select * into v_baby from public.babies b where b.id = p_baby_id;
  if v_baby.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select coalesce(max(er.requested_days) filter (where er.status = 'approved'), 0)::integer into v_extension
    from public.baby_extension_requests er where er.baby_id = p_baby_id;
  -- Content dated after the absolute ceiling is legacy: kept, not sealed,
  -- unless a Super Admin grandfathered it.
  v_cutoff := case when public.legacy_content_included(p_baby_id) then 'infinity'::date else v_baby.birth_date + 405 end;

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
       where m.baby_id = p_baby_id and m.achieved_on <= v_cutoff), '[]'::jsonb),
    'memories', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'title', m.title, 'body', m.body, 'memory_date', m.memory_date,
               'memory_time', m.memory_time, 'category', m.category, 'milestone_id', m.milestone_id,
               'include_in_book', m.include_in_book,
               'author', public.archive_snapshot_person(p_baby_id, m.author_id))
             order by m.memory_date, m.memory_time nulls first, m.created_at, m.id)
        from public.memories m
       where m.baby_id = p_baby_id and m.memory_date <= v_cutoff), '[]'::jsonb),
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
       where l.baby_id = p_baby_id and l.written_on <= v_cutoff), '[]'::jsonb),
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
       where m.baby_id = p_baby_id and m.status = 'ready' and m.taken_on <= v_cutoff), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'memory_id', c.memory_id, 'milestone_id', c.milestone_id, 'media_id', c.media_id,
               'body', c.body, 'created_at', public.snapshot_ts(c.created_at),
               'author', public.archive_snapshot_person(p_baby_id, c.author_id))
             order by c.created_at, c.id)
        from public.comments c
       where c.baby_id = p_baby_id
         and (c.memory_id is null or exists (select 1 from public.memories x where x.id = c.memory_id and x.memory_date <= v_cutoff))
         and (c.milestone_id is null or exists (select 1 from public.milestones x where x.id = c.milestone_id and x.achieved_on <= v_cutoff))
         and (c.media_id is null or exists (select 1 from public.media x where x.id = c.media_id and x.taken_on <= v_cutoff))),
      '[]'::jsonb)
  );
end;
$$;

-- Rollout report (Super Admin) -----------------------------------------------------------------------------
create or replace function public.admin_legacy_rollout_report()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform public.assert_admin_console('read', 30);
  with b as (
    select b.id, b.birth_date, coalesce(public.baby_lifecycle_active_internal(b.id), true) as active
      from public.babies b
  ), post as (
    select b.id as baby_id,
           (select count(*) from public.memories m where m.baby_id = b.id and m.memory_date > b.birth_date + 405)
         + (select count(*) from public.milestones m where m.baby_id = b.id and m.achieved_on > b.birth_date + 405)
         + (select count(*) from public.letters l where l.baby_id = b.id and l.written_on > b.birth_date + 405)
         + (select count(*) from public.media m where m.baby_id = b.id and m.taken_on > b.birth_date + 405) as items
      from b
  ), referenced as (
    select m.storage_path as path from public.media m
    union select m.thumb_path from public.media m where m.thumb_path is not null
    union select x.avatar_path from public.babies x where x.avatar_path is not null
    union select x.cover_path from public.babies x where x.cover_path is not null
    union select c.baby_id::text || '/capsules/' || c.id::text || '/photo.jpg' from public.time_capsules c where c.has_photo
  ), orphans as (
    select o.name from storage.objects o
     where o.bucket_id = 'baby-media' and not exists (select 1 from referenced r where r.path = o.name)
  )
  select jsonb_build_object(
    'babies_total', (select count(*) from b),
    'babies_locked', (select count(*) from b where not b.active),
    'babies_locked_ids', coalesce((select jsonb_agg(b.id order by b.id) from b where not b.active), '[]'::jsonb),
    'post_cutoff_content', coalesce((select jsonb_agg(jsonb_build_object('baby_id', p.baby_id, 'items', p.items,
                                                                         'grandfathered', public.legacy_content_included(p.baby_id))
                                                      order by p.baby_id)
                                       from post p where p.items > 0), '[]'::jsonb),
    'legacy_book_projects', (select count(*) from public.book_projects where legacy_status is not null),
    'legacy_book_exports', (select count(*) from public.book_exports where legacy_status is not null),
    'orphan_media_objects', (select count(*) from orphans),
    'orphan_media_sample', coalesce((select jsonb_agg(o.name) from (select name from orphans order by name limit 50) o), '[]'::jsonb),
    'unmapped_babies', coalesce((select jsonb_agg(x.id order by x.id) from public.babies x
                                  where not exists (select 1 from public.family_account_babies f where f.baby_id = x.id)),
                                '[]'::jsonb),
    'users_parent_in_several_accounts', coalesce((
      select jsonb_agg(u.user_id order by u.user_id) from (
        select m.user_id from public.family_account_members m
         where m.role = 'parent' and m.status = 'active'
         group by m.user_id having count(*) > 1) u), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- Release health (Super Admin): metric, value, status ------------------------------------------------------
create or replace function public.admin_release_health()
returns table (check_name text, value numeric, status text, detail text)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v numeric;
  function_status text;
begin
  perform public.assert_admin_console('read', 60);

  -- Lifecycle integrity: data that the lifecycle rules can never produce.
  select count(*) into v from public.babies b
   where b.birth_date > public.business_date_istanbul()
      or (select count(*) from public.baby_extension_requests e where e.baby_id = b.id and e.status = 'approved') > 1
      or exists (select 1 from public.baby_extension_requests e
                  where e.baby_id = b.id and e.status = 'approved' and e.requested_days not between 1 and 30);
  return query select 'lifecycle_mismatch'::text, v, case when v > 0 then 'critical' else 'ok' end, 'babies breaking lifecycle invariants';

  select coalesce(extract(epoch from now() - min(j.created_at)) / 60, 0) into v
    from public.output_jobs j where j.status = 'queued' and j.available_at <= now();
  return query select 'output_queue_age_minutes', round(v, 1),
                      case when v > 120 then 'critical' when v > 30 then 'warn' else 'ok' end, 'oldest claimable job';

  select count(*) into v from public.output_jobs j where j.status = 'poison' and j.finished_at > now() - interval '24 hours';
  return query select 'output_jobs_poison_24h', v, case when v > 10 then 'critical' when v > 3 then 'warn' else 'ok' end,
                      'jobs that ended without retry';

  select count(*) into v from public.output_artifacts a
   where a.status = 'quarantined' and a.failure_code in ('checksum_mismatch', 'size_mismatch', 'object_missing')
     and a.created_at > now() - interval '24 hours';
  return query select 'artifact_checksum_failures_24h', v, case when v > 5 then 'critical' when v > 0 then 'warn' else 'ok' end,
                      'quarantined uploads';

  select count(*) into v from public.output_download_denials d
   where d.requested_at > now() - interval '1 hour' and d.reason not in ('rate_limited');
  return query select 'download_denials_1h', v, case when v > 500 then 'critical' when v > 100 then 'warn' else 'ok' end,
                      'refused download requests';

  select count(*) into v from public.billing_events e where e.result = 'rejected' and e.received_at > now() - interval '24 hours';
  return query select 'payment_webhook_rejections_24h', v, case when v > 20 then 'critical' when v > 5 then 'warn' else 'ok' end,
                      'store events that could not be applied';

  -- Webhook lag proxy: live paid subscriptions but no store event for 48 h.
  select coalesce(extract(epoch from now() - max(e.received_at)) / 3600, 0) into v from public.billing_events e;
  function_status := case
    when exists (select 1 from public.subscriptions s where s.provider in ('app_store', 'google_play')
                   and s.status in ('active', 'grace', 'past_due')) and v > 48 then 'warn' else 'ok' end;
  return query select 'payment_webhook_silence_hours', round(v, 1), function_status, 'hours since the last store event';

  select count(*) into v from public.storage_cleanup_queue q where q.created_at < now() - interval '24 hours';
  return query select 'storage_cleanup_backlog', v, case when v > 1000 then 'warn' else 'ok' end, 'queued deletions older than 24 h';

  select count(*) into v from public.subscriptions s where s.over_capacity;
  return query select 'subscriptions_over_capacity', v, case when v > 0 then 'warn' else 'ok' end, 'downgraded below active members';
end;
$$;

-- Notifications: the reminder now fires when the archive is LOCKED -----------------------------------------
create or replace function public.run_daily_jobs(p_today date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_months integer;
  v_years integer;
  v_count integer := 0;
  v_capsules integer := 0;
begin
  -- 1) month-iversaries (first 24 months) and birthdays
  for r in select b.id, b.first_name, b.birth_date from public.babies b where b.birth_date < p_today loop
    v_months := (extract(year from age(p_today, r.birth_date)) * 12
                 + extract(month from age(p_today, r.birth_date)))::integer;
    if v_months >= 1 and (r.birth_date + make_interval(months => v_months))::date = p_today then
      v_years := v_months / 12;
      if v_months % 12 = 0 then
        perform public.notify_family(r.id, null, 'birthday',
          'Bugün ' || r.first_name || ' ' || v_years || ' yaşında! 🎂',
          'Bu özel günü bir anıyla ölümsüzleştirin.',
          jsonb_build_object('years', v_years), null,
          'birthday:' || r.id::text || ':' || v_years);
      elsif v_months < 24 then
        perform public.notify_family(r.id, null, 'anniversary',
          'Bugün ' || r.first_name || ' ' || v_months || ' aylık oldu ❤️',
          'Bu ayın en güzel anını eklemeye ne dersiniz?',
          jsonb_build_object('months', v_months), null,
          'months:' || r.id::text || ':' || v_months);
      end if;
      v_count := v_count + 1;
    end if;

    -- 2) the archive is complete (LOCKED) -> the digital products open.
    -- Before phase 13 this fired on day 365, while the archive was still
    -- ACTIVE and the book closed.
    if p_today = r.birth_date + 375 + coalesce((
         select er.requested_days::integer from public.baby_extension_requests er
          where er.baby_id = r.id and er.status = 'approved'), 0) then
      perform public.notify_family(r.id, null, 'book_ready',
        public.tr_suffix(r.first_name, 'genitive') || ' İlk Yıl arşivi tamamlandı 📖',
        'Dijital kitap, film ve çevrimdışı arşiv artık hazırlanabilir.',
        '{}'::jsonb, 'create_book', 'book_ready:' || r.id::text);
    end if;
  end loop;

  -- 3) "Bir yıl önce bugün..."
  for r in
    select m.baby_id, min(m.title) as title, count(*) as cnt
    from public.memories m
    where m.memory_date = (p_today - interval '1 year')::date
    group by m.baby_id
  loop
    perform public.notify_family(r.baby_id, null, 'memories_of_the_day',
      'Bir yıl önce bugün... ✨',
      r.title || case when r.cnt > 1 then ' ve ' || (r.cnt - 1) || ' anı daha' else '' end,
      jsonb_build_object('date', (p_today - interval '1 year')::date), 'view_memories',
      'otd:' || r.baby_id::text || ':' || p_today::text);
  end loop;

  -- 4) time capsules that open today
  for r in select c.id, c.baby_id, c.title, b.first_name
           from public.time_capsules c join public.babies b on b.id = c.baby_id
           where c.open_on = p_today loop
    perform public.notify_family(r.baby_id, null, 'time_capsule_opened',
      'Bir zaman kapsülü açıldı! 💫', r.title,
      jsonb_build_object('capsule_id', r.id), 'view_memories', 'capsule:' || r.id::text);
    v_capsules := v_capsules + 1;
  end loop;

  -- 5) housekeeping
  update public.family_invitations set status = 'expired'
   where status = 'pending' and expires_at <= now();
  delete from public.notifications where created_at < now() - interval '180 days';
  -- abandoned uploads (app killed mid-upload and never resumed)
  delete from public.media where status in ('uploading', 'failed') and created_at < now() - interval '3 days';

  return jsonb_build_object('anniversaries', v_count, 'capsules', v_capsules);
end;
$$;

-- Privilege hardening: helpers / trigger functions are not part of the API -------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig,
           p.prorettype = 'trigger'::regtype
             -- internal helpers of definer functions, never called by clients
             or p.proname in ('platform_setting_int', 'legacy_content_included') as is_trigger
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('babies_guard', 'baby_extension_requests_guard', 'book_owner_guard', 'content_date_guard',
                         'content_owner_guard', 'family_invitations_guard', 'family_members_guard',
                         'letters_author_snapshot', 'media_path_guard', 'milestone_types_guard', 'milestones_type_guard',
                         'on_book_exported', 'on_content_created', 'on_invitation_changed', 'on_member_changed',
                         'path_segment', 'path_uuid', 'platform_flags_audit', 'profiles_guard',
                         'queue_book_file_cleanup', 'queue_media_file_cleanup', 'relation_display', 'set_updated_at',
                         'tr_suffix', 'output_jobs_quota', 'platform_setting_int', 'legacy_content_included')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.is_trigger then
      execute format('grant execute on function %s to service_role', f.sig);
    else
      -- Used inside RLS / Storage policies evaluated as the signed-in user.
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
  end loop;
end;
$$;

-- Legal erasure (KVKK) ----------------------------------------------------------------------------------------
-- Deleting a baby (delete_baby_for_user / prepare_account_deletion) used to
-- fail once anything was purchased: orders, entitlements, snapshots and
-- outputs referenced the baby with ON DELETE RESTRICT and their
-- immutability guards refused deletes. Classified retention (plan 3.6):
--   * personal content - sealed snapshots, manifests, output files and
--     their metadata, download audit of those files - is erased; the files
--     are queued for storage-cleanup;
--   * financial records - orders and entitlements - are kept for the legal
--     retention period without the link to the erased baby.
-- The immutability guards still refuse every other delete.
create or replace function public.legal_erasure_active()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(current_setting('bebegimin.legal_erasure', true), '') = 'on';
$$;

alter table public.premium_orders alter column baby_id drop not null;
alter table public.premium_orders drop constraint premium_orders_baby_id_fkey;
alter table public.premium_orders
  add constraint premium_orders_baby_id_fkey foreign key (baby_id) references public.babies (id) on delete set null;
alter table public.product_entitlements alter column baby_id drop not null;
alter table public.product_entitlements drop constraint product_entitlements_baby_id_fkey;
alter table public.product_entitlements
  add constraint product_entitlements_baby_id_fkey foreign key (baby_id) references public.babies (id) on delete set null;

-- Guards keep their insert / update rules; deletes are refused unless the
-- transaction is a legal erasure.
do $$
declare
  t record;
begin
  for t in
    select * from (values
      ('archive_snapshots_seal', 'archive_snapshots', 'archive_snapshots_seal', 'insert or update'),
      ('output_projects_guard', 'output_projects', 'output_projects_guard', 'insert or update'),
      ('output_jobs_guard', 'output_jobs', 'output_jobs_guard', 'insert or update'),
      ('output_job_attempts_guard', 'output_job_attempts', 'output_job_attempts_guard', 'update'),
      ('output_artifacts_guard', 'output_artifacts', 'output_artifacts_guard', 'insert or update'),
      ('output_artifact_downloads_append_only', 'output_artifact_downloads', 'output_append_only', 'update'),
      ('output_download_denials_append_only', 'output_download_denials', 'output_append_only', 'update'),
      ('film_artifact_metadata_append_only', 'film_artifact_metadata', 'output_append_only', 'update'),
      ('html_artifact_metadata_append_only', 'html_artifact_metadata', 'output_append_only', 'update'),
      ('book_render_manifests_seal', 'book_render_manifests', 'book_render_manifests_seal', 'insert or update'),
      ('film_render_manifests_seal', 'film_render_manifests', 'film_render_manifests_seal', 'insert or update'),
      ('legacy_grandfather_decisions_append_only', 'legacy_grandfather_decisions', 'output_append_only', 'update')
    ) v(trigger_name, table_name, function_name, other_events)
  loop
    execute format('drop trigger %I on public.%I', t.trigger_name, t.table_name);
    execute format('create trigger %I before %s on public.%I for each row execute function public.%I()',
                   t.trigger_name, t.other_events, t.table_name, t.function_name);
    execute format('create trigger %I before delete on public.%I for each row when (not public.legal_erasure_active()) '
                   'execute function public.%I()', t.trigger_name || '_delete', t.table_name, t.function_name);
  end loop;
end;
$$;

-- Entitlements: the erasure only nulls baby_id (ON DELETE SET NULL).
drop trigger product_entitlements_guard on public.product_entitlements;
create trigger product_entitlements_guard
  before update or delete on public.product_entitlements
  for each row when (not public.legal_erasure_active())
  execute function public.product_entitlements_guard();

create or replace function public.babies_erase_outputs()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('bebegimin.legal_erasure', 'on', true);
  insert into public.storage_cleanup_queue (bucket_id, path)
  select 'output-artifacts', x.path
    from public.output_artifacts a
   cross join lateral (values (a.storage_path), (a.staging_path)) x(path)
   where a.baby_id = old.id
  on conflict do nothing;
  delete from public.output_download_denials
   where artifact_id in (select a.id from public.output_artifacts a where a.baby_id = old.id);
  delete from public.output_artifact_downloads
   where artifact_id in (select a.id from public.output_artifacts a where a.baby_id = old.id);
  delete from public.film_artifact_metadata
   where artifact_id in (select a.id from public.output_artifacts a where a.baby_id = old.id);
  delete from public.html_artifact_metadata
   where artifact_id in (select a.id from public.output_artifacts a where a.baby_id = old.id);
  delete from public.book_exports where baby_id = old.id;
  delete from public.output_artifacts where baby_id = old.id;
  delete from public.book_render_manifests where baby_id = old.id;
  delete from public.film_render_manifests where baby_id = old.id;
  delete from public.film_job_progress where job_id in (select j.id from public.output_jobs j where j.baby_id = old.id);
  delete from public.output_job_progress where job_id in (select j.id from public.output_jobs j where j.baby_id = old.id);
  delete from public.output_job_attempts where job_id in (select j.id from public.output_jobs j where j.baby_id = old.id);
  delete from public.output_jobs where baby_id = old.id;
  delete from public.output_projects where baby_id = old.id;
  delete from public.archive_snapshots where baby_id = old.id;
  return old;
end;
$$;

create trigger babies_erase_outputs before delete on public.babies
  for each row execute function public.babies_erase_outputs();

revoke all on function public.babies_erase_outputs() from public, anon, authenticated;
revoke all on function public.legal_erasure_active() from public, anon;
grant execute on function public.legal_erasure_active() to authenticated, service_role;

revoke all on function public.admin_set_legacy_grandfather(uuid, boolean, text),
  public.admin_legacy_rollout_report(),
  public.admin_release_health()
  from public, anon;
grant execute on function public.admin_set_legacy_grandfather(uuid, boolean, text),
  public.admin_legacy_rollout_report(),
  public.admin_release_health()
  to authenticated, service_role;

revoke all on function public.app_config() from public;
grant execute on function public.app_config() to anon, authenticated, service_role;

commit;
