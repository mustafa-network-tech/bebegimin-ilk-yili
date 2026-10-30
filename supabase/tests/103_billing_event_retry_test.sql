-- Verified store purchases: rejected deliveries can be re-verified, success is
-- reported only from the stored state, and Google Play honours an intent that
-- expired after the purchase began (migration 20261028000100).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('cb000000-0000-4000-8000-000000000001', 'retry-anne@example.com'),
  ('cb000000-0000-4000-8000-000000000002', 'retry-baba@example.com'),
  ('cb000000-0000-4000-8000-000000000003', 'retry-dede@example.com'),
  ('cb000000-0000-4000-8000-000000000004', 'retry-nine@example.com');

-- One family account + Google Play checkout intent per scenario.
set role authenticated;
select tests.login('cb000000-0000-4000-8000-000000000001');
select (public.create_baby('Yeniden', public.business_date_istanbul() - 20, 'anne')).id as baby1 \gset
select public.family_account_id_for_baby(:'baby1') as acct1 \gset
select intent_id as intent1 from public.request_subscription_checkout(:'acct1', 'small_family', 'monthly', 'google_play') \gset

select tests.login('cb000000-0000-4000-8000-000000000002');
select (public.create_baby('Gecikmis', public.business_date_istanbul() - 20, 'baba')).id as baby2 \gset
select public.family_account_id_for_baby(:'baby2') as acct2 \gset
select intent_id as intent2 from public.request_subscription_checkout(:'acct2', 'small_family', 'annual', 'google_play') \gset

select tests.login('cb000000-0000-4000-8000-000000000003');
select (public.create_baby('Gec', public.business_date_istanbul() - 20, 'anne')).id as baby3 \gset
select public.family_account_id_for_baby(:'baby3') as acct3 \gset
select intent_id as intent3 from public.request_subscription_checkout(:'acct3', 'small_family', 'monthly', 'google_play') \gset
select intent_id as intent3_apple from public.request_subscription_checkout(:'acct3', 'small_family', 'monthly', 'app_store') \gset

select tests.login('cb000000-0000-4000-8000-000000000004');
select (public.create_baby('Bitmis', public.business_date_istanbul() - 20, 'anne')).id as baby4 \gset
select public.family_account_id_for_baby(:'baby4') as acct4 \gset
select intent_id as intent4 from public.request_subscription_checkout(:'acct4', 'small_family', 'monthly', 'google_play') \gset
reset role;
select tests.logout();

-- 1. A rejected delivery is not a success and can be verified again ----------------------------
select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000001', 'google_play', 'ret-1',
  json_build_object('bound_intent_id', :'intent1', 'provider_subscription_id', 'tok-ret-1',
                    'provider_product_id', 'ghost_family:monthly', 'status', 'active')::jsonb),
  'rejected', 'an unknown product is rejected, not reported as success');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'acct1'), 0::bigint,
                'a rejected purchase grants no subscription');
select tests.eq((select error from public.billing_events where provider = 'google_play' and provider_event_id = 'ret-1'),
                'unknown provider product', 'the rejection reason is stored for diagnosis');

select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000001', 'google_play', 'ret-1',
  json_build_object('bound_intent_id', :'intent1', 'provider_subscription_id', 'tok-ret-1',
                    'provider_product_id', 'small_family:monthly', 'status', 'active',
                    'current_period_end', now() + interval '1 month')::jsonb),
  'applied', 'the same event id is re-verified after a rejection');
select tests.eq((select count(*) from public.billing_events where provider = 'google_play' and provider_event_id like 'ret-1%'),
                2::bigint, 'both attempts stay in the append-only history');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'acct1'), 1::bigint,
                'exactly one subscription after the retry');

-- 2. An applied event is never applied twice; the real state is confirmed -----------------------
select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000001', 'google_play', 'ret-1',
  json_build_object('bound_intent_id', :'intent1', 'provider_subscription_id', 'tok-ret-1',
                    'provider_product_id', 'small_family:monthly', 'status', 'active',
                    'current_period_end', now() + interval '1 month')::jsonb),
  'duplicate', 'a replay of an applied event is a confirmed duplicate');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'acct1'), 1::bigint,
                'a duplicate never creates a second subscription');
select tests.eq((select count(*) from public.billing_events where provider = 'google_play' and provider_event_id like 'ret-1%'),
                2::bigint, 'a duplicate adds no history row');

-- 3. Retries are bounded -----------------------------------------------------------------------------
select public.billing_apply_event('google_play', 'cap-1', 'x',
  json_build_object('bound_intent_id', :'intent3', 'provider_subscription_id', 'tok-cap',
                    'provider_product_id', 'ghost_family:monthly', 'status', 'active')::jsonb)
  from generate_series(1, 8);
select tests.eq((select count(*) from public.billing_events where provider = 'google_play' and provider_event_id like 'cap-1%'),
                5::bigint, 'a permanently rejected event is recorded at most five times');

-- 4. Google Play: an intent that expired after the purchase began is honoured ---------------
update public.subscription_checkout_intents set expires_at = now() - interval '1 hour' where id = :'intent2';
select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000002', 'google_play', 'late-1',
  json_build_object('bound_intent_id', :'intent2', 'provider_subscription_id', 'tok-late',
                    'provider_product_id', 'small_family:annual', 'status', 'active',
                    'current_period_start', now() - interval '2 hours',
                    'current_period_end', now() + interval '1 year')::jsonb),
  'applied', 'delayed verification / restore after the intent window works');
select tests.eq((select status from public.subscription_checkout_intents where id = :'intent2'), 'consumed',
                'the late intent is consumed exactly once');

-- ... but never for a purchase that began after the intent expired, nor for the App Store.
update public.subscription_checkout_intents set expires_at = now() - interval '1 hour' where id = :'intent3';
select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000003', 'google_play', 'late-2',
  json_build_object('bound_intent_id', :'intent3', 'provider_subscription_id', 'tok-late-2',
                    'provider_product_id', 'small_family:monthly', 'status', 'active',
                    'current_period_start', now(),
                    'current_period_end', now() + interval '1 month')::jsonb),
  'rejected', 'a purchase that began after the intent expired is rejected');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'acct3'), 0::bigint,
                'no subscription for a purchase that began after the intent expired');
update public.subscription_checkout_intents set expires_at = now() - interval '1 hour' where id = :'intent3_apple';
select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000003', 'app_store', 'late-3',
  json_build_object('bound_intent_id', :'intent3_apple', 'provider_subscription_id', 'orig-late',
                    'provider_product_id', 'bebegimin.small_family.monthly', 'status', 'active',
                    'current_period_start', now() - interval '2 hours')::jsonb),
  'rejected', 'the expiry relaxation is Google Play only');

-- 5. Verified with the store but expired: no access is reported ----------------------------------
select tests.eq(public.billing_apply_verified_purchase('cb000000-0000-4000-8000-000000000004', 'google_play', 'inactive-1',
  json_build_object('bound_intent_id', :'intent4', 'provider_subscription_id', 'tok-inactive',
                    'provider_product_id', 'small_family:monthly', 'status', 'expired',
                    'current_period_end', now() - interval '3 days')::jsonb),
  'inactive', 'an expired subscription is verified but never reported as active');

-- 6. Another family's purchase is still refused -------------------------------------------------------
select tests.expect_error(format($q$select public.billing_apply_verified_purchase(%L, 'google_play', 'steal-1', %L::jsonb)$q$,
  'cb000000-0000-4000-8000-000000000004',
  json_build_object('provider_subscription_id', 'tok-ret-1', 'provider_product_id', 'small_family:monthly', 'status', 'active')),
  'purchase_not_yours');
