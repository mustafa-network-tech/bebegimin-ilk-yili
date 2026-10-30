-- User event tracking: server-only write path, fixed vocabularies, triggers that can
-- never block the triggering statement, admin-only read models, the two distinct
-- payment-problem states, history without estimated events, retention.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

-- Fixtures (prefix d1 is unique to this suite) -------------------------------------------------
insert into public.platform_user_roles (user_id, role, granted_by)
values (tests.id('baska'), 'super_admin', tests.id('anne'))
on conflict (user_id, role) do update set revoked_at = null;

-- 1. Triggers record the journey --------------------------------------------------------------------
insert into auth.users (id, email) values ('d1000000-0000-4000-8000-000000000001', 'ue-yeni@example.com');
select tests.eq((select count(*) from public.user_events
                  where user_id = 'd1000000-0000-4000-8000-000000000001' and event_type = 'user_registered'),
                1::bigint, 'registration is recorded');

update auth.users set email_confirmed_at = now() where id = 'd1000000-0000-4000-8000-000000000001';
select tests.eq((select count(*) from public.user_events
                  where user_id = 'd1000000-0000-4000-8000-000000000001' and event_type = 'email_verified'),
                1::bigint, 'e-mail verification is recorded');

update auth.users set last_sign_in_at = now() where id = 'd1000000-0000-4000-8000-000000000001';
update auth.users set last_sign_in_at = now() + interval '1 hour' where id = 'd1000000-0000-4000-8000-000000000001';
select tests.eq((select count(*) from public.user_events
                  where user_id = 'd1000000-0000-4000-8000-000000000001' and event_type = 'first_sign_in'),
                1::bigint, 'only the first sign-in is recorded');

insert into public.family_accounts (id, display_name, created_by)
values ('d1100000-0000-4000-8000-000000000001', 'Olay ailesi', 'd1000000-0000-4000-8000-000000000001');
select tests.eq((select count(*) from public.user_events
                  where user_id = 'd1000000-0000-4000-8000-000000000001'
                    and family_account_id = 'd1100000-0000-4000-8000-000000000001'
                    and event_type = 'family_created'),
                1::bigint, 'family account creation is recorded for its creator');

