-- Phase 7: premium catalog, orders and baby-scoped entitlements.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('9c000000-0000-4000-8000-000000000001', 'premium-anne@example.com'),
  ('9c000000-0000-4000-8000-000000000002', 'premium-baba@example.com'),
  ('9c000000-0000-4000-8000-000000000011', 'premium-teyze@example.com'),
  ('9c000000-0000-4000-8000-000000000021', 'premium-yabanci@example.com');

-- Defne-like LOCKED baby and Ece-like second LOCKED baby, plus an ACTIVE one.
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000001');
select (public.create_baby('Kilitli', public.business_date_istanbul() - 400, 'anne')).id as locked_baby \gset
select (public.create_baby('Kardeş', public.business_date_istanbul() - 380, 'anne')).id as sibling \gset
select (public.create_baby('Açık', public.business_date_istanbul() - 30, 'anne')).id as active_baby \gset
select public.family_account_id_for_baby(:'locked_baby') as acct \gset
select status as life_before, effective_close_date as close_before from public.baby_lifecycle_summary(:'locked_baby') \gset
reset role;
select tests.logout();
insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'locked_baby', 'PREMBABA22', 'baba', true, '{}', '9c000000-0000-4000-8000-000000000001'),
  (:'locked_baby', 'PREMTEYZ22', 'teyze', false, '{view_memories,view_album}', '9c000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000002');
select public.accept_invitation('PREMBABA22');
select tests.login('9c000000-0000-4000-8000-000000000011');
select public.accept_invitation('PREMTEYZ22');

-- Catalog ---------------------------------------------------------------------------------
select tests.login('9c000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select * from public.premium_products$q$, 'permission denied');
select tests.expect_error($q$select * from public.product_entitlements$q$, 'permission denied');
select tests.eq((select string_agg(product_code || '=' || price_minor, ',' order by price_minor) from public.premium_store_products('app_store') s
                   join public.premium_storefront(:'locked_baby') f using (product_code)),
                'first_year_book=34900,first_year_html=44900,first_year_film=54900', 'premium catalog prices 34900 / 44900 / 54900 TRY');
select tests.eq((select bool_and(currency = 'TRY') from public.premium_storefront(:'locked_baby')), true, 'TRY only');
select tests.eq((select delivery_format from public.premium_storefront(:'locked_baby') where product_code = 'first_year_book'), 'pdf',
                'digital book is a PDF');
select tests.eq((select string_agg(provider_product_id, ',' order by provider_product_id) from public.premium_store_products('google_play')),
                'first_year_book,first_year_film,first_year_html', 'Google Play product ids');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.premium_products where price_minor not in (34900, 44900, 54900)), 0::bigint,
                'no retired or draft premium prices in the catalog');
select tests.expect_error($q$update public.premium_products set price_minor = 29900 where code = 'first_year_book'$q$, 'immutable');

-- Eligibility -----------------------------------------------------------------------------------
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.premium_storefront(%L)', :'active_baby'), 'premium_requires_locked');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'active_baby', 'first_year_book', 'app_store'),
                          'premium_requires_locked');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_book', 'app_store'),
                          'subscription_required');
reset role;
select tests.logout();
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'premium-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'small_family' and p.billing_period = 'monthly';
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_book', 'app_store'),
                          'storefront_closed');
select tests.eq((select purchase_block from public.premium_storefront(:'locked_baby') where product_code = 'first_year_book'),
                'storefront_closed', 'storefront shows the kill switch');
reset role;
select tests.logout();
update public.platform_flags set enabled = true where key = 'premium_storefront';
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000011');
select tests.expect_error(format('select * from public.premium_storefront(%L)', :'locked_baby'), 'not_parent');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_book', 'app_store'),
                          'not_parent');
select tests.login('9c000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_book', 'app_store'),
                          'not found');

-- Anne buys the book for the locked baby ---------------------------------------------------------
select tests.login('9c000000-0000-4000-8000-000000000001');
select order_id as book_order, provider_product_id as book_store_id, price_minor as book_price
  from public.request_premium_purchase(:'locked_baby', 'first_year_book', 'app_store') \gset
select tests.eq(:'book_store_id'::text, 'bebegimin.first_year_book', 'order carries the store product id');
select tests.eq(:book_price, 34900, 'order price comes from the catalog');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_book', 'paypal'), 'unknown provider');
select tests.expect_error($q$select public.premium_apply_event('app_store', 'x', 'y', '{}'::jsonb)$q$, 'permission denied');

reset role;
select tests.logout();
-- No entitlement without a verified payment; wrong price / currency / product / order are refused.
select tests.eq(public.premium_apply_event('app_store', 'p-price', 'ONE_TIME', json_build_object(
  'provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order', 'provider_product_id', 'bebegimin.first_year_book',
  'status', 'paid', 'price_minor', 100, 'currency', 'TRY')::jsonb), 'rejected', 'wrong price is rejected');
