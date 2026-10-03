-- Decision P-1 (2026-10-02): the official outputs hold the content dated
-- before the baby's own effective close date (birth + 375 + approved
-- extension; half-open, at most birth + 405).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values ('a3000000-0000-4000-8000-000000000001', 'cutoff-anne@example.com');
insert into public.babies (id, first_name, birth_date, created_by) values
  ('a3100000-0000-4000-8000-000000000001', 'Uzatmasız', public.business_date_istanbul() - 500, 'a3000000-0000-4000-8000-000000000001'),
  ('a3100000-0000-4000-8000-000000000002', 'Yedi Gün', public.business_date_istanbul() - 500, 'a3000000-0000-4000-8000-000000000001'),
  ('a3100000-0000-4000-8000-000000000003', 'Otuz Gün', public.business_date_istanbul() - 500, 'a3000000-0000-4000-8000-000000000001');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
select b.id, 'a3000000-0000-4000-8000-000000000001', 'anne', true, array(select key from public.permissions)
  from public.babies b where b.id::text like 'a3100000-%';

-- Approved extensions (decided through the trusted decision path).
insert into public.baby_extension_requests (baby_id, requested_by, requested_days) values
  ('a3100000-0000-4000-8000-000000000002', 'a3000000-0000-4000-8000-000000000001', 7),
  ('a3100000-0000-4000-8000-000000000003', 'a3000000-0000-4000-8000-000000000001', 30);
select set_config('app.lifecycle_extension_write', 'on', false);
update public.baby_extension_requests
   set status = 'approved', decided_by = 'a3000000-0000-4000-8000-000000000001', decided_at = now()
 where baby_id in ('a3100000-0000-4000-8000-000000000002', 'a3100000-0000-4000-8000-000000000003');
select set_config('app.lifecycle_extension_write', '', false);

-- The same days for every baby: 374, 375, 381, 404, 405.
insert into public.memories (baby_id, author_id, title, memory_date)
select b.id, 'a3000000-0000-4000-8000-000000000001', 'Gün ' || d, b.birth_date + d
  from public.babies b cross join unnest(array[374, 375, 381, 404, 405]) d
 where b.id::text like 'a3100000-%';
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status)
select x.id, x.baby_id, 'a3000000-0000-4000-8000-000000000001', 'photo', x.baby_id || '/' || x.id || '/p.jpg', 'image/jpeg',
       x.taken_on, 'ready'
  from (select gen_random_uuid() as id, b.id as baby_id, b.birth_date + d as taken_on
          from public.babies b cross join unnest(array[374, 375, 404, 405]) d
         where b.id::text like 'a3100000-%') x;

select tests.eq((select string_agg(m ->> 'title', ',' order by (m ->> 'memory_date')::date)
                   from jsonb_array_elements(public.build_archive_snapshot_content('a3100000-0000-4000-8000-000000000001') -> 'memories') m),
                'Gün 374', 'no extension: day 374 is the last sealed day, day 375 is not');
select tests.eq((select string_agg(m ->> 'title', ',' order by (m ->> 'memory_date')::date)
                   from jsonb_array_elements(public.build_archive_snapshot_content('a3100000-0000-4000-8000-000000000002') -> 'memories') m),
                'Gün 374,Gün 375,Gün 381', '7-day extension: content up to day 381 is sealed');
select tests.eq((select string_agg(m ->> 'title', ',' order by (m ->> 'memory_date')::date)
                   from jsonb_array_elements(public.build_archive_snapshot_content('a3100000-0000-4000-8000-000000000003') -> 'memories') m),
                'Gün 374,Gün 375,Gün 381,Gün 404', '30-day extension: day 404 is sealed, day 405 never');
select tests.eq((select jsonb_array_length(public.build_archive_snapshot_content(b.id) -> 'media')
                   from public.babies b where b.id = 'a3100000-0000-4000-8000-000000000001'),
                1, 'media follow the same cutoff');
select tests.eq((select public.build_archive_snapshot_content('a3100000-0000-4000-8000-000000000003') -> 'lifecycle' ->> 'effective_close_date')::date
                  = (select birth_date + 405 from public.babies where id = 'a3100000-0000-4000-8000-000000000003'),
                true, 'the snapshot states the effective close date it was cut at');
