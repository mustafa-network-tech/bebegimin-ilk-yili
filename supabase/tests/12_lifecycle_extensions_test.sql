-- Phase 2 lifecycle, extension and Super Admin security tests.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- Dedicated babies keep lifecycle cases independent from the demo fixtures.
reset role;
insert into public.babies (id, first_name, birth_date, created_by) values
  ('91000000-0000-4000-8000-000000000001', 'Sınır', public.business_date_istanbul() - 374, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000002', 'Bir', public.business_date_istanbul() - 100, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000003', 'Yedi', public.business_date_istanbul() - 100, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000004', 'Oniki', public.business_date_istanbul() - 100, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000005', 'Yirmidokuz', public.business_date_istanbul() - 100, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000006', 'Otuz', public.business_date_istanbul() - 372, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000007', 'Bekleyen', public.business_date_istanbul() - 100, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000008', 'Reddedilen', public.business_date_istanbul() - 100, tests.id('anne')),
  ('91000000-0000-4000-8000-000000000009', 'Süresi Dolan', public.business_date_istanbul() - 374, tests.id('anne')),
  ('91000000-0000-4000-8000-00000000000a', 'Artık', date '2024-02-29', tests.id('anne'));

insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
select b.id, tests.id('anne'), 'anne', true, array(select key from public.permissions)
  from public.babies b where b.id::text like '91000000-0000-4000-8000-%';
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
select b.id, tests.id('baba'), 'baba', true, array(select key from public.permissions)
  from public.babies b where b.id::text like '91000000-0000-4000-8000-%';

insert into public.platform_user_roles (user_id, role, granted_by)
values (tests.id('baska'), 'super_admin', tests.id('anne'));

set role authenticated;
select tests.login(tests.id('anne'));

-- +374 is active; +375 is locked. The interval is half-open.
select tests.eq(public.baby_is_active('91000000-0000-4000-8000-000000000001'), true, '+374 is ACTIVE');
select tests.eq(
  (select remaining_days from public.baby_lifecycle_summary('91000000-0000-4000-8000-000000000001')),
  1,
  '+374 has one remaining day'
);
reset role;
update public.babies
   set birth_date = public.business_date_istanbul() - 375
 where id = '91000000-0000-4000-8000-000000000001';
set role authenticated;
select tests.login(tests.id('anne'));
select tests.eq(public.baby_is_locked('91000000-0000-4000-8000-000000000001'), true, '+375 is LOCKED');
select tests.eq(
  (select remaining_days from public.baby_lifecycle_summary('91000000-0000-4000-8000-000000000001')),
  0,
  'locked profile has zero remaining days'
);
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000001', 1)$q$,
  'before base close'
);

-- Explicit Istanbul midnight boundary and session/client clock independence.
select tests.eq(
  timezone('Europe/Istanbul', timestamptz '2026-01-01 20:59:59+00')::date,
  date '2026-01-01',
  'Istanbul 23:59:59 remains the same business date'
);
select tests.eq(
  timezone('Europe/Istanbul', timestamptz '2026-01-01 21:00:00+00')::date,
  date '2026-01-02',
  'Istanbul 00:00 starts the next business date'
);
set timezone = 'Pacific/Kiritimati';
select tests.eq(
  public.business_date_istanbul(),
  timezone('Europe/Istanbul', statement_timestamp())::date,
  'client/session clock ahead cannot change business date'
);
set timezone = 'America/Adak';
select tests.eq(
  public.business_date_istanbul(),
  timezone('Europe/Istanbul', statement_timestamp())::date,
  'client/session clock behind cannot change business date'
);
set timezone = 'Europe/Istanbul';
select tests.eq(
  public.baby_base_close_date('91000000-0000-4000-8000-00000000000a'),
  date '2025-03-10',
  '29 February birth uses calendar-day +375 semantics'
);

-- Client cannot write either privileged table directly.
select tests.eq(public.is_super_admin(), false, 'baby admin is not Super Admin');
select tests.eq(tests.count('select 1 from platform_user_roles'), 0::bigint, 'non-Super Admin cannot read platform roles');
select tests.expect_error(
  $q$insert into platform_user_roles (user_id, role) values (tests.id('anne'), 'super_admin')$q$,
  'permission denied'
);
select tests.expect_error(
  $q$insert into baby_extension_requests (baby_id, requested_by, requested_days) values ('91000000-0000-4000-8000-000000000002', tests.id('anne'), 1)$q$,
  'permission denied'
);

-- Invalid durations never create a request.
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000002', 0)$q$,
  'between 1 and 30'
);
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000002', -1)$q$,
  'between 1 and 30'
);
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000002', 31)$q$,
  'between 1 and 30'
);

-- One-day request: only Super Admin can decide; an approved decision is immutable.
select public.request_baby_extension('91000000-0000-4000-8000-000000000002', 1) as request_one \gset
select tests.expect_error(
  format('select public.decide_baby_extension(%L, %L, %L)', :'request_one', 'approved', 'baby admin attempt'),
  'not authorized'
);
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000002', 1)$q$,
  'already requested'
);

select tests.login(tests.id('baska'));
select tests.eq(public.is_super_admin(), true, 'platform role grants Super Admin');
select tests.eq(
  public.decide_baby_extension(:'request_one', 'approved', 'approved in test'),
  'approved',
  'Super Admin approves request'
);
select tests.expect_error(
  format('select public.decide_baby_extension(%L, %L, %L)', :'request_one', 'rejected', 'second decision'),
  'immutable'
);