insert into public.family_account_members (family_account_id, user_id, role, status, activated_at)
values ('d1100000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'parent', 'active', now());

insert into public.babies (id, first_name, birth_date, created_by)
values ('d1200000-0000-4000-8000-000000000001', 'Olay', public.business_date_istanbul() - 30,
        'd1000000-0000-4000-8000-000000000001');
insert into public.family_account_babies (baby_id, family_account_id)
values ('d1200000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000001');
select tests.eq((select count(*) from public.user_events
                  where user_id = 'd1000000-0000-4000-8000-000000000001' and event_type = 'baby_added'),
                1::bigint, 'baby link is recorded without baby data');

insert into public.subscriptions (id, family_account_id, plan_id, plan_code, billing_period, status, provider,
                                  provider_subscription_id, current_period_end)
select 'd1300000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000001', p.id, p.code,
       p.billing_period, 'active', 'google_play', 'ue-token-should-never-be-copied', now() + interval '20 days'
  from public.subscription_plans p where p.code = 'small_family' and p.billing_period = 'monthly';
select tests.eq((select count(*) from public.user_events
                  where family_account_id = 'd1100000-0000-4000-8000-000000000001'
                    and event_type = 'subscription_activated' and platform = 'android'
                    and plan_code = 'small_family' and user_id is null),
                1::bigint, 'activation is recorded family-scoped with the platform');
update public.subscriptions set cancel_at_period_end = true where id = 'd1300000-0000-4000-8000-000000000001';
select tests.eq((select count(*) from public.user_events
                  where family_account_id = 'd1100000-0000-4000-8000-000000000001'
                    and event_type = 'subscription_canceled'),
                1::bigint, 'cancellation is recorded');
update public.subscriptions set status = 'expired' where id = 'd1300000-0000-4000-8000-000000000001';
select tests.eq((select count(*) from public.user_events
                  where family_account_id = 'd1100000-0000-4000-8000-000000000001'
                    and event_type = 'subscription_expired'),
                1::bigint, 'expiry is recorded');

-- No purchase token or free text is ever stored.
select tests.eq((select count(*) from information_schema.columns
                  where table_schema = 'public' and table_name = 'user_events'
                    and data_type in ('jsonb', 'json')),
                0::bigint, 'user_events has no json payload column');
select tests.eq((select count(*) from public.user_events where plan_code like '%token%' or error_code like '%token%'),
                0::bigint, 'no token reaches user_events');

-- 2. The writer never raises and only accepts the fixed vocabulary ----------------------------------------
set role service_role;
select tests.eq(public.record_server_user_event('d1000000-0000-4000-8000-000000000001', 'payment_verified',
                  'android', 'small_family', 'subscription', 'ok', null),
                true, 'service role records a server event');
select tests.eq(public.record_server_user_event('d1000000-0000-4000-8000-000000000001', 'payment_verified',
                  'android', 'small_family', 'subscription', 'ok', null),
                false, 'an identical event within a minute is not duplicated');
select tests.eq(public.record_server_user_event('d1000000-0000-4000-8000-000000000001', 'not_an_event'),
                false, 'unknown event type is swallowed, not raised');
select tests.eq(public.record_server_user_event('d1000000-0000-4000-8000-000000000001', 'activation_failed',
                  'android', 'small_family', 'subscription', 'failed', 'ya29.looks-like-a-token'),
                false, 'free-text error codes are refused');
select tests.eq(public.record_server_user_event('d1000000-0000-4000-8000-0000000000ff', 'activation_failed'),
                false, 'an unknown user does not raise');
select tests.eq(public.record_server_user_event(null, 'activation_failed'),
                false, 'an event without user or family is refused');
reset role;

-- 3. API roles cannot write, read or call the internals ------------------------------------------------------
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$select public.record_server_user_event(tests.id('anne'), 'payment_verified')$q$,
                          'permission denied');
select tests.expect_error($q$select public.user_events_write(tests.id('anne'), null, 'payment_verified', 'web', null, null, 'ok', null)$q$,
                          'permission denied');
select tests.expect_error($q$select public.user_payment_problem(tests.id('anne'))$q$, 'permission denied');
select tests.expect_error($q$select count(*) from public.user_events$q$, 'permission denied');
select tests.expect_error($q$insert into public.user_events (user_id, event_type) values (tests.id('anne'), 'payment_verified')$q$,
                          'permission denied');
select tests.expect_error($q$select public.purge_user_events()$q$, 'permission denied');
reset role;
set role anon;
select tests.expect_error($q$select public.record_server_user_event('d1000000-0000-4000-8000-000000000001', 'payment_verified')$q$,
                          'permission denied');
reset role;

-- 4. A tracking failure never blocks the triggering statement ------------------------------------------------
alter table public.user_events add constraint user_events_test_block check (false) not valid;
insert into auth.users (id, email) values ('d1000000-0000-4000-8000-000000000002', 'ue-engelsiz@example.com');
select tests.eq((select count(*) from auth.users where id = 'd1000000-0000-4000-8000-000000000002'),
                1::bigint, 'sign-up still succeeds while event writes fail');
alter table public.user_events drop constraint user_events_test_block;
delete from auth.users where id = 'd1000000-0000-4000-8000-000000000002';

-- 5. Admin read models: Super Admin only ---------------------------------------------------------------------------
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$select * from public.admin_user_activity('d1000000-0000-4000-8000-000000000001')$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_user_activity_summary('d1000000-0000-4000-8000-000000000001')$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_conversion_funnel(30)$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_payment_problems()$q$, 'not authorized');

select tests.login(tests.id('baska'));
select tests.expect_error($q$select * from public.admin_conversion_funnel(14)$q$, 'invalid period');
select tests.expect_error($q$select * from public.admin_user_activity('d1000000-0000-4000-8000-0000000000ee')$q$, 'user not found');
select tests.eq((select count(*) from public.admin_user_activity('d1000000-0000-4000-8000-000000000001', 100, 0)
                  where source = 'recorded' and event_type in ('user_registered', 'family_created', 'baby_added',
                        'subscription_activated', 'subscription_canceled', 'subscription_expired')) >= 6,
                true, 'timeline merges user and family scoped recorded events');
