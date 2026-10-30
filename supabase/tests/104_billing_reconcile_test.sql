-- Scheduled Google Play reconciliation (migration 20261029000100):
-- two-day access slack, flags, claim / lease / back-off, ack bookkeeping,
-- voided filter, forward-only cursor, run log, and service-role-only access.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('ca000000-0000-4000-8000-000000000001', 'rec-anne@example.com'),
  ('ca000000-0000-4000-8000-000000000002', 'rec-baba@example.com'),
  ('ca000000-0000-4000-8000-000000000003', 'rec-dede@example.com'),
  ('ca000000-0000-4000-8000-000000000004', 'rec-nine@example.com');

set role authenticated;
select tests.login('ca000000-0000-4000-8000-000000000001');
select (public.create_baby('Birinci', public.business_date_istanbul() - 20, 'anne')).id as baby1 \gset
select public.family_account_id_for_baby(:'baby1') as acct1 \gset
select intent_id as intent1 from public.request_subscription_checkout(:'acct1', 'small_family', 'monthly', 'google_play') \gset
select tests.login('ca000000-0000-4000-8000-000000000002');
select (public.create_baby('Ikinci', public.business_date_istanbul() - 20, 'baba')).id as baby2 \gset
select public.family_account_id_for_baby(:'baby2') as acct2 \gset
select intent_id as intent2 from public.request_subscription_checkout(:'acct2', 'small_family', 'annual', 'google_play') \gset
select tests.login('ca000000-0000-4000-8000-000000000003');
select (public.create_baby('Ucuncu', public.business_date_istanbul() - 20, 'anne')).id as baby3 \gset
select public.family_account_id_for_baby(:'baby3') as acct3 \gset
select intent_id as intent3 from public.request_subscription_checkout(:'acct3', 'small_family', 'monthly', 'app_store') \gset
select tests.login('ca000000-0000-4000-8000-000000000004');
select (public.create_baby('Dorduncu', public.business_date_istanbul() - 20, 'anne')).id as baby4 \gset
select public.family_account_id_for_baby(:'baby4') as acct4 \gset
select intent_id as intent4 from public.request_subscription_checkout(:'acct4', 'small_family', 'monthly', 'google_play') \gset
reset role;
select tests.logout();

select public.billing_apply_event('google_play', 'rec-s1', 'x', json_build_object('bound_intent_id', :'intent1',
  'provider_subscription_id', 'rec-tok-1', 'provider_product_id', 'small_family:monthly', 'status', 'active',
  'current_period_start', now() - interval '10 days', 'current_period_end', now() + interval '20 days')::jsonb);
select public.billing_apply_event('google_play', 'rec-s2', 'x', json_build_object('bound_intent_id', :'intent2',
  'provider_subscription_id', 'rec-tok-2', 'provider_product_id', 'small_family:annual', 'status', 'active',
  'current_period_start', now() - interval '1 year', 'current_period_end', now() - interval '1 hour')::jsonb);
select public.billing_apply_event('app_store', 'rec-s3', 'x', json_build_object('bound_intent_id', :'intent3',
  'provider_subscription_id', 'rec-orig-3', 'provider_product_id', 'bebegimin.small_family.monthly', 'status', 'active',
  'current_period_end', now() + interval '20 days')::jsonb);
select public.billing_apply_event('google_play', 'rec-s4', 'x', json_build_object('bound_intent_id', :'intent4',
  'provider_subscription_id', 'rec-tok-4', 'provider_product_id', 'small_family:monthly', 'status', 'expired',
  'current_period_end', now() - interval '5 days')::jsonb);

-- 1. Two-day access slack, and only for trialing / active --------------------------------------
select tests.eq(public.subscription_grants_access('active', now() - interval '47 hours'), true, 'active: still access 47 h after the period end');
select tests.eq(public.subscription_grants_access('active', now() - interval '49 hours'), false, 'active: no access after two days');
select tests.eq(public.subscription_grants_access('trialing', now() - interval '36 hours'), true, 'trialing gets the same slack');
select tests.eq(public.subscription_grants_access('active', null), true, 'no period end: access');
select tests.eq(public.subscription_grants_access('grace', now() - interval '30 days'), true, 'grace keeps its own rule');
select tests.eq(public.subscription_grants_access('past_due', now() + interval '10 days'), false, 'on hold / paused (past_due) never gets access');
select tests.eq(public.subscription_grants_access('expired', now() + interval '10 days'), false, 'expired (refund, revoke, end) never gets access');
select tests.eq(public.subscription_grants_access('canceled', now() + interval '10 days'), false, 'canceled status never gets access');

-- 2. Flags: off and dry-run by default ----------------------------------------------------------
select tests.eq((public.billing_reconcile_config() ->> 'enabled')::boolean, false, 'reconcile is off by default');
select tests.eq((public.billing_reconcile_config() ->> 'dry_run')::boolean, true, 'dry-run is on by default');

