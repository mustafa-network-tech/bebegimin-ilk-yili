-- Phase 3: LOCKED source archives are read-only on every backend write path
-- (REST table writes, SECURITY DEFINER RPCs, Storage), while membership,
-- favorites and privileged legal/service paths keep working.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

-- Fixtures -------------------------------------------------------------------------
-- While Defne is still ACTIVE (02_legacy_active_fixture), teyze starts an upload.
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status)
values ('f7000000-0000-4000-8000-000000000001', tests.id('defne'), tests.id('teyze'), 'photo',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f7000000-0000-4000-8000-000000000001/p.jpg',
        'image/jpeg', current_date, 'uploading');
-- Defne returns to her seed age (400 days) => LOCKED. Ege (120 days) stays ACTIVE.
update public.babies set birth_date = public.business_date_istanbul() - 400 where id = tests.id('defne');
-- teyze joins Ege with view-only permissions (ACTIVE but unauthorised writer).
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
values (tests.id('ege'), tests.id('teyze'), 'teyze', false, '{view_memories,view_album}')
on conflict (baby_id, user_id) do update set is_admin = false, permissions = excluded.permissions;
-- A user with no family at all.
insert into auth.users (id, email) values ('95000000-0000-4000-8000-000000000001', 'yabanci@example.com');
-- Dedicated babies for boundary, extension and birth-date cases.
insert into public.babies (id, first_name, birth_date, created_by) values
  ('92000000-0000-4000-8000-000000000001', 'Sınır', public.business_date_istanbul() - 374, tests.id('anne')),
  ('92000000-0000-4000-8000-000000000002', 'Uzatmalı', public.business_date_istanbul() - 100, tests.id('anne')),
  ('92000000-0000-4000-8000-000000000003', 'Yeni', public.business_date_istanbul() - 30, tests.id('anne'));
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
select b.id, tests.id('anne'), 'anne', true, array(select key from public.permissions)
  from public.babies b where b.id::text like '92000000-0000-4000-8000-%';
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
values ('92000000-0000-4000-8000-000000000003', tests.id('teyze'), 'teyze', false, '{view_memories}');
insert into public.platform_user_roles (user_id, role, granted_by)
values (tests.id('baska'), 'super_admin', tests.id('anne'))
on conflict do nothing;
-- An existing Storage object of a Defne photo (uploaded by anne).
insert into storage.objects (bucket_id, name)
values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg')
on conflict do nothing;
-- A SECURITY DEFINER function that forgets lifecycle checks: the row guard
-- must still stop it.
create or replace function tests.definer_insert_memory(p_baby uuid) returns uuid
language sql security definer set search_path = '' as $$
  insert into public.memories (baby_id, title, memory_date)
  values (p_baby, 'Definer yolu', current_date) returning id;
$$;
grant execute on function tests.definer_insert_memory(uuid) to authenticated;