select tests.eq(public.premium_apply_event('app_store', 'p-currency', 'ONE_TIME', json_build_object(
  'provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order', 'provider_product_id', 'bebegimin.first_year_book',
  'status', 'paid', 'price_minor', 34900, 'currency', 'USD')::jsonb), 'rejected', 'wrong currency is rejected');
select tests.eq(public.premium_apply_event('app_store', 'p-product', 'ONE_TIME', json_build_object(
  'provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order', 'provider_product_id', 'bebegimin.first_year_film',
  'status', 'paid')::jsonb), 'rejected', 'another product cannot pay this order');
select tests.eq(public.premium_apply_event('app_store', 'p-noorder', 'ONE_TIME', json_build_object(
  'provider_order_ref', 'tx-orphan', 'provider_product_id', 'bebegimin.first_year_book', 'status', 'paid')::jsonb),
  'rejected', 'a payment without an order is rejected');
select tests.eq(public.premium_apply_event('app_store', 'p-mismatch', 'ONE_TIME', json_build_object(
  'provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order', 'order_id', gen_random_uuid(),
  'provider_product_id', 'bebegimin.first_year_book', 'status', 'paid')::jsonb), 'rejected', 'client claim must match the store binding');
select tests.eq((select count(*) from public.product_entitlements where baby_id = :'locked_baby'), 0::bigint, 'nothing granted so far');
select tests.expect_error(format($q$select public.premium_apply_verified_purchase(%L, 'app_store', 'v-outsider', %L::jsonb)$q$,
  '9c000000-0000-4000-8000-000000000021', json_build_object('provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order',
  'provider_product_id', 'bebegimin.first_year_book', 'status', 'paid')), 'purchase_not_yours');
select tests.expect_error(format($q$select public.premium_apply_verified_purchase(%L, 'app_store', 'v-member', %L::jsonb)$q$,
  '9c000000-0000-4000-8000-000000000011', json_build_object('provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order',
  'provider_product_id', 'bebegimin.first_year_book', 'status', 'paid')), 'purchase_not_yours');

select tests.eq(public.premium_apply_verified_purchase('9c000000-0000-4000-8000-000000000001', 'app_store', 'v-book-1', json_build_object(
  'provider_order_ref', 'tx-book-1', 'bound_order_id', :'book_order', 'provider_product_id', 'bebegimin.first_year_book',
  'status', 'paid', 'price_minor', 34900, 'currency', 'TRY')::jsonb), 'applied', 'verified payment grants the book');
select tests.eq(public.premium_apply_verified_purchase('9c000000-0000-4000-8000-000000000001', 'app_store', 'v-book-1', '{}'::jsonb
  || json_build_object('provider_order_ref', 'tx-book-1', 'provider_product_id', 'bebegimin.first_year_book', 'status', 'paid')::jsonb),
  'duplicate', 'receipt replay is a no-op');
select tests.eq(public.premium_apply_event('app_store', 'n-book-1', 'ONE_TIME_CHARGE', json_build_object(
  'provider_order_ref', 'tx-book-1', 'provider_product_id', 'bebegimin.first_year_book', 'status', 'paid')::jsonb),
  'applied', 'store notification for the same purchase');
select tests.eq((select count(*) from public.product_entitlements where baby_id = :'locked_baby'), 1::bigint,
                'replays never create a second entitlement');
select tests.eq((select family_account_id from public.product_entitlements where baby_id = :'locked_baby'), :'acct'::uuid,
                'entitlement belongs to the family account, not the purchaser');

-- Anne's purchase is Baba's too; products and babies stay independent ---------------------------
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000002');
select tests.eq((select owned from public.premium_storefront(:'locked_baby') where product_code = 'first_year_book'), true,
                'Baba sees the book Anne bought');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_book', 'google_play'),
                          'already_owned');
select tests.eq((select owned from public.premium_storefront(:'locked_baby') where product_code = 'first_year_film'), false,
                'book does not unlock the film');
select tests.eq((select owned from public.premium_storefront(:'locked_baby') where product_code = 'first_year_html'), false,
                'book does not unlock the offline HTML');
select tests.login('9c000000-0000-4000-8000-000000000001');
select tests.eq((select owned from public.premium_storefront(:'sibling') where product_code = 'first_year_book'), false,
                'one baby''s book does not unlock the sibling');
select tests.login('9c000000-0000-4000-8000-000000000011');
select tests.eq((select string_agg(product_code, ',') from public.baby_entitlements(:'locked_baby')), 'first_year_book',
                'family members see owned products');
select tests.login('9c000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.baby_entitlements(%L)', :'locked_baby'), 'not found');

