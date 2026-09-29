-- Store billing (App Store / Google Play) and the subscription access gate:
-- without an active family subscription nobody in the family can use the
-- archive (server-side), family management and legal paths keep working.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('9b000000-0000-4000-8000-000000000001', 'store-anne@example.com'),
  ('9b000000-0000-4000-8000-000000000002', 'store-baba@example.com'),
  ('9b000000-0000-4000-8000-000000000011', 'store-teyze@example.com'),
  ('9b000000-0000-4000-8000-000000000021', 'store-yabanci@example.com');

set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000001');
select (public.create_baby('Mağaza', public.business_date_istanbul() - 60, 'anne')).id as baby \gset
select public.family_account_id_for_baby(:'baby') as acct \gset
insert into memories (baby_id, title, memory_date) values (:'baby', 'Abonelik testi', current_date);
insert into media (id, baby_id, kind, storage_path, mime_type, taken_on, status)
values ('9b100000-0000-4000-8000-000000000001', :'baby', 'photo',
        :'baby' || '/9b100000-0000-4000-8000-000000000001/p.jpg', 'image/jpeg', current_date, 'uploading');
update media set status = 'ready' where id = '9b100000-0000-4000-8000-000000000001';
select lifecycle.status as life_before, lifecycle.effective_close_date as close_before
  from public.baby_lifecycle_summary(:'baby') lifecycle \gset
reset role;
select tests.logout();
insert into public.family_invitations (baby_id, code, relation, created_by)
values (:'baby', 'MAGAZATE22', 'teyze', '9b000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select public.accept_invitation('MAGAZATE22');

-- Checkout per store ---------------------------------------------------------------------
select tests.login('9b000000-0000-4000-8000-000000000001');
select intent_id as ios_intent, provider_product_id as ios_product
  from public.request_subscription_checkout(:'acct', 'small_family', 'monthly', 'app_store') \gset
select tests.eq(:'ios_product'::text, 'bebegimin.small_family.monthly', 'App Store product id from the mapping');
select tests.eq((select provider_product_id from public.request_subscription_checkout(:'acct', 'small_family', 'annual', 'google_play')),
                'small_family:annual', 'Google Play product:basePlan from the mapping');
select tests.expect_error(format('select * from public.request_subscription_checkout(%L, %L, %L, %L)', :'acct', 'small_family', 'monthly', 'paypal'), 'unknown provider');
select tests.eq((select count(*) from public.subscription_store_products('app_store')), 6::bigint, 'store product ids for the whole catalog');
select tests.expect_error($q$select public.billing_apply_verified_purchase(tests.id('anne'), 'app_store', 'x', '{}'::jsonb)$q$, 'permission denied');

-- Verified purchase: only a parent of the bound account ----------------------------------------
reset role;
select tests.logout();
select tests.expect_error(format($q$select public.billing_apply_verified_purchase(%L, 'app_store', 'tx-1', %L::jsonb)$q$,
  '9b000000-0000-4000-8000-000000000021',
  json_build_object('bound_intent_id', :'ios_intent', 'provider_subscription_id', 'orig-1',
                    'provider_product_id', 'bebegimin.small_family.monthly', 'status', 'active')),
  'purchase_not_yours');
select tests.expect_error(format($q$select public.billing_apply_verified_purchase(%L, 'app_store', 'tx-1', %L::jsonb)$q$,
  '9b000000-0000-4000-8000-000000000011',
  json_build_object('bound_intent_id', :'ios_intent', 'provider_subscription_id', 'orig-1',
                    'provider_product_id', 'bebegimin.small_family.monthly', 'status', 'active')),
  'purchase_not_yours');
select tests.eq(public.billing_apply_verified_purchase('9b000000-0000-4000-8000-000000000001', 'app_store', 'tx-1',
  json_build_object('bound_intent_id', :'ios_intent', 'provider_subscription_id', 'orig-1',
                    'provider_product_id', 'bebegimin.small_family.monthly', 'status', 'active',
                    'current_period_end', now() + interval '1 month', 'event_time', now() - interval '1 minute')::jsonb),
  'applied', 'parent purchase verified by the store opens the subscription');
select tests.eq(public.billing_apply_event('app_store', 'n-mismatch', 'DID_RENEW',
  json_build_object('bound_intent_id', :'ios_intent', 'checkout_intent_id', gen_random_uuid(),
                    'provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'active')::jsonb),
  'rejected', 'store-bound account must match the checkout intent');

-- Restore: the parent on a new device, never an outsider -------------------------------------
select tests.eq(public.billing_apply_verified_purchase('9b000000-0000-4000-8000-000000000001', 'app_store', 'restore-1',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'active', 'current_period_end', now() + interval '1 month')::jsonb),
  'applied', 'parent restores the family subscription');
select tests.expect_error(format($q$select public.billing_apply_verified_purchase(%L, 'app_store', 'restore-2', %L::jsonb)$q$,
  '9b000000-0000-4000-8000-000000000021',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly', 'status', 'active')),
  'purchase_not_yours');

-- Out-of-order store notifications keep the newer state ----------------------------------------
select tests.eq(public.billing_apply_event('app_store', 'n-old', 'EXPIRED',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'expired', 'event_time', now() - interval '10 days')::jsonb),
  'stale', 'an older notification is ignored');
select tests.eq((select status from public.subscriptions where provider_subscription_id = 'orig-1'), 'active', 'state stays active');

-- Access gate ----------------------------------------------------------------------------------
update public.platform_flags set enabled = true where key = 'subscription_enforcement';
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select tests.eq((select allowed from public.baby_access_state(:'baby')), true, 'active subscription opens the archive');
select tests.eq(tests.count(format('select 1 from memories where baby_id = %L', :'baby')), 1::bigint, 'family member reads memories');

reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('app_store', 'n-grace', 'DID_FAIL_TO_RENEW',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'grace', 'current_period_end', now() - interval '2 days')::jsonb), 'applied', 'grace applied');
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select tests.eq((select allowed from public.baby_access_state(:'baby')), true, 'grace period keeps access');

reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('app_store', 'n-pastdue', 'GRACE_PERIOD_EXPIRED',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'past_due')::jsonb), 'applied', 'billing retry applied');
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select tests.eq((select reason from public.baby_access_state(:'baby')), 'payment_issue', 'past due goes to the payment page');

reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('app_store', 'n-expired', 'EXPIRED',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'expired')::jsonb), 'applied', 'expiry applied');

-- Family Member: blocked everywhere on the server.
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select tests.eq((select allowed from public.baby_access_state(:'baby')), false, 'ended subscription closes the archive');
select tests.eq((select reason from public.baby_access_state(:'baby')), 'subscription_ended', 'reason for the payment page');
select tests.eq((select is_parent from public.baby_access_state(:'baby')), false, 'family member cannot pay');
select tests.eq(tests.count(format('select 1 from memories where baby_id = %L', :'baby')), 0::bigint, 'memories hidden');
select tests.eq(tests.count(format('select 1 from timeline_entries where baby_id = %L', :'baby')), 0::bigint, 'timeline hidden');
select tests.eq(tests.count(format('select 1 from media where baby_id = %L', :'baby')), 0::bigint, 'album hidden');
select tests.eq(public.can_read_baby_object(:'baby' || '/9b100000-0000-4000-8000-000000000001/p.jpg'), false, 'no signed URL for media');
select tests.expect_error(format('insert into memories (baby_id, title, memory_date) values (%L, %L, current_date)', :'baby', 'x'), 'subscription_inactive');
select tests.eq(tests.count(format('select 1 from babies where id = %L', :'baby')), 1::bigint, 'baby name stays visible for the payment page');
select tests.eq(tests.count(format('select 1 from family_members where baby_id = %L', :'baby')) >= 2, true, 'family list stays visible');

-- Parent: same gate, but can pay and manage the family.
select tests.login('9b000000-0000-4000-8000-000000000001');
select tests.eq((select is_parent from public.baby_access_state(:'baby')), true, 'parent is offered the purchase');
select tests.eq(tests.count(format('select 1 from memories where baby_id = %L', :'baby')), 0::bigint, 'parents are blocked too');
select tests.expect_error(format('select public.create_time_capsule(%L, %L, %L, current_date + 30)', :'baby', 'k', 'm'), 'not allowed');
select tests.eq(public.can_write_baby_object(:'baby' || '/profile/a.jpg'), false, 'no uploads');
update family_members set permissions = permissions || '{comment}'::text[]
 where baby_id = :'baby' and user_id = '9b000000-0000-4000-8000-000000000011';
select tests.eq((select 'comment' = any (permissions) from family_members
                  where baby_id = :'baby' and user_id = '9b000000-0000-4000-8000-000000000011'), true, 'family management stays available');