select tests.eq((select count(*) from public.admin_user_activity('d1000000-0000-4000-8000-000000000001', 100, 0)
                  where scope = 'family') >= 3,
                true, 'family events are marked family scoped');
select tests.expect_error($q$select payload from public.admin_user_activity('d1000000-0000-4000-8000-000000000001')$q$,
                          'column "payload" does not exist');
select tests.expect_error($q$select provider_subscription_id from public.admin_user_activity('d1000000-0000-4000-8000-000000000001')$q$,
                          'does not exist');

-- 6. Payment problem states are kept apart ---------------------------------------------------------------------------
-- (a) store confirmed the payment, nothing activated, no access -> paid_not_activated
reset role;
insert into auth.users (id, email) values ('d1000000-0000-4000-8000-000000000003', 'ue-odeme@example.com');
insert into public.family_accounts (id, display_name, created_by)
values ('d1100000-0000-4000-8000-000000000003', 'Ödeme ailesi', 'd1000000-0000-4000-8000-000000000003');
insert into public.family_account_members (family_account_id, user_id, role, status, activated_at)
values ('d1100000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000003', 'parent', 'active', now());

set role service_role;
select public.record_server_user_event('d1000000-0000-4000-8000-000000000003', 'payment_verified',
         'android', 'small_family', 'subscription', 'ok', null);
select public.record_server_user_event('d1000000-0000-4000-8000-000000000003', 'activation_failed',
         'android', 'small_family', 'subscription', 'failed', 'purchase_rejected');
reset role;
select tests.eq(public.user_payment_problem('d1000000-0000-4000-8000-000000000003'),
                'paid_not_activated', 'store-confirmed payment without activation is paid_not_activated');

-- (b) verification only failed (payment unknown) -> verification_failed
insert into auth.users (id, email) values ('d1000000-0000-4000-8000-000000000004', 'ue-dogrulama@example.com');
set role service_role;
select public.record_server_user_event('d1000000-0000-4000-8000-000000000004', 'store_verification_failed',
         'android', 'small_family', null, 'failed', 'google_403');
reset role;
select tests.eq(public.user_payment_problem('d1000000-0000-4000-8000-000000000004'),
                'verification_failed', 'a failed store check alone is verification_failed, not a paid payment');

set role authenticated;
select tests.login(tests.id('baska'));
select tests.eq((select payment_problem from public.admin_user_activity_summary('d1000000-0000-4000-8000-000000000003')),
                'paid_not_activated', 'summary shows paid_not_activated');
select tests.eq((select payment_failure_count from public.admin_user_activity_summary('d1000000-0000-4000-8000-000000000003')),
                1::bigint, 'failed activation counted once');
select tests.eq((select has_payment_attempt from public.admin_user_activity_summary('d1000000-0000-4000-8000-000000000003')),
                true, 'payment attempt detected from recorded events');
select tests.eq((select problem from public.admin_payment_problems(100, 0)
                  where user_id = 'd1000000-0000-4000-8000-000000000004'),
                'verification_failed', 'problem list separates the two states');
select tests.eq((select problem from public.admin_payment_problems(100, 0)
                  where user_id = 'd1000000-0000-4000-8000-000000000003'),
                'paid_not_activated', 'problem list shows the paid, not activated user');
select tests.eq((select open_paid_not_activated >= 1 and open_verification_failed >= 1
                   from public.admin_conversion_funnel(7)),
                true, 'funnel counts both open problem states');
select tests.eq((select plans_viewed_available from public.admin_conversion_funnel(7)),
                false, 'plan views are reported as not available before the client phase');

-- (c) later activation or granted access resolves the problem
reset role;
set role service_role;
select public.record_server_user_event('d1000000-0000-4000-8000-000000000003', 'activation_granted',
         'android', 'small_family', 'subscription', 'ok', null);