-- Other suites leave live Google subscriptions behind: park them, so that only the four
-- subscriptions of this suite can be due.
insert into public.billing_reconcile_state (subscription_id, next_check_at)
select s.id, now() + interval '30 days' from public.subscriptions s
 where s.family_account_id not in (:'acct1', :'acct2', :'acct3', :'acct4')
on conflict (subscription_id) do nothing;

-- 3. Claim: only live Google subscriptions, leased once -------------------------------------------
create temp table claim1 as select * from public.billing_reconcile_claim(50, 600);
select tests.eq((select count(*) from claim1), 2::bigint, 'two live Google subscriptions are due (App Store and expired are not)');
select tests.eq((select count(*) from claim1 where provider_subscription_id in ('rec-orig-3', 'rec-tok-4')), 0::bigint,
                'App Store and expired subscriptions are never claimed');
select tests.eq((select count(*) from public.billing_reconcile_claim(50, 600)), 0::bigint,
                'a leased subscription is not handed out again (overlapping runs)');
select tests.eq((select count(*) from public.billing_reconcile_state where lease_until > now()), 2::bigint, 'the lease is stored');

-- An expired lease frees the row (crashed run).
update public.billing_reconcile_state set lease_until = now() - interval '1 minute';
select tests.eq((select count(*) from public.billing_reconcile_claim(1, 600)), 1::bigint, 'an expired lease is claimable again; the limit is honoured');

-- 4. Finish: schedule and back-off ------------------------------------------------------------------
select id as sub1 from public.subscriptions where provider_subscription_id = 'rec-tok-1' \gset
select id as sub2 from public.subscriptions where provider_subscription_id = 'rec-tok-2' \gset
update public.billing_reconcile_state set lease_until = now() where subscription_id = :'sub1';

select public.billing_reconcile_finish(:'sub1', 'ok');
select tests.eq((select lease_until is null and failure_count = 0 and last_checked_at is not null from public.billing_reconcile_state where subscription_id = :'sub1'),
                true, 'ok releases the lease and clears failures');
select tests.eq((select next_check_at > now() + interval '12 hours' and next_check_at <= now() + interval '1 day 1 minute'
                   from public.billing_reconcile_state where subscription_id = :'sub1'),
                true, 'a renewal 20 days away is looked at daily (refund / revoke detection)');

select public.billing_reconcile_finish(:'sub1', 'error', 'temporary_error');
select tests.eq((select failure_count from public.billing_reconcile_state where subscription_id = :'sub1'), 1, 'first error counts');
select tests.eq((select next_check_at <= now() + interval '15 minutes 1 second' from public.billing_reconcile_state where subscription_id = :'sub1'),
                true, 'first retry after 15 minutes');
select public.billing_reconcile_finish(:'sub1', 'error', 'temporary_error');
select tests.eq((select next_check_at between now() + interval '55 minutes' and now() + interval '61 minutes'
                   from public.billing_reconcile_state where subscription_id = :'sub1'),
                true, 'second retry after about one hour (exponential back-off)');
select public.billing_reconcile_finish(:'sub1', 'error', 'temporary_error');
select public.billing_reconcile_finish(:'sub1', 'error', 'temporary_error');
select public.billing_reconcile_finish(:'sub1', 'error', 'temporary_error');
select tests.eq((select next_check_at <= now() + interval '24 hours 1 minute' from public.billing_reconcile_state where subscription_id = :'sub1'),
                true, 'the back-off is capped at 24 hours');
select tests.eq((select last_error_code from public.billing_reconcile_state where subscription_id = :'sub1'), 'temporary_error',
                'only the safe code is stored');
select public.billing_reconcile_finish(:'sub1', 'ok');
select tests.eq((select failure_count from public.billing_reconcile_state where subscription_id = :'sub1'), 0, 'a good read resets the back-off');

-- the schedule policy itself
select tests.eq(public.billing_reconcile_next_check('active', now() + interval '30 days', 0) between now() + interval '23 hours' and now() + interval '1 day 1 minute',
                true, 'far renewal: daily');
select tests.eq(public.billing_reconcile_next_check('active', now() + interval '36 hours', 0) between now() + interval '55 minutes' and now() + interval '1 day',
                true, 'renewal in 36 h: at most daily, then closer');
select tests.eq(public.billing_reconcile_next_check('active', now() + interval '3 hours', 0) between now() + interval '59 minutes' and now() + interval '61 minutes',
                true, 'renewal within two days: hourly');
select tests.eq(public.billing_reconcile_next_check('active', now() - interval '1 hour', 0) between now() + interval '14 minutes' and now() + interval '16 minutes',
                true, 'just past the period end: every 15 minutes');
