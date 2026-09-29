-- Phase 6: family accounts, parent seats, plan capacity, provider events,
-- catalog rules and legacy mapping. Uses its own users/babies so the demo
-- fixtures and earlier suites stay independent.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('97000000-0000-4000-8000-000000000001', 'pelin@example.com'),
  ('97000000-0000-4000-8000-000000000002', 'poyraz@example.com'),
  ('97000000-0000-4000-8000-000000000003', 'ucuncu@example.com'),
  ('97000000-0000-4000-8000-000000000011', 'uye1@example.com'),
  ('97000000-0000-4000-8000-000000000012', 'uye2@example.com'),
  ('97000000-0000-4000-8000-000000000013', 'uye3@example.com'),
  ('97000000-0000-4000-8000-000000000014', 'uye4@example.com'),
  ('97000000-0000-4000-8000-000000000015', 'uye5@example.com'),
  ('97000000-0000-4000-8000-000000000021', 'baskaaile@example.com');
update public.profiles set display_name = 'Pelin' where id = '97000000-0000-4000-8000-000000000001';
update public.profiles set display_name = 'Poyraz' where id = '97000000-0000-4000-8000-000000000002';

-- Catalog ----------------------------------------------------------------------------
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000001');
select tests.eq((select count(*) from public.subscription_plan_catalog()), 6::bigint, 'catalog has 3 plans x 2 periods');
select tests.eq((select string_agg(price_minor::text, '/' order by max_family_members) from public.subscription_plan_catalog() where billing_period = 'monthly'),
                '29900/36900/46900', 'monthly prices come from the catalog');
select tests.eq((select string_agg(price_minor::text, '/' order by max_family_members) from public.subscription_plan_catalog() where billing_period = 'annual'),
                '322920/398520/506520', 'annual prices come from the catalog');
select tests.eq((select count(*) from public.subscription_plan_catalog() a join public.subscription_plan_catalog() m
                   on m.plan_code = a.plan_code and m.billing_period = 'monthly'
                  where a.billing_period = 'annual' and a.price_minor = round(m.price_minor * 12 * 0.90)), 3::bigint,
                'annual = monthly x 12 x 0.90 for every plan');
select tests.eq((select string_agg(max_family_members::text, '/' order by max_family_members) from public.subscription_plan_catalog() where billing_period = 'monthly'),
                '3/6/12', 'capacities 3 / 6 / 12');
select tests.eq((select bool_and(max_parent_seats = 2) from public.subscription_plan_catalog()), true, 'two parent seats on every plan');
select tests.expect_error($q$select * from public.subscription_plans$q$, 'permission denied');
reset role;
select tests.logout();
select tests.expect_error($q$insert into public.subscription_plans (code, billing_period, version, max_parent_seats, max_family_members, price_minor)
  values ('small_family', 'monthly', 2, 2, 3, 30000), ('small_family', 'annual', 2, 2, 3, 99999)$q$, 'annual price must equal');
select tests.expect_error($q$update public.subscription_plans set price_minor = 1 where code = 'small_family' and billing_period = 'monthly'$q$, 'immutable');

-- Account creation: two babies, one account, one subscription -----------------------------
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000001');
select (public.create_baby('Deniz', public.business_date_istanbul() - 100, 'anne')).id as deniz \gset
select (public.create_baby('Derya', public.business_date_istanbul() - 30, 'anne')).id as derya \gset
select public.family_account_id_for_baby(:'deniz') as acct \gset
select tests.eq(public.family_account_id_for_baby(:'derya'), :'acct'::uuid, 'second baby joins the same family account');
select tests.eq((public.family_account_overview(:'acct') ->> 'my_role'), 'parent', 'creator is a parent');
select tests.eq(jsonb_array_length(public.family_account_overview(:'acct') -> 'babies'), 2, 'account covers both babies');
select status as deniz_status_before, effective_close_date as deniz_close_before
  from public.baby_lifecycle_summary(:'deniz') \gset

