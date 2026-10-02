-- media.taken_on follows the content date rule (birth - 310 .. today + 1);
-- legacy rows are reported, never changed.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout(); -- fixture writes run as a trusted (non-user) context
insert into auth.users (id, email) values ('9d100000-0000-4000-8000-000000000001', 'md-anne@example.com');
insert into public.babies (id, first_name, birth_date, created_by) values
  ('9d000000-0000-4000-8000-000000000001', 'Tarih', current_date - 100, '9d100000-0000-4000-8000-000000000001');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('9d000000-0000-4000-8000-000000000001', '9d100000-0000-4000-8000-000000000001', 'anne', true,
   array(select key from public.permissions));

-- New writes ------------------------------------------------------------------------------------
select tests.expect_error(
  $q$insert into public.media (id, baby_id, kind, storage_path, mime_type, taken_on)
     values ('9d200000-0000-4000-8000-000000000001', '9d000000-0000-4000-8000-000000000001', 'photo',
             '9d000000-0000-4000-8000-000000000001/9d200000-0000-4000-8000-000000000001/p.jpg', 'image/jpeg',
             current_date + 30)$q$,
  'date_in_future');
select tests.expect_error(
  $q$insert into public.media (id, baby_id, kind, storage_path, mime_type, taken_on)
     values ('9d200000-0000-4000-8000-000000000002', '9d000000-0000-4000-8000-000000000001', 'photo',
             '9d000000-0000-4000-8000-000000000001/9d200000-0000-4000-8000-000000000002/p.jpg', 'image/jpeg',
             current_date - 100 - 311)$q$,
  'date_before_birth');

insert into public.media (id, baby_id, kind, storage_path, mime_type, taken_on) values
  ('9d200000-0000-4000-8000-000000000003', '9d000000-0000-4000-8000-000000000001', 'photo',
   '9d000000-0000-4000-8000-000000000001/9d200000-0000-4000-8000-000000000003/p.jpg', 'image/jpeg', current_date - 100 - 310),
  ('9d200000-0000-4000-8000-000000000004', '9d000000-0000-4000-8000-000000000001', 'photo',
   '9d000000-0000-4000-8000-000000000001/9d200000-0000-4000-8000-000000000004/p.jpg', 'image/jpeg', current_date);
select tests.eq((select count(*) from public.media where baby_id = '9d000000-0000-4000-8000-000000000001'), 2::bigint,
                'pregnancy photos (birth - 310) and today are accepted');
select tests.expect_error(
  $q$update public.media set taken_on = current_date + 30 where id = '9d200000-0000-4000-8000-000000000004'$q$,
  'date_in_future');

-- Legacy rows: kept, still usable, reported ----------------------------------------------------------
alter table public.media disable trigger media_date_guard;
insert into public.media (id, baby_id, kind, storage_path, mime_type, taken_on, status) values
  ('9d200000-0000-4000-8000-000000000005', '9d000000-0000-4000-8000-000000000001', 'photo',
   '9d000000-0000-4000-8000-000000000001/9d200000-0000-4000-8000-000000000005/p.jpg', 'image/jpeg', date '2035-01-01', 'uploading');
alter table public.media enable trigger media_date_guard;
update public.media set status = 'ready' where id = '9d200000-0000-4000-8000-000000000005';
select tests.eq((select status from public.media where id = '9d200000-0000-4000-8000-000000000005'), 'ready',
                'a legacy row with a wrong date still changes status (the rule runs on taken_on writes only)');

set role authenticated;
select tests.login('9d100000-0000-4000-8000-000000000001');
select tests.expect_error($q$select public.admin_media_date_report()$q$, 'not authorized');
select tests.login(tests.id('baska')); -- Super Admin since the Phase 2 tests
select tests.eq(exists (select 1 from jsonb_array_elements(public.admin_media_date_report() -> 'sample') e
                         where e ->> 'media_id' = '9d200000-0000-4000-8000-000000000005' and e ->> 'reason' = 'date_in_future'),
                true, 'legacy out-of-range media are reported for support');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.media where id = '9d200000-0000-4000-8000-000000000005'), 1::bigint,
                'the report never deletes or changes a row');
