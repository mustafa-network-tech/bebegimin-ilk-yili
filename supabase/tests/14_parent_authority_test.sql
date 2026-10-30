-- Parent authority (decisions P-3, P-5, P-8, P-9, P-10 of 2026-10-02).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout(); -- fixture writes run as a trusted (non-user) context
insert into auth.users (id, email) values
  ('9f100000-0000-4000-8000-000000000001', 'pa-anne@example.com'),
  ('9f100000-0000-4000-8000-000000000002', 'pa-baba@example.com'),
  ('9f100000-0000-4000-8000-000000000003', 'pa-teyze@example.com'),
  ('9f100000-0000-4000-8000-000000000004', 'pa-dayi@example.com'),
  ('9f100000-0000-4000-8000-000000000005', 'pa-tek-anne@example.com'),
  ('9f100000-0000-4000-8000-000000000006', 'pa-eski-anne@example.com'),
  ('9f100000-0000-4000-8000-000000000007', 'pa-eski-baba@example.com'),
  ('9f100000-0000-4000-8000-000000000008', 'pa-eski-dede@example.com'),
  ('9f100000-0000-4000-8000-000000000009', 'pa-yeni@example.com');

insert into public.babies (id, first_name, birth_date, created_by) values
  ('9f000000-0000-4000-8000-000000000001', 'İkiEbeveyn', public.business_date_istanbul() - 100, '9f100000-0000-4000-8000-000000000001'),
  ('9f000000-0000-4000-8000-000000000002', 'Ayrılan', public.business_date_istanbul() - 100, '9f100000-0000-4000-8000-000000000001'),
  ('9f000000-0000-4000-8000-000000000003', 'TekEbeveyn', public.business_date_istanbul() - 100, '9f100000-0000-4000-8000-000000000005'),
  ('9f000000-0000-4000-8000-000000000004', 'EskiBaba', public.business_date_istanbul() - 100, '9f100000-0000-4000-8000-000000000006'),
  ('9f000000-0000-4000-8000-000000000005', 'EskiDede', public.business_date_istanbul() - 100, '9f100000-0000-4000-8000-000000000006');

insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  -- Two parents + a teyze + a dayı who may manage and invite members (not an admin).
  ('9f000000-0000-4000-8000-000000000001', '9f100000-0000-4000-8000-000000000001', 'anne', true, array(select key from public.permissions)),
  ('9f000000-0000-4000-8000-000000000001', '9f100000-0000-4000-8000-000000000002', 'baba', true, array(select key from public.permissions)),
  ('9f000000-0000-4000-8000-000000000001', '9f100000-0000-4000-8000-000000000003', 'teyze', false, '{view_memories}'),
  ('9f000000-0000-4000-8000-000000000001', '9f100000-0000-4000-8000-000000000004', 'dayi', false,
   '{invite_members,manage_members,view_memories}'),
  -- Baba leaves this one himself.
  ('9f000000-0000-4000-8000-000000000002', '9f100000-0000-4000-8000-000000000001', 'anne', true, array(select key from public.permissions)),
  ('9f000000-0000-4000-8000-000000000002', '9f100000-0000-4000-8000-000000000002', 'baba', true, array(select key from public.permissions)),
  -- A single parent with a relative.
  ('9f000000-0000-4000-8000-000000000003', '9f100000-0000-4000-8000-000000000005', 'anne', true, array(select key from public.permissions)),
  ('9f000000-0000-4000-8000-000000000003', '9f100000-0000-4000-8000-000000000003', 'teyze', false, '{view_memories}'),
  -- Legacy: Baba joined without admin rights.
  ('9f000000-0000-4000-8000-000000000004', '9f100000-0000-4000-8000-000000000006', 'anne', true, array(select key from public.permissions)),
  ('9f000000-0000-4000-8000-000000000004', '9f100000-0000-4000-8000-000000000007', 'baba', false, '{view_memories}'),
  ('9f000000-0000-4000-8000-000000000005', '9f100000-0000-4000-8000-000000000006', 'anne', true, array(select key from public.permissions));
-- Legacy: a non-parent admin (P-5 makes this impossible to create today).
alter table public.family_members disable trigger family_members_parent_guard;
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('9f000000-0000-4000-8000-000000000005', '9f100000-0000-4000-8000-000000000008', 'dede', true, array(select key from public.permissions));
alter table public.family_members enable trigger family_members_parent_guard;

set role authenticated;

-- P-5: only Anne / Baba can be admins ----------------------------------------------------------------
select tests.login('9f100000-0000-4000-8000-000000000001');
select tests.expect_error(
  $q$update public.family_members set is_admin = true
      where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000003'$q$,
  'admin_requires_parent');
