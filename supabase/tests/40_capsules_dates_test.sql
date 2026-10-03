-- Time capsules are sealed on the backend; content date rules.
set role authenticated;
select tests.login(tests.id('teyze'));

select tests.eq(tests.count($q$select 1 from time_capsules where baby_id = tests.id('defne')$q$), 2::bigint, 'family sees capsule envelopes');
select tests.eq(tests.count($q$select 1 from time_capsule_contents$q$), 1::bigint, 'only the opened capsule content is readable');
select tests.eq(tests.count($q$select 1 from time_capsule_contents where capsule_id = 'b0000000-0000-4000-8000-000000000001'$q$), 0::bigint, 'sealed 18th-birthday capsule is not readable');

-- even the author cannot read a sealed capsule
select tests.login(tests.id('anne'));
select tests.eq(tests.count($q$select 1 from time_capsule_contents where capsule_id = 'b0000000-0000-4000-8000-000000000001'$q$), 0::bigint, 'author cannot peek either');
select tests.expect_error($q$insert into time_capsule_contents (capsule_id, baby_id, body) values ('b0000000-0000-4000-8000-000000000001', tests.id('defne'), 'x')$q$, 'permission denied');
select tests.expect_error($q$update time_capsule_contents set body = 'x'$q$, 'permission denied');
select tests.expect_error($q$update time_capsules set open_on = current_date$q$, 'permission denied');
select tests.expect_error($q$select public.create_time_capsule(tests.id('defne'), 'Geçmiş', 'x', current_date)$q$, 'open_date_not_future');
select tests.eq((select public.create_time_capsule(tests.id('defne'), '10 yaşında aç', 'Merhaba büyük kız!', current_date + 3000, 'age_10', true) is not null), true, 'create capsule via RPC');
select tests.eq(tests.count($q$select 1 from time_capsule_contents where body = 'Merhaba büyük kız!'$q$), 0::bigint, 'freshly created capsule is sealed');
-- capsule photo: author may upload now, nobody may read until opened
select tests.eq(public.can_write_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/capsules/' ||
  (select id from time_capsules where title = '10 yaşında aç')::text || '/photo.jpg'), true, 'author can upload capsule photo');
select tests.eq(public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/capsules/' ||
  (select id from time_capsules where title = '10 yaşında aç')::text || '/photo.jpg'), false, 'sealed capsule photo cannot be signed');
select tests.eq(public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/capsules/b0000000-0000-4000-8000-000000000002/photo.jpg'), true, 'opened capsule photo can be signed');

-- dates: past-dated memories are allowed (even long after the first year), future ones are not
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Gelecek', current_date + 5)$q$, 'date_in_future');
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Çok eski', current_date - 400 - 400)$q$, 'date_before_birth');
insert into memories (id, baby_id, title, memory_date) values
  ('e3000000-0000-4000-8000-000000000001', tests.id('defne'), 'Hamilelik: ilk tekme', current_date - 400 - 60);
select tests.eq(tests.count($q$select 1 from memories where id = 'e3000000-0000-4000-8000-000000000001'$q$), 1::bigint, 'pregnancy memory accepted');
-- Defne is past her first birthday but inside the 375-day window (see
-- 02_legacy_active_fixture.sql): a forgotten first-year memory can still be
-- added. After the window the archive is locked (70_lifecycle_mutation_lock_test).
insert into memories (id, baby_id, title, memory_date) values
  ('e3000000-0000-4000-8000-000000000002', tests.id('defne'), 'İlk yılın unutulan anısı',
   (select birth_date + 200 from babies where id = tests.id('defne')));
select tests.eq((select memory_date - (select birth_date from babies where id = tests.id('defne')) from memories
                 where id = 'e3000000-0000-4000-8000-000000000002'), 200, 'first-year memory added after the first birthday');
-- uploads keep working in the final days of the active window
insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
  values ('f3000000-0000-4000-8000-000000000001', tests.id('defne'), 'video',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f3000000-0000-4000-8000-000000000001/v.mp4', 'video/mp4', current_date);
select tests.eq(tests.count($q$select 1 from media where id = 'f3000000-0000-4000-8000-000000000001'$q$), 1::bigint, 'video upload after the first birthday, before lock');
-- milestones: one per type per baby
select tests.expect_error($q$insert into milestones (baby_id, milestone_type_id, achieved_on)
  select tests.id('defne'), id, current_date - 50 from milestone_types where key = 'first_steps'$q$, 'duplicate key');
-- a custom type of another baby cannot be used
select tests.expect_error($q$insert into milestones (baby_id, milestone_type_id, achieved_on)
  values (tests.id('ege'), 'a1000000-0000-4000-8000-000000000001', current_date - 1)$q$, 'does not belong');
reset role;