-- Parent seats: second parent joins, a third is refused ------------------------------------
reset role;
select tests.logout();
insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'deniz', 'PARBABA222', 'baba', true, '{}', '97000000-0000-4000-8000-000000000001'),
  (:'deniz', 'PARBABA333', 'baba', true, '{}', '97000000-0000-4000-8000-000000000001'),
  (:'deniz', 'UYEBRRRR22', 'teyze', false, '{view_memories,view_album,comment}', '97000000-0000-4000-8000-000000000001'),
  (:'deniz', 'UYEKKKKK22', 'hala', false, '{view_memories,view_album,comment}', '97000000-0000-4000-8000-000000000001'),
  (:'deniz', 'UYEUUUUU22', 'dayi', false, '{view_memories,view_album,comment}', '97000000-0000-4000-8000-000000000001'),
  (:'deniz', 'UYEDDDDD22', 'amca', false, '{view_memories,view_album,comment}', '97000000-0000-4000-8000-000000000001'),
  (:'deniz', 'UYEBBBBB22', 'dede', false, '{view_memories,view_album,comment}', '97000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000002');
select public.accept_invitation('PARBABA222');
select tests.eq((public.family_account_overview(:'acct') ->> 'active_parents')::integer, 2, 'second parent takes the second seat');
select tests.eq((public.family_account_overview(:'acct') ->> 'my_role'), 'parent', 'both parents have the same role');
select tests.login('97000000-0000-4000-8000-000000000003');
select tests.expect_error($q$select public.accept_invitation('PARBABA333')$q$, 'parent_seats_full');

-- Checkout: parents only; clients never activate a plan themselves ---------------------------
select tests.login('97000000-0000-4000-8000-000000000002');
select intent_id as intent_small, provider_product_id as product_small
  from public.request_subscription_checkout(:'acct', 'small_family', 'monthly') \gset
select tests.eq(:'product_small'::text, 'mock.small_family.monthly', 'intent maps to the provider product');
select tests.expect_error(format('select * from public.request_subscription_checkout(%L, %L, %L)', :'acct', 'mega_family', 'monthly'), 'unknown plan');
select tests.expect_error($q$insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id)
  select a.id, p.id, 'small_family', 'monthly', 'active', 'mock', 'hack' from public.family_accounts a, public.subscription_plans p limit 1$q$, 'permission denied');
select tests.expect_error($q$select public.billing_apply_event('mock', 'x', 'y', '{}'::jsonb)$q$, 'permission denied');
select tests.expect_error($q$select * from public.billing_events$q$, 'permission denied');

-- Provider events: apply, replay, IDOR ------------------------------------------------------
reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('mock', 'evt-1', 'subscription.created', jsonb_build_object(
  'checkout_intent_id', :'intent_small', 'provider_subscription_id', 'sub-1',
  'provider_product_id', 'mock.small_family.monthly', 'status', 'active',
  'current_period_start', now(), 'current_period_end', now() + interval '1 month')), 'applied', 'verified event opens the subscription');
select tests.eq(public.billing_apply_event('mock', 'evt-1', 'subscription.created', '{}'::jsonb), 'duplicate', 'event replay is a no-op');
select tests.eq(public.billing_apply_event('mock', 'evt-1b', 'subscription.renewed', jsonb_build_object(
  'provider_subscription_id', 'sub-1', 'provider_product_id', 'mock.small_family.monthly', 'status', 'active')),
  'applied', 'a second event for the same subscription updates it');
select tests.eq((select count(*) from public.subscriptions where family_account_id = :'acct'), 1::bigint, 'replays never create a second subscription');
select tests.eq((select count(*) from public.billing_events where provider_event_id like 'evt-1%'), 2::bigint, 'events are stored once each');
select tests.expect_error($q$update public.billing_events set payload = '{}' where provider_event_id = 'evt-1'$q$, 'append-only');
select tests.expect_error($q$delete from public.billing_events where provider_event_id = 'evt-1'$q$, 'append-only');
select tests.eq(public.billing_apply_event('mock', 'evt-no-intent', 'subscription.created', jsonb_build_object(
  'provider_subscription_id', 'sub-orphan', 'provider_product_id', 'mock.small_family.monthly', 'status', 'active')),
  'rejected', 'a new subscription needs the parent''s checkout intent');
select tests.eq(public.billing_apply_event('mock', 'evt-used-intent', 'subscription.created', jsonb_build_object(
  'checkout_intent_id', :'intent_small', 'provider_subscription_id', 'sub-2',
  'provider_product_id', 'mock.small_family.monthly', 'status', 'active')),
  'rejected', 'a consumed intent cannot open a second subscription');