select tests.expect_error(
  $q$insert into public.family_invitations (baby_id, relation, is_admin)
     values ('9f000000-0000-4000-8000-000000000001', 'teyze', true)$q$,
  'admin_requires_parent');
select tests.expect_error(
  $q$select public.add_member_from_sibling('9f000000-0000-4000-8000-000000000002', '9f100000-0000-4000-8000-000000000003',
                                           'teyze', null, '{view_memories}', true)$q$,
  'admin_requires_parent');

select tests.login('9f100000-0000-4000-8000-000000000009');
select tests.expect_error(
  $q$select public.create_baby('Teyzenin', public.business_date_istanbul() - 5, 'teyze')$q$,
  'admin_requires_parent');
select tests.eq((select first_name from public.create_baby('Annenin', public.business_date_istanbul() - 5, 'anne')),
                'Annenin', 'Anne can create a baby and becomes its admin');

-- P-8: a parent seat is filled only through a parent --------------------------------------------------
select tests.login('9f100000-0000-4000-8000-000000000004');
select tests.expect_error(
  $q$insert into public.family_invitations (baby_id, relation, permissions)
     values ('9f000000-0000-4000-8000-000000000001', 'baba', '{view_memories}')$q$,
  'not_parent');
select tests.expect_error(
  $q$update public.family_members set relation = 'anne'
      where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000003'$q$,
  'not_parent');
select tests.eq((select count(*) from public.family_invitations where baby_id = '9f000000-0000-4000-8000-000000000001'),
                0::bigint, 'refused parent invitations are not stored');

select tests.login('9f100000-0000-4000-8000-000000000005');
insert into public.family_invitations (baby_id, relation, is_admin)
values ('9f000000-0000-4000-8000-000000000003', 'baba', true);
select tests.eq((select count(*) from public.family_invitations
                  where baby_id = '9f000000-0000-4000-8000-000000000003' and relation = 'baba'),
                1::bigint, 'the remaining parent can invite the other parent back');

-- P-9: no parent removes or demotes the other parent --------------------------------------------------
select tests.login('9f100000-0000-4000-8000-000000000001');
select tests.expect_error(
  $q$delete from public.family_members
      where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000002'$q$,
  'parent_protected');
select tests.expect_error(
  $q$update public.family_members set is_admin = false
      where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000002'$q$,
  'parent_protected');
select tests.expect_error(
  $q$update public.family_members set relation = 'amca'
      where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000002'$q$,
  'parent_protected');
-- Ordinary member management still works.
update public.family_members set permissions = '{view_memories,comment}'
 where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000003';
