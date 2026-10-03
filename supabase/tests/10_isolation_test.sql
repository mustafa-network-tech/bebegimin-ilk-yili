-- Family data isolation: nobody can see or touch another family's data.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

set role authenticated;
select tests.login(tests.id('baska'));  -- Deniz, family of Can

select tests.eq(tests.count('select 1 from babies'), 1::bigint, 'stranger sees only own baby');
select tests.eq(tests.count($q$select 1 from babies where id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see Defne');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see memories');
select tests.eq(tests.count($q$select 1 from media where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see media');
select tests.eq(tests.count($q$select 1 from letters where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see letters');
select tests.eq(tests.count($q$select 1 from milestones where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see milestones');
select tests.eq(tests.count($q$select 1 from family_members where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see family');
select tests.eq(tests.count($q$select 1 from comments where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see comments');
select tests.eq(tests.count($q$select 1 from time_capsules where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger cannot see capsules');
select tests.eq(tests.count($q$select 1 from timeline_entries where baby_id = tests.id('defne')$q$), 0::bigint, 'stranger timeline view is filtered');
select tests.eq(tests.count($q$select 1 from profiles where id = tests.id('anne')$q$), 0::bigint, 'stranger cannot read other family profiles');
select tests.eq(tests.count($q$select 1 from family_invitations$q$), 0::bigint, 'stranger cannot list invitations');
select tests.eq(tests.count('select 1 from timeline_entries'), 1::bigint, 'stranger sees own timeline');

-- write attempts into another family
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'hack', current_date)$q$, 'row-level security');
select tests.expect_error($q$insert into letters (baby_id, body) values (tests.id('defne'), 'hack')$q$, 'row-level security');
select tests.expect_error($q$insert into comments (baby_id, memory_id, body) values (tests.id('defne'), 'e0000000-0000-4000-8000-000000000001', 'hack')$q$, 'row-level security');
select tests.expect_error($q$insert into favorites (baby_id, memory_id) values (tests.id('defne'), 'e0000000-0000-4000-8000-000000000001')$q$, 'row-level security');
select tests.expect_error($q$select public.create_time_capsule(tests.id('defne'), 't', 'b', current_date + 10)$q$, 'not allowed');

-- IDOR: attach own media to someone else's memory (composite FK)
select tests.expect_error($q$insert into media (id, baby_id, memory_id, kind, storage_path, mime_type, taken_on)
  values ('f1000000-0000-4000-8000-000000000001', tests.id('can'), 'e0000000-0000-4000-8000-000000000001', 'photo',
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc/f1000000-0000-4000-8000-000000000001/a.jpg', 'image/jpeg', current_date)$q$,
  'foreign key');
-- IDOR: storage path pointing into another baby's folder
select tests.expect_error($q$insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
  values ('f1000000-0000-4000-8000-000000000002', tests.id('can'), 'photo',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f1000000-0000-4000-8000-000000000002/a.jpg', 'image/jpeg', current_date)$q$,
  'storage_path');

-- updates / deletes silently affect 0 rows
select tests.eq(tests.count($q$select 1 from babies where id = tests.id('defne')$q$), 0::bigint, 'precondition');
do $$
declare n integer;
begin
  update memories set title = 'hacked' where baby_id = tests.id('defne');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'stranger updated % memories', n; end if;
  delete from media where baby_id = tests.id('defne');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'stranger deleted % media', n; end if;
  update babies set first_name = 'x' where id = tests.id('defne');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'stranger updated baby'; end if;
  delete from family_members where baby_id = tests.id('defne');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'stranger removed members'; end if;
end $$;

-- storage
select tests.eq(tests.count($q$select 1 where public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg')$q$), 0::bigint, 'stranger cannot sign Defne photo');
select tests.eq(tests.count($q$select 1 where public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/avatar.jpg')$q$), 0::bigint, 'stranger cannot read Defne profile photo');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg')$q$, 'row-level security');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('avatars', '11111111-1111-4111-8111-111111111111/a.jpg')$q$, 'row-level security');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('baby-media', '../aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/x.jpg')$q$, 'row-level security');

-- the family member (teyze) sees Defne but never Can
select tests.login(tests.id('teyze'));
select tests.eq(tests.count($q$select 1 from babies$q$), 1::bigint, 'teyze sees only Defne');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('can')$q$), 0::bigint, 'teyze cannot see Can memories');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('defne')$q$) > 0, true, 'teyze sees Defne memories');
select tests.eq(tests.count($q$select 1 from media where baby_id = tests.id('can')$q$), 0::bigint, 'teyze cannot see Can media');
select tests.eq(tests.count($q$select 1 from profiles$q$), 3::bigint, 'teyze sees Defne family profiles only');

-- anon has no access at all
reset role;
set role anon;
select tests.expect_error('select * from public.babies', 'permission denied');
select tests.expect_error('select * from public.memories', 'permission denied');
select tests.expect_error('select * from public.timeline_entries', 'permission denied');
select tests.expect_error($q$select public.accept_invitation('DEDE2DAVET')$q$, 'permission denied');
reset role;