select tests.eq(public.billing_apply_event('mock', 'evt-bad-status', 'subscription.updated', jsonb_build_object(
  'provider_subscription_id', 'sub-1', 'provider_product_id', 'mock.small_family.monthly', 'status', 'paid_by_client')),
  'rejected', 'unknown provider status is rejected');

-- Another family's receipt cannot move or reuse this subscription.
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000021');
select (public.create_baby('Başka', public.business_date_istanbul() - 50, 'anne')).id as other_baby \gset
select public.family_account_id_for_baby(:'other_baby') as other_acct \gset
select intent_id as other_intent from public.request_subscription_checkout(:'other_acct', 'large_family', 'annual') \gset
select tests.expect_error(format('select * from public.request_subscription_checkout(%L, %L, %L)', :'acct', 'large_family', 'annual'), 'not authorized');
select tests.expect_error(format('select public.family_account_overview(%L)', :'acct'), 'not found');
select tests.expect_error(format('select public.family_account_id_for_baby(%L)', :'deniz'), 'not found');
reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('mock', 'evt-idor-1', 'subscription.updated', jsonb_build_object(
  'checkout_intent_id', :'other_intent', 'provider_subscription_id', 'sub-1',
  'provider_product_id', 'mock.large_family.annual', 'status', 'active')),
  'rejected', 'another family''s intent cannot touch this subscription');
select tests.eq(public.billing_apply_event('mock', 'evt-idor-2', 'subscription.updated', jsonb_build_object(
  'family_account_id', :'other_acct', 'provider_subscription_id', 'sub-1',
  'provider_product_id', 'mock.small_family.monthly', 'status', 'active')),
  'rejected', 'a receipt naming another family account is rejected');
select tests.eq((select family_account_id from public.subscriptions where provider_subscription_id = 'sub-1'), :'acct'::uuid, 'subscription stays with its family');
select tests.eq((select plan_code from public.subscriptions where provider_subscription_id = 'sub-1'), 'small_family', 'rejected events change nothing');

-- Capacity: Small = 3 Family Members, parents not counted ----------------------------------
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000011');
select public.accept_invitation('UYEBRRRR22');
select tests.expect_error(format('select * from public.request_subscription_checkout(%L, %L, %L)', :'acct', 'normal_family', 'monthly'), 'not authorized');
select tests.eq((public.family_account_overview(:'acct') ->> 'my_role'), 'family_member', 'family member sees the family plan');
select tests.login('97000000-0000-4000-8000-000000000012');
select public.accept_invitation('UYEKKKKK22');
select tests.login('97000000-0000-4000-8000-000000000013');
select public.accept_invitation('UYEUUUUU22');
select tests.eq((public.family_account_overview(:'acct') ->> 'active_family_members')::integer, 3, 'three Family Members on Small');
select tests.eq((public.family_account_overview(:'acct') ->> 'active_parents')::integer, 2, 'parents are counted separately');
select tests.login('97000000-0000-4000-8000-000000000014');
select tests.expect_error($q$select public.accept_invitation('UYEDDDDD22')$q$, 'family_capacity_full');
reset role;
select tests.logout();
select tests.eq((select status from public.family_invitations where code = 'UYEDDDDD22'), 'pending', 'refused activation keeps the invitation');
set role authenticated;

-- Adding an existing Family Member to the sibling uses no extra seat.
select tests.login('97000000-0000-4000-8000-000000000001');
select public.add_member_from_sibling(:'derya', '97000000-0000-4000-8000-000000000011', 'teyze');
select tests.eq((public.family_account_overview(:'acct') ->> 'active_family_members')::integer, 3, 'sibling membership is the same seat');

-- Upgrade opens capacity ----------------------------------------------------------------------
reset role;
select tests.logout();
select tests.eq(public.billing_apply_event('mock', 'evt-up', 'subscription.updated', jsonb_build_object(
  'provider_subscription_id', 'sub-1', 'provider_product_id', 'mock.normal_family.monthly', 'status', 'active')),
  'applied', 'upgrade to Normal applied');
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000014');
select public.accept_invitation('UYEDDDDD22');
select tests.eq((public.family_account_overview(:'acct') ->> 'active_family_members')::integer, 4, 'upgrade makes the 4th member possible');

-- Downgrade below the member count: nobody is removed, new activations wait -------------------
reset role;
select tests.logout();
select permissions as perms_before from public.family_members
 where baby_id = :'deniz' and user_id = '97000000-0000-4000-8000-000000000014' \gset