select tests.eq((select permissions from public.family_members
                  where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000003'),
                '{comment,view_memories}'::text[], 'a parent still manages relatives');

select tests.login('9f100000-0000-4000-8000-000000000002');
delete from public.family_members
 where baby_id = '9f000000-0000-4000-8000-000000000002' and user_id = '9f100000-0000-4000-8000-000000000002';
reset role;
select tests.logout();
select tests.eq(tests.count($q$select 1 from public.family_members where baby_id = '9f000000-0000-4000-8000-000000000002'$q$),
                1::bigint, 'a parent can leave by their own will');
select tests.eq(tests.count($q$select 1 from public.family_members
                                 where baby_id = '9f000000-0000-4000-8000-000000000001' and relation in ('anne', 'baba') and is_admin$q$),
                2::bigint, 'both parents of the first baby are untouched');

-- P-10: a sole parent deletes the babies first ------------------------------------------------------
set role authenticated;
select tests.login('9f100000-0000-4000-8000-000000000005');
select tests.eq((select array_agg(first_name order by first_name) from public.account_deletion_blockers()),
                array['TekEbeveyn'], 'the settings screen lists the babies that block deletion');
select tests.login('9f100000-0000-4000-8000-000000000001');
select tests.eq((select count(*) from public.account_deletion_blockers()), 1::bigint,
                'a parent alone on a baby (after the other left) is blocked for that baby only');
reset role;
select tests.logout();

begin;
set local role service_role;
select tests.expect_error($q$select * from public.prepare_account_deletion('9f100000-0000-4000-8000-000000000005', false)$q$,
                          'delete_babies_first');
select tests.eq((select count(*) from public.babies where id = '9f000000-0000-4000-8000-000000000003'), 1::bigint,
                'babies are never deleted implicitly');
rollback;

-- P-8: the other parent stays the admin; legacy non-admin Baba is promoted, a non-parent never.
begin;
set local role service_role;
select tests.eq((select count(*) from public.prepare_account_deletion('9f100000-0000-4000-8000-000000000002', false)) >= 0,
                true, 'Baba can delete the account while Anne remains');
select tests.eq((select is_admin from public.family_members
                  where baby_id = '9f000000-0000-4000-8000-000000000001' and user_id = '9f100000-0000-4000-8000-000000000001'),
                true, 'Anne stays the admin');
rollback;

begin;
set local role service_role;
-- Anne of EskiBaba / EskiDede: EskiDede has a legacy non-parent admin, so
-- Anne is not its last admin; EskiBaba has a non-admin Baba who is promoted.
select count(*) from public.prepare_account_deletion('9f100000-0000-4000-8000-000000000006', false);
select tests.eq((select is_admin from public.family_members
                  where baby_id = '9f000000-0000-4000-8000-000000000004' and user_id = '9f100000-0000-4000-8000-000000000007'),
                true, 'the other parent (legacy, non-admin) is promoted');
select tests.eq((select count(*) from public.activity_logs
                  where baby_id = '9f000000-0000-4000-8000-000000000004' and action = 'member_admin_granted'),
                1::bigint, 'the promotion is audited');
rollback;

-- P-3: only a parent deletes a baby ------------------------------------------------------------------
begin;
set local role service_role;
select tests.expect_error(
  $q$select * from public.delete_baby_for_user('9f100000-0000-4000-8000-000000000008', '9f000000-0000-4000-8000-000000000005')$q$,
  'only parents');
select tests.eq((select count(*) from public.delete_baby_for_user('9f100000-0000-4000-8000-000000000001',
                                                                    '9f000000-0000-4000-8000-000000000002')) >= 0,
                true, 'either parent alone deletes the baby');
select tests.eq((select count(*) from public.babies where id = '9f000000-0000-4000-8000-000000000002'), 0::bigint, 'baby deleted');
rollback;

-- Legacy report (Super Admin) ------------------------------------------------------------------------
set role authenticated;
select tests.login(tests.id('baska')); -- Super Admin since the Phase 2 tests
select tests.eq((public.admin_parent_authority_report() -> 'babies_without_parent_admin') ? '9f000000-0000-4000-8000-000000000005',
                false, 'a baby with a parent admin is not reported as parentless');
select tests.eq(exists (select 1 from jsonb_array_elements(public.admin_parent_authority_report() -> 'non_parent_admins') e
                         where e ->> 'baby_id' = '9f000000-0000-4000-8000-000000000005'),
                true, 'remaining non-parent admins are reported');
select tests.eq(exists (select 1 from jsonb_array_elements(public.admin_parent_authority_report() -> 'parents_without_admin') e
                         where e ->> 'baby_id' = '9f000000-0000-4000-8000-000000000004'),
                true, 'Anne / Baba without admin rights are reported');
select tests.login('9f100000-0000-4000-8000-000000000001');
select tests.expect_error($q$select public.admin_parent_authority_report()$q$, 'not authorized');
reset role;
select tests.logout();

-- Legacy clean-up (run by the migration; idempotent) -----------------------------------------------
-- Runs in a transaction that is rolled back: the clean-up is global and
-- must not change the legacy fixtures of the other suites.
begin;
-- A baby whose only admin is a non-parent keeps that admin (never admin-less).
insert into public.babies (id, first_name, birth_date, created_by) values
  ('9f000000-0000-4000-8000-000000000006', 'Ebeveynsiz', public.business_date_istanbul() - 100, '9f100000-0000-4000-8000-000000000008');
alter table public.family_members disable trigger family_members_parent_guard;
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('9f000000-0000-4000-8000-000000000006', '9f100000-0000-4000-8000-000000000008', 'dede', true, array(select key from public.permissions));
alter table public.family_members enable trigger family_members_parent_guard;

select tests.eq(public.revoke_non_parent_admins() >= 1, true, 'legacy non-parent admins are revoked');
select tests.eq((select is_admin from public.family_members
                  where baby_id = '9f000000-0000-4000-8000-000000000005' and user_id = '9f100000-0000-4000-8000-000000000008'),
                false, 'a non-parent admin next to a parent admin becomes a regular member');
select tests.eq((select permissions from public.family_members
                  where baby_id = '9f000000-0000-4000-8000-000000000005' and user_id = '9f100000-0000-4000-8000-000000000008'),
                array(select key from public.permissions order by key), 'permissions are left unchanged');
select tests.eq((select count(*) from public.activity_logs
                  where baby_id = '9f000000-0000-4000-8000-000000000005' and action = 'member_admin_revoked'),
                1::bigint, 'the revocation is audited');
select tests.eq((select is_admin from public.family_members
                  where baby_id = '9f000000-0000-4000-8000-000000000006' and user_id = '9f100000-0000-4000-8000-000000000008'),
                true, 'a baby without a parent admin keeps its only admin (reported instead)');
select tests.eq(public.revoke_non_parent_admins(), 0, 'the clean-up is idempotent');
select tests.eq(has_function_privilege('authenticated', 'public.revoke_non_parent_admins()', 'execute'), false,
                'the clean-up is not callable by clients');
rollback;
