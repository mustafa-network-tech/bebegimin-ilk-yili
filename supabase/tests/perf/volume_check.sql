-- Phase 13: query plans and timings at production-like volume.
-- Manual / staging tool, NOT part of run_db_tests.sh. Run on a THROW-AWAY
-- database that already has all migrations:
--   psql -d bebegimin_test -f supabase/tests/perf/volume_check.sql
-- Volume: 2 000 families × 1 baby, 200 media + 50 memories + 20 milestones
-- + 5 letters each (≈ 400 000 media, 100 000 memories).
\set ON_ERROR_STOP 1
\timing on
reset role;
select set_config('request.jwt.claims', '', false);

-- Bulk load without triggers (notifications, guards), then re-enable.
set session_replication_role = replica;
create temp table perf_users as
select gen_random_uuid() as id, g as n from generate_series(1, 2000) g;
insert into auth.users (id, email) select id, 'perf-' || n || '@example.com' from perf_users;
insert into public.profiles (id, display_name) select id, 'Perf ' || n from perf_users on conflict (id) do nothing;
create temp table perf_babies as
select gen_random_uuid() as id, u.id as user_id, u.n from perf_users u;
insert into public.babies (id, first_name, birth_date, created_by)
select b.id, 'Perf' || b.n, public.business_date_istanbul() - (380 + b.n % 30), b.user_id from perf_babies b;
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
select b.id, b.user_id, 'anne', true, '{}' from perf_babies b;
insert into public.memories (id, baby_id, author_id, title, body, memory_date)
select gen_random_uuid(), b.id, b.user_id, 'Anı ' || g, 'Gün güzel geçti ' || g, public.business_date_istanbul() - 380 + g * 7
  from perf_babies b, generate_series(1, 50) g;
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status)
select x.id, x.baby_id, x.user_id, case when x.g % 20 = 0 then 'video' else 'photo' end,
       x.baby_id || '/' || x.id || '/p.jpg', 'image/jpeg', public.business_date_istanbul() - 380 + x.g, 'ready'
  from (select gen_random_uuid() as id, b.id as baby_id, b.user_id, g from perf_babies b, generate_series(1, 200) g) x;
insert into public.milestones (baby_id, milestone_type_id, achieved_on, created_by)
select b.id, t.id, public.business_date_istanbul() - 300 + t.sort_order, b.user_id
  from perf_babies b cross join (select id, sort_order from public.milestone_types where baby_id is null limit 20) t;
insert into public.letters (baby_id, author_id, author_name, author_relation, body, written_on)
select b.id, b.user_id, 'Perf', 'anne', 'Sevgili bebeğim ' || g, public.business_date_istanbul() - 200 + g
  from perf_babies b, generate_series(1, 5) g;
set session_replication_role = origin;
analyze;

select (select id from perf_babies order by n limit 1) as baby, (select user_id from perf_babies order by n limit 1) as usr \gset

\echo '== timeline page (RLS, signed-in parent)'
select tests.login(:'usr');
set role authenticated;
explain (analyze, costs off, timing on, summary on)
select * from public.timeline_entries where baby_id = :'baby' order by entry_date desc limit 50;
reset role;
select tests.logout();

\echo '== snapshot content of one baby (seal input)'
explain (analyze, costs off, summary on) select public.build_archive_snapshot_content(:'baby');

\echo '== film plan of one baby (200 media)'
explain (analyze, costs off, summary on)
select public.film_compose(public.build_archive_snapshot_content(:'baby'), '{}'::jsonb) ->> 'total_duration_ms';

\echo '== lifecycle summary for 2 000 babies'
explain (analyze, costs off, summary on)
select count(*) from public.babies b where coalesce(public.baby_lifecycle_active_internal(b.id), true);

\echo '== daily job over all babies'
explain (analyze, costs off, summary on) select public.run_daily_jobs(public.business_date_istanbul());