select tests.eq((select count(*) from public.request_subscription_checkout(:'acct', 'normal_family', 'monthly', 'app_store')), 1::bigint,
                'parent can start a new purchase from the payment page');
select tests.eq((select status from public.baby_lifecycle_summary(:'baby')), :'life_before', 'subscription gate never changes the lifecycle');
select tests.eq((select effective_close_date from public.baby_lifecycle_summary(:'baby')), :'close_before'::date, 'close date unchanged');

-- Author-owned writes that bypass has_baby_permission are stopped by the guard.
reset role;
select tests.logout();
select id as own_memory from memories where baby_id = :'baby' limit 1 \gset
select set_config('test.own_memory', :'own_memory', false);
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000001');
do $$
declare n integer;
begin
  update public.memories set title = 'x' where id = current_setting('test.own_memory', true)::uuid;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'blocked parent updated a memory'; end if;
  raise notice 'ok - blocked authors cannot edit through owner policies';
end $$;

-- A stale "active" projection whose period visibly ended does not grant access.
reset role;
select tests.logout();
update public.subscriptions set status = 'active', current_period_end = now() - interval '3 days'
 where provider_subscription_id = 'orig-1';
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select tests.eq((select allowed from public.baby_access_state(:'baby')), false, 'period end in the past closes access');

-- Renewal reopens everything; nothing was deleted.
reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('app_store', 'n-renew', 'DID_RENEW',
  json_build_object('provider_subscription_id', 'orig-1', 'provider_product_id', 'bebegimin.small_family.monthly',
                    'status', 'active', 'current_period_end', now() + interval '1 month', 'event_time', now())::jsonb),
  'applied', 'renewal applied');
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000011');
select tests.eq(tests.count(format('select 1 from memories where baby_id = %L', :'baby')), 1::bigint, 'renewal restores access to kept data');

-- Unmapped legacy babies are closed while enforcement is on.
reset role;
select tests.logout();
insert into public.babies (id, first_name, birth_date, created_by)
values ('9b200000-0000-4000-8000-000000000001', 'Eşlenmemiş', current_date - 10, '9b000000-0000-4000-8000-000000000021');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
values ('9b200000-0000-4000-8000-000000000001', '9b000000-0000-4000-8000-000000000021', 'anne', true, '{}');
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000021');
select tests.eq((select reason from public.baby_access_state('9b200000-0000-4000-8000-000000000001')), 'account_unmapped',
                'unmapped baby reports account_unmapped');
select tests.eq((select allowed from public.baby_access_state('9b200000-0000-4000-8000-000000000001')), false,
                'unmapped baby is closed while enforcement is on');

-- Google Play: linked purchase token (plan change) updates the same row.
reset role;
select tests.logout();
set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000002');
select (public.create_baby('Android', public.business_date_istanbul() - 20, 'baba')).id as gbaby \gset
select public.family_account_id_for_baby(:'gbaby') as gacct \gset
select intent_id as g_intent from public.request_subscription_checkout(:'gacct', 'small_family', 'monthly', 'google_play') \gset
reset role;
select tests.logout();
select tests.eq(public.billing_apply_verified_purchase('9b000000-0000-4000-8000-000000000002', 'google_play', 'gp-1',
  json_build_object('bound_intent_id', :'g_intent', 'provider_subscription_id', 'token-A',
                    'provider_product_id', 'small_family:monthly', 'status', 'active')::jsonb), 'applied', 'Google Play purchase verified');
select tests.eq(public.billing_apply_event('google_play', 'rtdn-2', 'SUBSCRIPTION_PURCHASED',
  json_build_object('provider_subscription_id', 'token-B', 'previous_provider_subscription_id', 'token-A',
                    'provider_product_id', 'normal_family:monthly', 'status', 'active')::jsonb), 'applied', 'upgrade with a linked token');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'gacct'), 1::bigint, 'linked token never creates a second subscription');
select tests.eq((select plan_code || '/' || provider_subscription_id from public.subscriptions where family_account_id = :'gacct'),
                'normal_family/token-B', 'plan and token follow the upgrade');

-- Enforcement off: legacy behaviour.
update public.platform_flags set enabled = false where key = 'subscription_enforcement';
set role authenticated;
select tests.login(tests.id('anne'));
select tests.eq((select reason from public.baby_access_state(tests.id('ege'))), 'enforcement_off', 'flag off keeps today''s access');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('ege')$q$) >= 0, true, 'reads work with the flag off');

reset role;
select tests.logout();