select tests.eq(public.billing_reconcile_next_check('grace', now() - interval '1 day', 0) between now() + interval '59 minutes' and now() + interval '61 minutes',
                true, 'grace: hourly');
select tests.eq(public.billing_reconcile_next_check('past_due', now() - interval '1 day', 0) between now() + interval '359 minutes' and now() + interval '361 minutes',
                true, 'hold: every six hours');

-- replaced by Play (plan change): keeps its state, remembers why
select public.billing_reconcile_finish(:'sub2', 'replaced', 'replaced');
select tests.eq((select last_error_code from public.billing_reconcile_state where subscription_id = :'sub2'), 'replaced', 'a replacement is recorded');
select tests.eq((select status from public.subscriptions where id = :'sub2'), 'active', 'finish never changes the subscription itself');

-- 5. Server-side acknowledgement bookkeeping ---------------------------------------------------------
select public.billing_reconcile_note_ack('rec-tok-1', 'pending');
select tests.eq((select ack_state from public.billing_reconcile_state where subscription_id = :'sub1'), 'pending', 'ack pending is tracked');
select tests.eq((select ack_first_seen_at is not null from public.billing_reconcile_state where subscription_id = :'sub1'), true, 'first sighting time is stored');
select public.billing_reconcile_note_ack('rec-tok-1', 'failed', 'google_403');
select tests.eq((select ack_attempts from public.billing_reconcile_state where subscription_id = :'sub1'), 1, 'a failed ack counts an attempt');
select tests.eq((select ack_last_error_code from public.billing_reconcile_state where subscription_id = :'sub1'), 'google_403', 'ack failure code is kept apart from the entitlement');
update public.billing_reconcile_state set ack_first_seen_at = now() - interval '25 hours' where subscription_id = :'sub1';
select tests.eq((public.billing_reconcile_health() ->> 'ack_at_risk_24h')::integer, 1, 'health flags an ack pending for more than 24 h');
select public.billing_reconcile_note_ack('rec-tok-1', 'acknowledged');
select tests.eq((select ack_state = 'acknowledged' and acknowledged_at is not null and ack_last_error_code is null
                   from public.billing_reconcile_state where subscription_id = :'sub1'), true, 'acknowledged clears the error');
select tests.eq((public.billing_reconcile_health() ->> 'ack_at_risk_24h')::integer, 0, 'an acknowledged purchase is no longer at risk');
select public.billing_reconcile_note_ack('no-such-token', 'pending');
select tests.eq((select count(*) from public.billing_reconcile_state where ack_state = 'pending'), 0::bigint, 'an unknown token is ignored');
select tests.expect_error($q$select public.billing_reconcile_note_ack('rec-tok-1', 'bogus')$q$, 'unknown ack state');

-- 6. Voided purchases: only known ones pass the filter ---------------------------------------------------
select tests.eq(public.billing_voided_known(array['rec-tok-1', 'ghost-token'], array['GPA.ghost'])::text,
                '{"orders": [], "tokens": ["rec-tok-1"]}', 'unknown tokens / orders are filtered out');
select tests.eq(public.billing_voided_known(null, null)::text, '{"orders": [], "tokens": []}', 'null input is safe');
select tests.eq(public.billing_voided_known(array['rec-orig-3'], '{}')::text, '{"orders": [], "tokens": []}', 'an App Store id never matches a Google token');

-- 7. Cursor only moves forward ----------------------------------------------------------------------------
select tests.eq(public.billing_reconcile_cursor_get('voided'), null::bigint, 'no cursor yet');
select public.billing_reconcile_cursor_set('voided', 2000);
select public.billing_reconcile_cursor_set('voided', 1000);
select tests.eq(public.billing_reconcile_cursor_get('voided'), 2000::bigint, 'the cursor never moves back');
select public.billing_reconcile_cursor_set('voided', 3000);
select tests.eq(public.billing_reconcile_cursor_get('voided'), 3000::bigint, 'the cursor moves forward');

-- 8. Run log / circuit breaker input ------------------------------------------------------------------------
select public.billing_reconcile_record_run('{"dry_run": true, "downgrades": 9}');
select public.billing_reconcile_record_run('{"dry_run": false, "downgrades": 3, "checked": 10}');
select tests.eq(public.billing_reconcile_recent_downgrades(60), 3, 'dry runs never count as applied removals');
update public.billing_reconcile_runs set started_at = now() - interval '3 hours' where downgrades = 3;
select tests.eq(public.billing_reconcile_recent_downgrades(60), 0, 'old runs fall out of the window');
select tests.eq(public.billing_reconcile_recent_downgrades(300), 3, 'a longer window sees them');
select tests.eq((public.billing_reconcile_health() -> 'last_run' ->> 'downgrades')::integer, 3, 'health reports the last run');