-- LOCKED Defne: reads stay open -----------------------------------------------------------
set role authenticated;
select tests.login(tests.id('anne'));
select tests.eq((select status from public.baby_lifecycle_summary(tests.id('defne'))), 'LOCKED', 'Defne is LOCKED');
select tests.eq((select status from public.baby_lifecycle_summary(tests.id('ege'))), 'ACTIVE', 'Ege is ACTIVE');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('defne')$q$) > 0, true, 'locked memories are readable');
select tests.eq(tests.count($q$select 1 from timeline_entries where baby_id = tests.id('defne')$q$) > 0, true, 'locked timeline is readable');
select tests.eq(tests.count($q$select 1 from media where baby_id = tests.id('defne') and status = 'ready'$q$) > 0, true, 'locked album is readable');
select tests.eq(public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg'), true, 'locked photo can still be signed');
select tests.expect_error($q$select public.baby_lifecycle_active_internal(tests.id('defne'))$q$, 'permission denied');
select tests.expect_error($q$select public.baby_source_writable(tests.id('defne'))$q$, 'permission denied');

-- LOCKED Defne: every source table write is rejected ---------------------------------------
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Kilitli', current_date)$q$, 'lifecycle');
select tests.expect_error($q$update memories set title = 'x' where id = 'e0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$update memories set include_in_book = false where id = 'e0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$delete from memories where id = 'e0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

select tests.expect_error($q$insert into milestones (baby_id, milestone_type_id, achieved_on)
  select tests.id('defne'), id, current_date - 5 from milestone_types where key = 'first_school_day'$q$, 'lifecycle');
select tests.expect_error($q$update milestones set description = 'x' where id = 'd0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$update milestones set include_in_book = false where id = 'd0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$delete from milestones where id = 'd0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

select tests.expect_error($q$insert into milestone_types (baby_id, title) values (tests.id('defne'), 'Kilitli tip')$q$, 'lifecycle');
select tests.expect_error($q$update milestone_types set title = 'x' where id = 'a1000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$delete from milestone_types where id = 'a1000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

select tests.expect_error($q$insert into letters (baby_id, body) values (tests.id('defne'), 'Kilitli mektup')$q$, 'lifecycle');
select tests.expect_error($q$update letters set body = 'x' where id = 'c0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$delete from letters where id = 'c0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

select tests.expect_error($q$insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
  values ('f7000000-0000-4000-8000-0000000000aa', tests.id('defne'), 'photo',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f7000000-0000-4000-8000-0000000000aa/p.jpg', 'image/jpeg', current_date)$q$, 'lifecycle');
select tests.expect_error($q$update media set caption = 'x' where id = 'f0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$update media set include_in_book = false where id = 'f0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$delete from media where id = 'f0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

select tests.expect_error($q$insert into comments (baby_id, memory_id, body) values (tests.id('defne'), 'e0000000-0000-4000-8000-000000000001', 'Kilitli not')$q$, 'lifecycle');
select tests.expect_error($q$select public.create_time_capsule(tests.id('defne'), 'Kilitli kapsül', 'x', current_date + 100)$q$, 'lifecycle');
select tests.expect_error($q$delete from time_capsules where id = 'b0000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

select tests.expect_error($q$update babies set story = 'Yeni hikâye' where id = tests.id('defne')$q$, 'lifecycle');
select tests.expect_error($q$update babies set first_name = 'Başka' where id = tests.id('defne')$q$, 'lifecycle');
select tests.expect_error($q$update babies set avatar_path = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/new.jpg' where id = tests.id('defne')$q$, 'lifecycle');
select tests.expect_error($q$update babies set birth_date = birth_date + 100 where id = tests.id('defne')$q$, 'birth_date_rpc_only');

-- comment authors are locked too
select tests.login(tests.id('teyze'));
select tests.expect_error($q$update comments set body = 'x' where baby_id = tests.id('defne') and author_id = tests.id('teyze')$q$, 'lifecycle');
select tests.expect_error($q$delete from comments where baby_id = tests.id('defne') and author_id = tests.id('teyze')$q$, 'lifecycle');

-- A half-finished upload can neither write its file nor be finalised after the lock.
select tests.eq(public.can_write_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f7000000-0000-4000-8000-000000000001/p.jpg'), false, 'pending upload cannot write its file after lock');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f7000000-0000-4000-8000-000000000001/p.jpg')$q$, 'row-level security');
select tests.expect_error($q$update media set status = 'ready' where id = 'f7000000-0000-4000-8000-000000000001'$q$, 'lifecycle');

-- Storage: no new, replaced or deleted source objects.
select tests.login(tests.id('anne'));
select tests.eq(public.can_write_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/avatar-9.jpg'), false, 'no profile upload for LOCKED baby');
select tests.eq(public.can_delete_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/avatar-9.jpg'), false, 'no profile delete for LOCKED baby');
select tests.eq(public.can_delete_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg'), false, 'no media file delete for LOCKED baby');
select tests.eq(public.can_write_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/capsules/b0000000-0000-4000-8000-000000000001/photo.jpg'), false, 'no capsule photo upload for LOCKED baby');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/x.jpg')$q$, 'row-level security');
do $$
declare n integer;
begin
  update storage.objects set metadata = '{"x": 1}'
   where name = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'locked object was replaced'; end if;
  delete from storage.objects
   where name = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'locked object was deleted'; end if;
  raise notice 'ok - locked Storage objects cannot be replaced or deleted';
end $$;

-- SECURITY DEFINER functions cannot bypass the row guard.
select tests.expect_error($q$select tests.definer_insert_memory(tests.id('defne'))$q$, 'lifecycle');
select tests.eq((select tests.definer_insert_memory(tests.id('ege')) is not null), true, 'definer path still works for ACTIVE baby');

-- Non-members get the RLS answer, never a lifecycle hint about a foreign baby.
select tests.login('95000000-0000-4000-8000-000000000001');
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Yabancı', current_date)$q$, 'row-level security');

-- Not part of the lock: favorites and family management ------------------------------------
select tests.login(tests.id('anne'));
delete from favorites where memory_id = 'e0000000-0000-4000-8000-00000000000a';
insert into favorites (baby_id, memory_id) values (tests.id('defne'), 'e0000000-0000-4000-8000-00000000000a');
select tests.eq(tests.count($q$select 1 from favorites where memory_id = 'e0000000-0000-4000-8000-00000000000a'$q$), 1::bigint, 'favorites work on LOCKED baby');
delete from favorites where memory_id = 'e0000000-0000-4000-8000-00000000000a';
select tests.eq(tests.count($q$select 1 from favorites where memory_id = 'e0000000-0000-4000-8000-00000000000a'$q$), 0::bigint, 'unfavorite works on LOCKED baby');
update family_members set permissions = permissions || '{view_album}'::text[]
 where baby_id = tests.id('defne') and user_id = tests.id('teyze');
select tests.eq((select 'view_album' = any (permissions) from family_members
                  where baby_id = tests.id('defne') and user_id = tests.id('teyze')), true, 'member permissions editable on LOCKED baby');
insert into family_invitations (baby_id, relation) values (tests.id('defne'), 'dayi');
select tests.eq(tests.count($q$select 1 from family_invitations where baby_id = tests.id('defne') and relation = 'dayi'$q$) > 0, true, 'invitations work on LOCKED baby');

-- ACTIVE Ege: authorised writes succeed and stay in Ege ---------------------------------------
insert into memories (id, baby_id, title, memory_date)
values ('e7000000-0000-4000-8000-000000000001', tests.id('ege'), 'Ege aktif', current_date);
update memories set title = 'Ege aktif (düzenlendi)' where id = 'e7000000-0000-4000-8000-000000000001';
insert into comments (baby_id, memory_id, body) values (tests.id('ege'), 'e7000000-0000-4000-8000-000000000001', 'Not');
insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
values ('f7000000-0000-4000-8000-000000000002', tests.id('ege'), 'photo',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-000000000002/p.jpg', 'image/jpeg', current_date);
select tests.eq(public.can_write_baby_object('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-000000000002/p.jpg'), true, 'ACTIVE upload may write its file');
insert into storage.objects (bucket_id, name) values ('baby-media', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-000000000002/p.jpg');
update media set status = 'ready' where id = 'f7000000-0000-4000-8000-000000000002';
select tests.eq(public.can_write_baby_object('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-000000000002/p.jpg'), false, 'finalised file cannot be overwritten');
select tests.eq(public.can_write_baby_object('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/profile/avatar-1.jpg'), true, 'ACTIVE profile upload allowed');
update babies set story = 'Ege''nin hikâyesi' where id = tests.id('ege');
select tests.eq((select story from babies where id = tests.id('ege')), 'Ege''nin hikâyesi', 'ACTIVE profile editable');
select tests.eq(tests.count($q$select 1 from memories where id = 'e7000000-0000-4000-8000-000000000001' and baby_id = tests.id('defne')$q$), 0::bigint, 'Ege write never lands in Defne');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('defne') and title like 'Ege%'$q$), 0::bigint, 'Defne list unaffected by Ege writes');

-- baby_id swaps and cross-baby parents are rejected.
select tests.expect_error($q$update memories set baby_id = tests.id('defne') where id = 'e7000000-0000-4000-8000-000000000001'$q$, 'lifecycle');
select tests.expect_error($q$update memories set baby_id = '92000000-0000-4000-8000-000000000002' where id = 'e7000000-0000-4000-8000-000000000001'$q$, 'immutable');
select tests.expect_error($q$insert into comments (baby_id, memory_id, body) values (tests.id('ege'), 'e0000000-0000-4000-8000-000000000001', 'x')$q$, 'foreign key');
select tests.expect_error($q$insert into media (id, baby_id, memory_id, kind, storage_path, mime_type, taken_on)
  values ('f7000000-0000-4000-8000-0000000000ab', tests.id('ege'), 'e0000000-0000-4000-8000-000000000001', 'photo',
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-0000000000ab/p.jpg', 'image/jpeg', current_date)$q$, 'foreign key');

-- Deleting ACTIVE media removes the row first; its files are queued for cleanup.
delete from media where id = 'f7000000-0000-4000-8000-000000000002';
delete from memories where id = 'e7000000-0000-4000-8000-000000000001';
select tests.eq(tests.count($q$select 1 from memories where id = 'e7000000-0000-4000-8000-000000000001'$q$), 0::bigint, 'ACTIVE delete works');

-- ACTIVE but unauthorised: teyze is view-only on Ege, baska is a stranger.
select tests.login(tests.id('teyze'));
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values (tests.id('ege'), 'x', current_date)$q$, 'row-level security');
select tests.expect_error($q$insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
  values ('f7000000-0000-4000-8000-0000000000ac', tests.id('ege'), 'photo',
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-0000000000ac/p.jpg', 'image/jpeg', current_date)$q$, 'row-level security');
select tests.eq(public.can_write_baby_object('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/profile/avatar-2.jpg'), false, 'view-only member cannot upload profile image');
select tests.login('95000000-0000-4000-8000-000000000001');
select tests.expect_error($q$insert into letters (baby_id, body) values (tests.id('ege'), 'x')$q$, 'row-level security');

reset role;
select tests.logout();
select tests.eq((select count(*) from storage_cleanup_queue
                  where path = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/f7000000-0000-4000-8000-000000000002/p.jpg'), 1::bigint,
                'deleted media file queued for cleanup');

-- Close boundary and approved extension ------------------------------------------------------
set role authenticated;
select tests.login(tests.id('anne'));
insert into memories (baby_id, title, memory_date) values ('92000000-0000-4000-8000-000000000001', 'Son gün', current_date);
select tests.eq(tests.count($q$select 1 from memories where baby_id = '92000000-0000-4000-8000-000000000001'$q$), 1::bigint, '+374 is writable');
insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
values ('f7000000-0000-4000-8000-000000000003', '92000000-0000-4000-8000-000000000001', 'photo',
        '92000000-0000-4000-8000-000000000001/f7000000-0000-4000-8000-000000000003/p.jpg', 'image/jpeg', current_date);
select public.request_baby_extension('92000000-0000-4000-8000-000000000002', 30) as ext_request \gset
select tests.login(tests.id('baska'));
select public.decide_baby_extension(:'ext_request', 'approved', 'Faz 3 testi');

reset role;
select tests.logout();
update public.babies set birth_date = public.business_date_istanbul() - 375 where id = '92000000-0000-4000-8000-000000000001';
update public.babies set birth_date = public.business_date_istanbul() - 404 where id = '92000000-0000-4000-8000-000000000002';

set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values ('92000000-0000-4000-8000-000000000001', 'Kapanış', current_date)$q$, 'lifecycle');
select tests.expect_error($q$update media set status = 'ready' where id = 'f7000000-0000-4000-8000-000000000003'$q$, 'lifecycle');
insert into memories (baby_id, title, memory_date) values ('92000000-0000-4000-8000-000000000002', 'Ek süre', current_date);
select tests.eq(tests.count($q$select 1 from memories where baby_id = '92000000-0000-4000-8000-000000000002'$q$), 1::bigint, 'approved extension keeps the archive writable (+404)');

reset role;
select tests.logout();
update public.babies set birth_date = public.business_date_istanbul() - 405 where id = '92000000-0000-4000-8000-000000000002';
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values ('92000000-0000-4000-8000-000000000002', 'Tavan', current_date)$q$, 'lifecycle');

-- Quarantine of half-finished uploads -------------------------------------------------------
reset role;
select tests.logout();
begin;
set local role service_role;
select (public.run_baby_lifecycle_jobs() ->> 'quarantined_uploads')::integer as quarantined \gset
commit;
select tests.eq(:quarantined >= 2, true, 'lifecycle job quarantines uploads of locked babies');
select tests.eq((select status from media where id = 'f7000000-0000-4000-8000-000000000001'), 'failed', 'Defne pending upload quarantined');
select tests.eq((select status from media where id = 'f7000000-0000-4000-8000-000000000003'), 'failed', 'boundary pending upload quarantined');
begin;
set local role service_role;
select (public.run_baby_lifecycle_jobs() ->> 'quarantined_uploads')::integer as quarantined_again \gset
commit;
select tests.eq(:quarantined_again, 0, 'quarantine is idempotent');
select tests.eq((select count(*) from activity_logs where action = 'upload_quarantined'
                  and target_id = 'f7000000-0000-4000-8000-000000000001'), 1::bigint, 'quarantine is audited once');
-- stale failed uploads of a locked baby are deleted and their files queued
begin;
set local role service_role;
update media set created_at = now() - interval '4 days' where id = 'f7000000-0000-4000-8000-000000000001';
select public.run_daily_jobs();
select tests.eq((select count(*) from media where id = 'f7000000-0000-4000-8000-000000000001'), 0::bigint, 'daily job removes quarantined upload of LOCKED baby');
select tests.eq((select count(*) from storage_cleanup_queue
                  where path = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f7000000-0000-4000-8000-000000000001/p.jpg'), 1::bigint,
                'quarantined file queued for cleanup');
rollback;

-- Legal deletion and account cascades are not blocked by the lock ----------------------------
begin;
set local role service_role;
select count(*) from public.prepare_account_deletion(tests.id('teyze'), true);
select tests.eq((select count(*) from memories where author_id = tests.id('teyze') and baby_id = tests.id('defne')), 0::bigint,
                'KVKK content deletion works on LOCKED archive');
rollback;
begin;
set local role service_role;
select tests.eq((select count(*) from public.delete_baby_for_user(tests.id('anne'), tests.id('defne'))) > 0, true, 'LOCKED baby can be deleted by its admin');
select tests.eq((select count(*) from memories where baby_id = tests.id('defne')), 0::bigint, 'LOCKED baby deletion cascades');
rollback;
begin;
delete from auth.users where id = tests.id('teyze');
select tests.eq((select count(*) from memories where baby_id = tests.id('defne') and author_id is null) > 0, true,
                'account deletion anonymises authors in LOCKED archive');
rollback;

-- Birth date correction (plan 3.5) -------------------------------------------------------------
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$update babies set birth_date = birth_date - 1 where id = tests.id('ege')$q$, 'birth_date_rpc_only');
select birth_date as ege_birth from babies where id = tests.id('ege') \gset
select tests.expect_error(
  format('select public.correct_baby_birth_date(%L, %L)', tests.id('ege'), :'ege_birth'::date - 1),
  'birth_date_requires_admin');
select tests.eq(
  public.correct_baby_birth_date('92000000-0000-4000-8000-000000000003', public.business_date_istanbul() - 31),
  public.business_date_istanbul() - 31,
  'parent corrects birth date before any content');
select tests.eq(tests.count($q$select 1 from activity_logs where baby_id = '92000000-0000-4000-8000-000000000003'
                               and action = 'birth_date_corrected' and details ->> 'actor_role' = 'parent'$q$), 1::bigint,
                'parent correction is audited');
select tests.expect_error(
  format('select public.correct_baby_birth_date(%L, %L)', tests.id('defne'), public.business_date_istanbul() - 300),
  'lifecycle');
select tests.login(tests.id('teyze'));
select tests.expect_error(
  format('select public.correct_baby_birth_date(%L, %L)', '92000000-0000-4000-8000-000000000003', public.business_date_istanbul() - 32),
  'not authorized');
select tests.login(tests.id('baba'));
select tests.expect_error(
  format('select public.correct_baby_birth_date(%L, %L)', '92000000-0000-4000-8000-000000000003', public.business_date_istanbul() - 32),
  'not found');

select tests.login(tests.id('baska'));
select tests.expect_error(
  format('select public.correct_baby_birth_date(%L, %L)', tests.id('ege'), :'ege_birth'::date - 1),
  'birth_date_reason_required');
select tests.eq(
  public.correct_baby_birth_date(tests.id('ege'), :'ege_birth'::date - 1, 'Nüfus kaydı düzeltmesi'),
  :'ege_birth'::date - 1,
  'super admin corrects birth date with a reason');
select tests.login(tests.id('anne')); -- activity log is readable by baby admins
select tests.eq((select (details ->> 'birth_date_before')::date from activity_logs
                  where baby_id = tests.id('ege') and action = 'birth_date_corrected'
                  order by id desc limit 1), :'ege_birth'::date, 'audit keeps the previous birth date');
select tests.login(tests.id('baska'));
select tests.eq((select count(*) from baby_extension_requests where baby_id = tests.id('ege')), 1::bigint,
                'correction creates no new extension right');
select tests.expect_error(
  format('select public.correct_baby_birth_date(%L, %L, %L)', tests.id('defne'), public.business_date_istanbul() - 300, 'Hastane kaydı'),
  'reopen_confirmation_required');
select tests.eq((select status from public.baby_lifecycle_summary(tests.id('defne'))), 'LOCKED', 'unconfirmed reopen leaves profile LOCKED');
begin;
select public.correct_baby_birth_date(tests.id('defne'), public.business_date_istanbul() - 300, 'Hastane kaydı', true);
select tests.eq((select status from public.baby_lifecycle_summary(tests.id('defne'))), 'ACTIVE', 'confirmed reopen is possible for Super Admin');
select tests.login(tests.id('anne'));
select tests.eq(tests.count($q$select 1 from activity_logs where baby_id = tests.id('defne') and action = 'lifecycle_reopened'$q$), 1::bigint,
                'reopen is logged as a security event');
rollback;

-- Kill switch: trusted, audited and invisible to clients -----------------------------------------
select tests.login(tests.id('anne'));
select tests.expect_error($q$update platform_flags set enabled = false$q$, 'permission denied');
reset role;
select tests.logout();
begin;
update public.platform_flags set enabled = false, note = 'Faz 3 testi' where key = 'lifecycle_write_lock';
select tests.eq((select count(*) from public.platform_flag_events where key = 'lifecycle_write_lock' and new_value = false), 1::bigint, 'flag change is audited');
set local role authenticated;
select tests.login(tests.id('anne'));
insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Acil durum', current_date);
select tests.eq(tests.count($q$select 1 from memories where title = 'Acil durum'$q$), 1::bigint, 'kill switch lifts the lock');
rollback;

select tests.logout();
reset role;
