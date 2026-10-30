-- Granular permissions and privilege escalation
set role authenticated;

-- teyze: view, add_memory, edit_own_memory, add_photo, comment, write_letter (no video/milestone/book/members)
select tests.login(tests.id('teyze'));
insert into memories (id, baby_id, title, memory_date) values
  ('e1000000-0000-4000-8000-000000000001', tests.id('defne'), 'Teyzenin anısı', current_date - 5);
select tests.eq(tests.count($q$select 1 from memories where id = 'e1000000-0000-4000-8000-000000000001' and author_id = tests.id('teyze')$q$), 1::bigint, 'teyze adds memory, author forced to herself');
insert into memories (id, baby_id, author_id, title, memory_date) values
  ('e1000000-0000-4000-8000-000000000002', tests.id('defne'), tests.id('anne'), 'Sahte yazar', current_date - 5);
select tests.eq(tests.count($q$select 1 from memories where id = 'e1000000-0000-4000-8000-000000000002' and author_id = tests.id('teyze')$q$), 1::bigint, 'author_id cannot be forged');

update memories set title = 'Düzenlendi' where id = 'e1000000-0000-4000-8000-000000000001';
select tests.eq(tests.count($q$select 1 from memories where title = 'Düzenlendi'$q$), 1::bigint, 'teyze edits own memory');
update memories set title = 'hack' where id = 'e0000000-0000-4000-8000-000000000001';
select tests.eq(tests.count($q$select 1 from memories where title = 'hack'$q$), 0::bigint, 'teyze cannot edit mother''s memory');
delete from memories where id = 'e0000000-0000-4000-8000-000000000001';
select tests.eq(tests.count($q$select 1 from memories where id = 'e0000000-0000-4000-8000-000000000001'$q$), 1::bigint, 'teyze cannot delete mother''s memory');

select tests.expect_error($q$insert into milestones (baby_id, milestone_type_id, achieved_on)
  select tests.id('defne'), id, current_date - 3 from milestone_types where key = 'first_snow'$q$, 'row-level security');
select tests.expect_error($q$insert into media (id, baby_id, kind, storage_path, mime_type, taken_on)
  values ('f2000000-0000-4000-8000-000000000001', tests.id('defne'), 'video',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f2000000-0000-4000-8000-000000000001/v.mp4', 'video/mp4', current_date)$q$, 'row-level security');
insert into media (id, baby_id, kind, storage_path, mime_type, taken_on, memory_id)
  values ('f2000000-0000-4000-8000-000000000002', tests.id('defne'), 'photo',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f2000000-0000-4000-8000-000000000002/p.jpg', 'image/jpeg', current_date,
          'e1000000-0000-4000-8000-000000000001');
select tests.eq(tests.count($q$select 1 from media where id = 'f2000000-0000-4000-8000-000000000002' and status = 'uploading'$q$), 1::bigint, 'teyze uploads photo (row starts as uploading)');
select tests.expect_error($q$insert into book_projects (baby_id) values (tests.id('defne'))$q$, 'row-level security');
select tests.expect_error($q$insert into family_invitations (baby_id, relation) values (tests.id('defne'), 'dede')$q$, 'row-level security');
select tests.eq(tests.count('select 1 from family_invitations'), 0::bigint, 'teyze cannot read invitations');
select tests.eq(tests.count('select 1 from activity_logs'), 0::bigint, 'only admins read the activity log');

-- privilege escalation attempts
do $$
declare n integer;
begin
  update family_members set is_admin = true, permissions = '{manage_members}' where user_id = tests.id('teyze');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'teyze escalated herself'; end if;
  update babies set first_name = 'X' where id = tests.id('defne');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'teyze changed baby profile'; end if;
  delete from family_members where user_id = tests.id('anne') and baby_id = tests.id('defne');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'teyze removed the mother'; end if;
end $$;
select tests.eq((select is_admin from family_members where user_id = tests.id('teyze')), false, 'teyze is still not admin');

-- admin (anne) grants add_milestone + manage_members to teyze
select tests.login(tests.id('anne'));
update family_members set permissions = permissions || '{add_milestone,manage_members}'::text[]
 where user_id = tests.id('teyze') and baby_id = tests.id('defne');
select tests.eq(tests.count($q$select 1 from family_members where user_id = tests.id('teyze') and 'add_milestone' = any(permissions)$q$), 1::bigint, 'admin grants permission');
select tests.eq(tests.count('select 1 from activity_logs where action = ''member_updated'''), 1::bigint, 'permission change is audited');
-- admin can edit & delete any content (manage_content implied)
update memories set title = 'Anne düzeltti' where id = 'e1000000-0000-4000-8000-000000000002';
select tests.eq(tests.count($q$select 1 from memories where title = 'Anne düzeltti'$q$), 1::bigint, 'admin edits others content');

select tests.login(tests.id('teyze'));
insert into milestones (baby_id, milestone_type_id, achieved_on)
  select tests.id('defne'), id, current_date - 3 from milestone_types where key = 'first_snow';
select tests.eq(tests.count($q$select 1 from milestones m join milestone_types t on t.id = m.milestone_type_id where t.key = 'first_snow'$q$), 1::bigint, 'granted permission takes effect immediately');
-- a non-admin member manager still cannot touch admins or hand out management rights
select tests.expect_error($q$update family_members set is_admin = false where user_id = tests.id('anne') and baby_id = tests.id('defne')$q$, 'only admins');
select tests.expect_error($q$update family_members set permissions = '{manage_content}' where user_id = tests.id('teyze')$q$, 'own permissions');
-- custom milestone types are bound to the baby
insert into milestone_types (id, baby_id, title, key) values ('a1000000-0000-4000-8000-000000000001', tests.id('defne'), 'İlk bisiklet', 'hack_system_key');
select tests.eq((select key from milestone_types where id = 'a1000000-0000-4000-8000-000000000001'), null::text, 'clients cannot create system milestone types');
select tests.expect_error($q$insert into milestone_types (baby_id, title) values (tests.id('can'), 'x')$q$, 'row-level security');
update milestone_types set title = 'x' where key = 'first_smile';
select tests.eq((select title from milestone_types where key = 'first_smile'), 'İlk gülümsemem', 'system milestone types are read-only');

-- last admin cannot leave / be demoted
select tests.login(tests.id('baska'));
select tests.expect_error($q$delete from family_members where user_id = tests.id('baska')$q$, 'last_admin');
select tests.expect_error($q$update family_members set is_admin = false where user_id = tests.id('baska')$q$, 'last_admin');
-- a regular member can leave by themselves
select tests.login(tests.id('baba'));
delete from family_members where baby_id = tests.id('ege') and user_id = tests.id('baba');
select tests.eq(tests.count($q$select 1 from babies where id = tests.id('ege')$q$), 0::bigint, 'member who left loses access');

reset role;
-- restore
insert into family_members (baby_id, user_id, relation, is_admin, permissions)
  values (tests.id('ege'), tests.id('baba'), 'baba', true, array(select key from permissions));