-- 9. Reconcile bookkeeping never touches entitlements ----------------------------------------------------------
select tests.eq((select count(*) from public.subscriptions where family_account_id in (:'acct1', :'acct2', :'acct3', :'acct4')), 4::bigint,
                'no subscription was created or removed');
select tests.eq((select string_agg(status, ',' order by provider_subscription_id) from public.subscriptions
                  where family_account_id in (:'acct1', :'acct2', :'acct3', :'acct4')),
                'active,active,active,expired', 'no subscription status changed');

-- 10. Service role only ----------------------------------------------------------------------------------------
set role authenticated;
select tests.login('ca000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select * from public.billing_reconcile_claim(10, 60)$q$, 'permission denied');
select tests.expect_error($q$select public.billing_reconcile_finish(gen_random_uuid(), 'ok')$q$, 'permission denied');
select tests.expect_error($q$select public.billing_reconcile_note_ack('rec-tok-1', 'acknowledged')$q$, 'permission denied');
select tests.expect_error($q$select public.billing_voided_known('{}', '{}')$q$, 'permission denied');
select tests.expect_error($q$select public.billing_reconcile_cursor_set('x', 1)$q$, 'permission denied');
select tests.expect_error($q$select public.billing_reconcile_record_run('{}')$q$, 'permission denied');
select tests.expect_error($q$select public.billing_reconcile_health()$q$, 'permission denied');
select tests.expect_error($q$select public.billing_reconcile_config()$q$, 'permission denied');
select tests.expect_error($q$select * from public.billing_reconcile_state$q$, 'permission denied');
select tests.expect_error($q$select * from public.billing_reconcile_runs$q$, 'permission denied');
select tests.expect_error($q$select * from public.billing_reconcile_cursors$q$, 'permission denied');
select tests.logout();
set role anon;
select tests.expect_error($q$select * from public.billing_reconcile_claim(10, 60)$q$, 'permission denied');
reset role;
select tests.logout();
select tests.eq((select has_function_privilege('service_role', 'public.billing_reconcile_claim(integer, integer)', 'execute')), true, 'service_role may run the claim');

-- 11. Plan change in Play: the new token continues the same subscription row ---------------------------------
select tests.eq(public.billing_apply_event('google_play', 'rec-plan-1', 'reconcile', json_build_object(
  'provider_subscription_id', 'rec-tok-1-new', 'previous_provider_subscription_id', 'rec-tok-1',
  'provider_product_id', 'small_family:annual', 'status', 'active',
  'current_period_start', now(), 'current_period_end', now() + interval '1 year')::jsonb),
  'applied', 'a linked purchase token continues the existing subscription (no intent needed)');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'acct1'), 1::bigint, 'still exactly one subscription');
select tests.eq((select provider_subscription_id from public.subscriptions where family_account_id = :'acct1'), 'rec-tok-1-new',
                'the row now follows the new token');
select tests.eq((select billing_period from public.subscriptions where family_account_id = :'acct1'), 'annual', 'the plan change is applied');
update public.billing_reconcile_state set next_check_at = now() - interval '1 minute', lease_until = null where subscription_id = :'sub1';
select tests.eq((select c.provider_subscription_id from public.billing_reconcile_claim(50, 600) c where c.subscription_id = :'sub1'),
                'rec-tok-1-new', 'reconcile state is keyed by the row: the claim already returns the new token');
select tests.eq((select count(*) from public.billing_reconcile_state where subscription_id = :'sub1'), 1::bigint, 'one state row per subscription');
-- the replaced token can no longer reach the subscription through the reconcile claim
select tests.eq((select count(*) from public.subscriptions where provider_subscription_id = 'rec-tok-1'), 0::bigint, 'the old token is gone from the row');

-- 12. The access gate honours the two-day slack end to end -----------------------------------------------------
update public.subscriptions set current_period_end = now() - interval '36 hours' where id = :'sub2';
select enabled as enforcement_before from public.platform_flags where key = 'subscription_enforcement' \gset
update public.platform_flags set enabled = true where key = 'subscription_enforcement';
select tests.eq(public.baby_subscription_ok(:'baby2'), true, 'a baby keeps access 36 h after the period end (renewal not yet seen)');
update public.subscriptions set current_period_end = now() - interval '3 days' where id = :'sub2';
select tests.eq(public.baby_subscription_ok(:'baby2'), false, 'no access once the slack is over');
update public.subscriptions set current_period_end = now() - interval '1 hour', status = 'expired' where id = :'sub2';
select tests.eq(public.baby_subscription_ok(:'baby2'), false, 'a refunded / revoked (expired) subscription gets no slack');
update public.subscriptions set current_period_end = now() + interval '5 days', status = 'past_due' where id = :'sub2';
select tests.eq(public.baby_subscription_ok(:'baby2'), false, 'a held subscription gets no access');
update public.platform_flags set enabled = :'enforcement_before' where key = 'subscription_enforcement';