-- Two open orders for the same product: only one entitlement ever ------------------------------
select tests.login('9c000000-0000-4000-8000-000000000001');
select order_id as film_a from public.request_premium_purchase(:'locked_baby', 'first_year_film', 'google_play') \gset
select order_id as film_b from public.request_premium_purchase(:'locked_baby', 'first_year_film', 'google_play') \gset
reset role;
select tests.logout();
select tests.eq(public.premium_apply_event('google_play', 'g-film-a', 'rtdn.1', json_build_object(
  'provider_order_ref', 'GPA.1', 'bound_order_id', :'film_a', 'provider_product_id', 'first_year_film', 'status', 'paid')::jsonb),
  'applied', 'first film payment grants the film');
select tests.eq(public.premium_apply_event('google_play', 'g-film-b', 'rtdn.1', json_build_object(
  'provider_order_ref', 'GPA.2', 'bound_order_id', :'film_b', 'provider_product_id', 'first_year_film', 'status', 'paid')::jsonb),
  'duplicate_payment', 'a second payment is flagged, not granted twice');
select tests.eq((select count(*) from public.product_entitlements where baby_id = :'locked_baby' and product_code = 'first_year_film'),
                1::bigint, 'one film entitlement');

-- Refund revokes (append-only), a new purchase can follow ----------------------------------------
select tests.eq(public.premium_apply_event('google_play', 'g-film-a-void', 'voided', json_build_object(
  'provider_order_ref', 'GPA.1', 'status', 'refunded')::jsonb),
  'applied', 'refund applied (voided notifications carry no product id)');
select tests.eq(public.premium_apply_event('google_play', 'g-film-nopid', 'rtdn.1', json_build_object(
  'provider_order_ref', 'GPA.2', 'status', 'paid')::jsonb),
  'rejected', 'a payment without a product id never grants');
select tests.eq((select status from public.product_entitlements where source_order_id = :'film_a'), 'revoked', 'refund revokes the entitlement');
select tests.eq((select status from public.premium_orders where id = :'film_a'), 'refunded', 'order marked refunded');
select tests.eq(public.premium_apply_event('google_play', 'g-film-a-again', 'rtdn.1', json_build_object(
  'provider_order_ref', 'GPA.1', 'provider_product_id', 'first_year_film', 'status', 'paid')::jsonb),
  'rejected', 'a refunded order cannot be paid again');
select tests.expect_error($q$delete from public.product_entitlements$q$, 'permanent');
select tests.expect_error($q$update public.product_entitlements set status = 'active', revoked_at = null where status = 'revoked'$q$, 'immutable');
select tests.expect_error($q$delete from public.premium_order_events$q$, 'append-only');
select tests.eq((select count(*) from public.premium_order_events where order_id = :'film_a'), 2::bigint, 'purchase and refund both recorded');
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000001');
select order_id as film_c from public.request_premium_purchase(:'locked_baby', 'first_year_film', 'mock') \gset
reset role;
select tests.logout();
select tests.eq(public.premium_apply_event('mock', 'm-film-c', 'paid', json_build_object(
  'provider_order_ref', 'mock-3', 'order_id', :'film_c', 'provider_product_id', 'mock.first_year_film', 'status', 'paid')::jsonb),
  'applied', 'repurchase after refund');
select tests.eq((select count(*) from public.product_entitlements where baby_id = :'locked_baby' and product_code = 'first_year_film' and status = 'active'),
                1::bigint, 'exactly one active film entitlement again');

-- Lifecycle and subscription stay independent ----------------------------------------------------
update public.subscriptions set status = 'canceled' where provider_subscription_id = 'premium-sub';
select tests.eq((select count(*) from public.product_entitlements where baby_id = :'locked_baby' and status = 'active'), 2::bigint,
                'a lapsed subscription never removes entitlements');
set role authenticated;
select tests.login('9c000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'locked_baby', 'first_year_html', 'app_store'),
                          'subscription_required');
select tests.eq((select status from public.baby_lifecycle_summary(:'locked_baby')), :'life_before', 'purchases never change the lifecycle');
select tests.eq((select effective_close_date from public.baby_lifecycle_summary(:'locked_baby')), :'close_before'::date, 'close date unchanged');

-- Routing helper for receipts / notifications
reset role;
select tests.logout();
select tests.eq(public.store_product_kind('app_store', 'bebegimin.first_year_book'), 'premium', 'premium product routed');
select tests.eq(public.store_product_kind('app_store', 'bebegimin.small_family.monthly'), 'subscription', 'subscription product routed');
select tests.eq(public.store_product_kind('app_store', 'unknown'), null::text, 'unknown product not routed');
update public.platform_flags set enabled = false where key = 'premium_storefront';