select tests.login(tests.id('anne'));
select tests.eq(public.baby_approved_extension_days('91000000-0000-4000-8000-000000000002'), 1::smallint, 'one day approved');
select tests.eq(
  public.baby_effective_close_date('91000000-0000-4000-8000-000000000002'),
  public.baby_base_close_date('91000000-0000-4000-8000-000000000002') + 1,
  'one-day extension changes effective close only'
);

-- Approved 7, 12, 29 and 30 day variants.
select public.request_baby_extension('91000000-0000-4000-8000-000000000003', 7) as request_seven \gset
select public.request_baby_extension('91000000-0000-4000-8000-000000000004', 12) as request_twelve \gset
select public.request_baby_extension('91000000-0000-4000-8000-000000000005', 29) as request_twenty_nine \gset
select public.request_baby_extension('91000000-0000-4000-8000-000000000006', 30) as request_thirty \gset
select tests.login(tests.id('baska'));
select public.decide_baby_extension(:'request_seven', 'approved', null);
select public.decide_baby_extension(:'request_twelve', 'approved', null);
select public.decide_baby_extension(:'request_twenty_nine', 'approved', null);
select public.decide_baby_extension(:'request_thirty', 'approved', null);

select tests.login(tests.id('anne'));
select tests.eq(public.baby_approved_extension_days('91000000-0000-4000-8000-000000000003'), 7::smallint, 'seven days approved');
select tests.eq(public.baby_approved_extension_days('91000000-0000-4000-8000-000000000004'), 12::smallint, 'twelve days approved');
select tests.eq(public.baby_approved_extension_days('91000000-0000-4000-8000-000000000005'), 29::smallint, 'twenty-nine days approved');
select tests.eq(public.baby_approved_extension_days('91000000-0000-4000-8000-000000000006'), 30::smallint, 'thirty days approved');
select tests.eq(
  public.baby_effective_close_date('91000000-0000-4000-8000-000000000006'),
  (select birth_date + 405 from public.babies where id = '91000000-0000-4000-8000-000000000006'),
  'thirty-day extension closes at absolute +405'
);
select tests.eq(
  (select remaining_days from public.baby_lifecycle_summary('91000000-0000-4000-8000-000000000006')),
  33,
  'thirty days approved three days before base close yields 33 remaining days'
);

-- Pending and rejected states permanently consume the one request.
select public.request_baby_extension('91000000-0000-4000-8000-000000000007', 7) as request_pending \gset
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000007', 7)$q$,
  'already requested'
);
select public.request_baby_extension('91000000-0000-4000-8000-000000000008', 12) as request_rejected \gset
select tests.login(tests.id('baska'));
select tests.eq(
  public.decide_baby_extension(:'request_rejected', 'rejected', 'not justified'),
  'rejected',
  'Super Admin rejects request'
);
select tests.login(tests.id('anne'));
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000008', 12)$q$,
  'already requested'
);

-- The unique constraint is the concurrent-request serialization boundary.
select tests.eq(
  (select count(*) from pg_constraint
    where conrelid = 'public.baby_extension_requests'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) = 'UNIQUE (baby_id)'),
  1::bigint,
  'one unique request per baby serializes concurrent attempts'
);

-- Expiration at base close never reopens the profile and is idempotent.
select public.request_baby_extension('91000000-0000-4000-8000-000000000009', 30) as request_expiring \gset
reset role;
update public.babies
   set birth_date = public.business_date_istanbul() - 375
 where id = '91000000-0000-4000-8000-000000000009';
select public.run_baby_lifecycle_jobs(public.business_date_istanbul());
set role authenticated;
select tests.login(tests.id('anne'));
select tests.eq(
  (select status from public.baby_extension_requests where id = :'request_expiring'),
  'expired',
  'pending request expires at base close'
);
select tests.eq(
  (select status from public.baby_lifecycle_summary('91000000-0000-4000-8000-000000000009')),
  'LOCKED',
  'expired request does not reopen the profile at base close'
);
reset role;
update public.babies
   set birth_date = public.business_date_istanbul() - 100
 where id = '91000000-0000-4000-8000-000000000009';
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error(
  $q$select public.request_baby_extension('91000000-0000-4000-8000-000000000009', 30)$q$,
  'already requested'
);
select tests.eq(
  tests.count(format('select 1 from activity_logs where baby_id = %L and action = %L', '91000000-0000-4000-8000-000000000009', 'extension_expired')),
  1::bigint,
  'expiration is audited once'
);
reset role;
select public.run_baby_lifecycle_jobs(public.business_date_istanbul());
set role authenticated;
select tests.login(tests.id('anne'));
select tests.eq(
  tests.count(format('select 1 from activity_logs where baby_id = %L and action = %L', '91000000-0000-4000-8000-000000000009', 'extension_expired')),
  1::bigint,
  'second lifecycle job run is idempotent'
);
select tests.eq(
  tests.count(format('select 1 from activity_logs where baby_id = %L and action = %L', '91000000-0000-4000-8000-000000000009', 'profile_locked')),
  1::bigint,
  'profile lock is audited once'
);
select tests.eq(
  tests.count(format('select 1 from notifications where baby_id = %L and type = %L', '91000000-0000-4000-8000-000000000009', 'extension_expired')) > 0,
  true,
  'expiration notifies the family'
);

-- Decision fields cannot be edited through table writes, even by a member.
select tests.expect_error(
  format('update baby_extension_requests set status = %L where id = %L', 'approved', :'request_rejected'),
  'permission denied'
);
select tests.eq(
  tests.count($q$select 1 from activity_logs where action = 'extension_requested'$q$) > 0,
  true,
  'extension requests are audited'
);
select tests.eq(
  tests.count($q$select 1 from activity_logs where action in ('extension_approved', 'extension_rejected')$q$) > 0,
  true,
  'extension decisions are audited'
);

reset role;
