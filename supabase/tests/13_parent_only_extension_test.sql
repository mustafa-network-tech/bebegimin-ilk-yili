-- Decision P-6 (2026-10-02): only the parents (Anne / Baba admins) may
-- request the one-time lifecycle extension. A refused attempt must never
-- use up the single right.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout(); -- fixture writes run as a trusted (non-user) context
-- Dedicated users so the shared demo users (teyze, baska) keep their
-- memberships for the later suites.
insert into auth.users (id, email) values
  ('9e100000-0000-4000-8000-000000000001', 'akraba@example.com'),
  ('9e100000-0000-4000-8000-000000000002', 'eski-yonetici@example.com'),
  ('9e100000-0000-4000-8000-000000000003', 'dis-kisi@example.com');

insert into public.babies (id, first_name, birth_date, created_by) values
  ('9e000000-0000-4000-8000-000000000001', 'Ebeveyn', public.business_date_istanbul() - 100, tests.id('anne')),
  ('9e000000-0000-4000-8000-000000000002', 'Eski Yönetici', public.business_date_istanbul() - 100, tests.id('anne')),
  ('9e000000-0000-4000-8000-000000000003', 'Baba', public.business_date_istanbul() - 100, tests.id('baba'));

insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('9e000000-0000-4000-8000-000000000001', tests.id('anne'), 'anne', true, array(select key from public.permissions)),
  ('9e000000-0000-4000-8000-000000000001', tests.id('baba'), 'baba', true, array(select key from public.permissions)),
  ('9e000000-0000-4000-8000-000000000001', '9e100000-0000-4000-8000-000000000001', 'teyze', false, '{view_memories}'),
  ('9e000000-0000-4000-8000-000000000002', tests.id('anne'), 'anne', true, array(select key from public.permissions)),
  ('9e000000-0000-4000-8000-000000000003', tests.id('baba'), 'baba', true, array(select key from public.permissions));
-- Legacy data: a non-parent admin. P-5 (parent_authority migration) makes
-- this impossible to create today, so the fixture bypasses that guard.
alter table public.family_members disable trigger family_members_parent_guard;
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('9e000000-0000-4000-8000-000000000002', '9e100000-0000-4000-8000-000000000002', 'dede', true,
   array(select key from public.permissions));
alter table public.family_members enable trigger family_members_parent_guard;

set role authenticated;

-- Non-parents ---------------------------------------------------------------------------------
select tests.login('9e100000-0000-4000-8000-000000000001');
select tests.eq((select can_request_extension from public.baby_lifecycle_summary('9e000000-0000-4000-8000-000000000001')),
                false, 'a non-parent member never gets the extension form');
select tests.expect_error(
  $q$select public.request_baby_extension('9e000000-0000-4000-8000-000000000001', 1)$q$,
  'only parents'
);

select tests.login('9e100000-0000-4000-8000-000000000002');
select tests.eq((select can_request_extension from public.baby_lifecycle_summary('9e000000-0000-4000-8000-000000000002')),
                false, 'a non-parent admin never gets the extension form');
select tests.expect_error(
  $q$select public.request_baby_extension('9e000000-0000-4000-8000-000000000002', 7)$q$,
  'only parents'
);

-- Non-members still learn nothing about the baby.
select tests.login('9e100000-0000-4000-8000-000000000003');
select tests.expect_error(
  $q$select public.request_baby_extension('9e000000-0000-4000-8000-000000000003', 7)$q$,
  'resource not found'
);

reset role;
select tests.logout();
select tests.eq(tests.count($q$select 1 from public.baby_extension_requests
                                 where baby_id in ('9e000000-0000-4000-8000-000000000001',
                                                   '9e000000-0000-4000-8000-000000000002',
                                                   '9e000000-0000-4000-8000-000000000003')$q$),
                0::bigint, 'refused attempts never use up the one-time right');
set role authenticated;

-- Parents -----------------------------------------------------------------------------------
select tests.login(tests.id('anne'));
select tests.eq((select can_request_extension from public.baby_lifecycle_summary('9e000000-0000-4000-8000-000000000001')),
                true, 'Anne gets the extension form');
select tests.eq(public.request_baby_extension('9e000000-0000-4000-8000-000000000001', 30) is not null,
                true, 'Anne can request the extension');
select tests.eq((select can_request_extension from public.baby_lifecycle_summary('9e000000-0000-4000-8000-000000000001')),
                false, 'the right is used once requested');

select tests.login(tests.id('baba'));
select tests.expect_error(
  $q$select public.request_baby_extension('9e000000-0000-4000-8000-000000000001', 5)$q$,
  'already requested'
);
select tests.eq((select can_request_extension from public.baby_lifecycle_summary('9e000000-0000-4000-8000-000000000003')),
                true, 'Baba gets the extension form');
select tests.eq(public.request_baby_extension('9e000000-0000-4000-8000-000000000003', 1) is not null,
                true, 'Baba can request the extension');

-- The helper is internal: clients cannot probe it.
reset role;
select tests.logout();
select tests.eq(has_function_privilege('authenticated', 'public.is_baby_parent(uuid)', 'execute'), false,
                'is_baby_parent is not callable by clients');
select tests.eq(has_function_privilege('anon', 'public.is_baby_parent(uuid)', 'execute'), false,
                'is_baby_parent is not callable by anon');