reset role;
select tests.eq(public.user_payment_problem('d1000000-0000-4000-8000-000000000003'),
                null, 'a later activation resolves the problem');

insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider,
                                  provider_subscription_id, current_period_end)
select 'd1100000-0000-4000-8000-000000000003', p.id, p.code, p.billing_period, 'active', 'google_play',
       'ue-token-2', now() + interval '20 days'
  from public.subscription_plans p where p.code = 'small_family' and p.billing_period = 'monthly';
set role service_role;
select public.record_server_user_event('d1000000-0000-4000-8000-000000000004', 'payment_verified',
         'android', 'small_family', 'subscription', 'ok', null);
reset role;
insert into public.family_accounts (id, display_name, created_by)
values ('d1100000-0000-4000-8000-000000000004', 'Doğrulama ailesi', 'd1000000-0000-4000-8000-000000000004');
insert into public.family_account_members (family_account_id, user_id, role, status, activated_at)
values ('d1100000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000004', 'parent', 'active', now());
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider,
                                  provider_subscription_id, current_period_end)
select 'd1100000-0000-4000-8000-000000000004', p.id, p.code, p.billing_period, 'active', 'google_play',
       'ue-token-3', now() + interval '20 days'
  from public.subscription_plans p where p.code = 'small_family' and p.billing_period = 'monthly';
select tests.eq(public.user_payment_problem('d1000000-0000-4000-8000-000000000004'),
                null, 'granted access also resolves a store-confirmed payment');

-- 7. History: only what exists, only before tracking started, never estimated ---------------------------------------
alter table auth.users disable trigger user_events_auth_insert;
insert into auth.users (id, email, created_at) values
  ('d1000000-0000-4000-8000-000000000005', 'ue-eski@example.com',
   (select value - interval '30 days' from public.user_event_meta where key = 'tracking_started'));
alter table auth.users enable trigger user_events_auth_insert;
set role authenticated;
select tests.login(tests.id('baska'));
select tests.eq((select count(*) from public.admin_user_activity('d1000000-0000-4000-8000-000000000005')
                  where source = 'history' and event_type = 'user_registered'),
                1::bigint, 'pre-tracking registration is shown from the users table');
select tests.eq((select count(*) from public.admin_user_activity('d1000000-0000-4000-8000-000000000005')
                  where source = 'recorded'),
                0::bigint, 'no recorded or estimated events exist for a pre-tracking user');
select tests.eq((select count(*) from public.admin_user_activity('d1000000-0000-4000-8000-000000000005')
                  where event_type in ('plans_viewed', 'plan_selected', 'first_sign_in', 'payment_verified')),
                0::bigint, 'untracked steps are not invented');

-- 8. Retention ----------------------------------------------------------------------------------------------------------------
reset role;
select tests.logout();
insert into public.user_events (user_id, event_type, occurred_at)
values ('d1000000-0000-4000-8000-000000000005', 'user_registered', now() - interval '14 months');
set role service_role;
select tests.expect_error($q$select public.purge_user_events(interval '1 day')$q$, 'at least one month');
select tests.eq(public.purge_user_events() >= 1, true, 'events older than 13 months are purged');
reset role;
select tests.eq((select count(*) from public.user_events where occurred_at < now() - interval '13 months'),
                0::bigint, 'nothing older than the retention window remains');

-- 9. Account deletion removes the user's events ----------------------------------------------------------------------
delete from public.subscriptions where family_account_id in
  ('d1100000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000003', 'd1100000-0000-4000-8000-000000000004');
delete from public.family_account_babies where baby_id = 'd1200000-0000-4000-8000-000000000001';
delete from public.babies where id = 'd1200000-0000-4000-8000-000000000001';
delete from public.family_accounts where id in
  ('d1100000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000003', 'd1100000-0000-4000-8000-000000000004');
delete from auth.users where id in
  ('d1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000003',
   'd1000000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000005');
select tests.eq((select count(*) from public.user_events where user_id::text like 'd1000000-%'),
                0::bigint, 'deleting a user cascades to their events');

delete from public.platform_user_roles where user_id = tests.id('baska') and role = 'super_admin';