select tests.eq(public.billing_apply_event('mock', 'evt-down', 'subscription.updated', jsonb_build_object(
  'provider_subscription_id', 'sub-1', 'provider_product_id', 'mock.small_family.monthly', 'status', 'active')),
  'applied', 'downgrade to Small applied');
select tests.eq((select over_capacity from public.subscriptions where provider_subscription_id = 'sub-1'), true, 'downgrade flags over capacity');
select tests.eq((select count(*) from public.family_account_members where family_account_id = :'acct' and role = 'family_member' and status = 'active'),
                4::bigint, 'downgrade removes nobody');
select tests.eq((select permissions::text from public.family_members
                  where baby_id = :'deniz' and user_id = '97000000-0000-4000-8000-000000000014'), :'perms_before', 'downgrade keeps permissions');
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000015');
select tests.expect_error($q$select public.accept_invitation('UYEBBBBB22')$q$, 'family_capacity_full');
select tests.login('97000000-0000-4000-8000-000000000001');
delete from public.family_members where baby_id = :'deniz' and user_id = '97000000-0000-4000-8000-000000000014';
reset role;
select tests.logout();
select tests.eq((select status from public.family_account_members
                  where family_account_id = :'acct' and user_id = '97000000-0000-4000-8000-000000000014'), 'removed', 'leaving the last baby leaves the account');
select tests.eq((select over_capacity from public.subscriptions where provider_subscription_id = 'sub-1'), false, 'capacity flag clears when the count fits');

-- Subscription never changes the lifecycle -----------------------------------------------------
select tests.eq(public.billing_apply_event('mock', 'evt-cancel', 'subscription.canceled', jsonb_build_object(
  'provider_subscription_id', 'sub-1', 'provider_product_id', 'mock.small_family.monthly', 'status', 'canceled')),
  'applied', 'cancellation applied');
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000001');
select tests.eq((select status from public.baby_lifecycle_summary(:'deniz')), :'deniz_status_before', 'subscription changes keep the lifecycle status');
select tests.eq((select effective_close_date from public.baby_lifecycle_summary(:'deniz')), :'deniz_close_before'::date, 'subscription changes keep the close date');
select tests.eq((public.family_account_overview(:'acct') ->> 'subscription_live')::boolean, false, 'canceled subscription is not live');

-- Enforcement flag: without a live subscription, activation needs one -------------------------
reset role;
select tests.logout();
begin;
update public.platform_flags set enabled = true where key = 'subscription_enforcement';
set local role authenticated;
select tests.login('97000000-0000-4000-8000-000000000015');
select tests.expect_error($q$select public.accept_invitation('UYEBBBBB22')$q$, 'subscription_required');
rollback;
set role authenticated;
select tests.login('97000000-0000-4000-8000-000000000015');
select public.accept_invitation('UYEBBBBB22');
select tests.eq((select count(*) from public.family_members where user_id = '97000000-0000-4000-8000-000000000015'), 1::bigint,
                'without enforcement and without a live plan, legacy invitations keep working');

-- Legacy mapping: exact matches only ------------------------------------------------------------
reset role;
select tests.logout();
insert into auth.users (id, email) values
  ('98000000-0000-4000-8000-000000000001', 'eski-anne@example.com'),
  ('98000000-0000-4000-8000-000000000002', 'eski-baba@example.com'),
  ('98000000-0000-4000-8000-000000000003', 'tek-anne@example.com'),
  ('98000000-0000-4000-8000-000000000004', 'karisik@example.com'),
  ('98000000-0000-4000-8000-000000000005', 'karisik-es@example.com'),
  ('98000000-0000-4000-8000-000000000006', 'eski-teyze@example.com');
insert into public.babies (id, first_name, birth_date, created_by) values
  ('99000000-0000-4000-8000-000000000001', 'Eski1', current_date - 50, '98000000-0000-4000-8000-000000000001'),
  ('99000000-0000-4000-8000-000000000002', 'Eski2', current_date - 40, '98000000-0000-4000-8000-000000000001'),
  ('99000000-0000-4000-8000-000000000003', 'Tek', current_date - 40, '98000000-0000-4000-8000-000000000003'),
  ('99000000-0000-4000-8000-000000000004', 'Karışık1', current_date - 40, '98000000-0000-4000-8000-000000000004'),
  ('99000000-0000-4000-8000-000000000005', 'Karışık2', current_date - 40, '98000000-0000-4000-8000-000000000004'),
  ('99000000-0000-4000-8000-000000000006', 'Sahipsiz', current_date - 40, '98000000-0000-4000-8000-000000000006');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('99000000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', 'anne', true, '{}'),
  ('99000000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000002', 'baba', true, '{}'),
  ('99000000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000006', 'teyze', false, '{view_memories}'),
  ('99000000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000001', 'anne', true, '{}'),
  ('99000000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000002', 'baba', true, '{}'),
  ('99000000-0000-4000-8000-000000000003', '98000000-0000-4000-8000-000000000003', 'anne', true, '{}'),
  ('99000000-0000-4000-8000-000000000004', '98000000-0000-4000-8000-000000000004', 'anne', true, '{}'),
  ('99000000-0000-4000-8000-000000000005', '98000000-0000-4000-8000-000000000004', 'anne', true, '{}'),
  ('99000000-0000-4000-8000-000000000005', '98000000-0000-4000-8000-000000000005', 'baba', true, '{}'),
  ('99000000-0000-4000-8000-000000000006', '98000000-0000-4000-8000-000000000006', 'teyze', true, '{}');
select public.backfill_family_accounts();
select tests.eq((select count(distinct family_account_id) from public.family_account_babies
                  where baby_id in ('99000000-0000-4000-8000-000000000001', '99000000-0000-4000-8000-000000000002')), 1::bigint,
                'identical parent sets share one account');
select tests.eq((select count(*) from public.family_account_members m
                   join public.family_account_babies fab on fab.family_account_id = m.family_account_id
                  where fab.baby_id = '99000000-0000-4000-8000-000000000001' and m.role = 'parent'), 2::bigint, 'both legacy parents mapped');
select tests.eq((select m.role from public.family_account_members m
                   join public.family_account_babies fab on fab.family_account_id = m.family_account_id
                  where fab.baby_id = '99000000-0000-4000-8000-000000000001' and m.user_id = '98000000-0000-4000-8000-000000000006'),
                'family_member', 'legacy relatives become Family Members');
select tests.eq((select count(*) from public.family_account_babies where baby_id = '99000000-0000-4000-8000-000000000003'), 1::bigint, 'single-parent household mapped');
select tests.eq((select reason from public.family_account_migration_report where baby_id = '99000000-0000-4000-8000-000000000004' and resolved_at is null),
                'ambiguous_parent_sets', 'a parent in two different sets is not merged');
select tests.eq((select reason from public.family_account_migration_report where baby_id = '99000000-0000-4000-8000-000000000005' and resolved_at is null),
                'ambiguous_parent_sets', 'both sides of the ambiguity are reported');
select tests.eq((select count(*) from public.family_account_babies where baby_id in ('99000000-0000-4000-8000-000000000004', '99000000-0000-4000-8000-000000000005')),
                0::bigint, 'ambiguous households stay unmapped');
select tests.eq((select reason from public.family_account_migration_report where baby_id = '99000000-0000-4000-8000-000000000006' and resolved_at is null),
                'no_parent', 'baby without anne/baba admin is reported');
select public.backfill_family_accounts();
select tests.eq((select count(*) from public.family_account_babies where baby_id = '99000000-0000-4000-8000-000000000001'), 1::bigint, 'backfill is idempotent');
select tests.eq((select count(*) from public.family_account_migration_report where baby_id = '99000000-0000-4000-8000-000000000004'), 1::bigint,
                'report rows are not duplicated');
select tests.eq((select count(*) from public.family_members where baby_id::text like '99000000%'), 10::bigint, 'legacy mapping deletes no membership');
select public.resolve_family_account_mapping('99000000-0000-4000-8000-000000000004',
  (select family_account_id from public.family_account_babies where baby_id = '99000000-0000-4000-8000-000000000003'));
select tests.eq((select resolved_at is not null from public.family_account_migration_report where baby_id = '99000000-0000-4000-8000-000000000004'),
                true, 'manual resolution closes the report');
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$select public.backfill_family_accounts()$q$, 'permission denied');
select tests.expect_error($q$select * from public.family_account_migration_report$q$, 'permission denied');

reset role;
select tests.logout();
