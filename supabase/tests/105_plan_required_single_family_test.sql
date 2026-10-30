-- Mandatory plan for new families + one-family-per-person (joins only).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();

insert into auth.users (id, email, raw_user_meta_data) values
  ('a5000000-0000-4000-8000-000000000001', 'plan-new-parent@example.com', '{"display_name":"New Parent"}'),
  ('a5000000-0000-4000-8000-000000000002', 'plan-old-parent@example.com', '{"display_name":"Old Parent"}'),
  ('a5000000-0000-4000-8000-000000000003', 'plan-paid-parent@example.com', '{"display_name":"Paid Parent"}'),
  ('a5000000-0000-4000-8000-000000000004', 'plan-aunt@example.com', '{"display_name":"Aunt"}');

insert into public.family_accounts (id, display_name, created_by, plan_exempt) values
  ('a5100000-0000-4000-8000-000000000001', 'New Family', 'a5000000-0000-4000-8000-000000000001', false),
  ('a5100000-0000-4000-8000-000000000002', 'Old Family', 'a5000000-0000-4000-8000-000000000002', true),
  ('a5100000-0000-4000-8000-000000000003', 'Paid Family', 'a5000000-0000-4000-8000-000000000003', false);
insert into public.family_account_members
  (family_account_id, user_id, role, relationship_label, status, activated_at) values
  ('a5100000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000001', 'parent', 'anne', 'active', now()),
  ('a5100000-0000-4000-8000-000000000002', 'a5000000-0000-4000-8000-000000000002', 'parent', 'anne', 'active', now()),
  ('a5100000-0000-4000-8000-000000000003', 'a5000000-0000-4000-8000-000000000003', 'parent', 'anne', 'active', now());

insert into public.babies (id, first_name, birth_date, created_by) values
  ('a5200000-0000-4000-8000-000000000001', 'New Baby', public.business_date_istanbul() - 30, 'a5000000-0000-4000-8000-000000000001'),
  ('a5200000-0000-4000-8000-000000000002', 'Old Baby', public.business_date_istanbul() - 30, 'a5000000-0000-4000-8000-000000000002'),
  ('a5200000-0000-4000-8000-000000000003', 'Paid Baby', public.business_date_istanbul() - 30, 'a5000000-0000-4000-8000-000000000003');
insert into public.family_account_babies (baby_id, family_account_id) values
  ('a5200000-0000-4000-8000-000000000001', 'a5100000-0000-4000-8000-000000000001'),
  ('a5200000-0000-4000-8000-000000000002', 'a5100000-0000-4000-8000-000000000002'),
  ('a5200000-0000-4000-8000-000000000003', 'a5100000-0000-4000-8000-000000000003');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('a5200000-0000-4000-8000-000000000001', 'a5000000-0000-4000-8000-000000000001', 'anne', true, array(select key from public.permissions)),
  ('a5200000-0000-4000-8000-000000000002', 'a5000000-0000-4000-8000-000000000002', 'anne', true, array(select key from public.permissions)),
  ('a5200000-0000-4000-8000-000000000003', 'a5000000-0000-4000-8000-000000000003', 'anne', true, array(select key from public.permissions));

insert into public.subscriptions
  (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id, current_period_end)
select f.id, p.id, p.code, 'monthly', 'active', 'test', 'plan-gate-' || f.n, now() + interval '20 days'
  from (values ('a5100000-0000-4000-8000-000000000003'::uuid, 'paid-1'),
               ('a5100000-0000-4000-8000-000000000002'::uuid, 'old-1')) f(id, n),
       (select id, code from public.subscription_plans order by code limit 1) p;

update public.platform_flags set enabled = true where key = 'subscription_enforcement';

set role authenticated;

-- Plan gate ---------------------------------------------------------------------------------------
select tests.login('a5000000-0000-4000-8000-000000000001');
select tests.eq((select plan_required from public.baby_access_state('a5200000-0000-4000-8000-000000000001')), true,
                'new family without any subscription must pick a plan');
select tests.login('a5000000-0000-4000-8000-000000000002');
select tests.eq((select plan_required from public.baby_access_state('a5200000-0000-4000-8000-000000000002')), false,
                'family that existed before the rule is exempt');
select tests.login('a5000000-0000-4000-8000-000000000003');
select tests.eq((select plan_required from public.baby_access_state('a5200000-0000-4000-8000-000000000003')), false,
                'new family with a subscription is not gated');

-- One family per person: joining ------------------------------------------------------------------
reset role;
select tests.login('a5000000-0000-4000-8000-000000000004');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
values ('a5200000-0000-4000-8000-000000000002', 'a5000000-0000-4000-8000-000000000004', 'teyze', false, '{view_memories}');
select tests.expect_error(
  $q$insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
     values ('a5200000-0000-4000-8000-000000000003', 'a5000000-0000-4000-8000-000000000004', 'teyze', false, '{view_memories}')$q$,
  'already_in_another_family');
select tests.eq((select count(*) from public.family_members where user_id = 'a5000000-0000-4000-8000-000000000004'), 1::bigint,
                'a second family join leaves membership unchanged');

-- Founding a family is never refused.
insert into public.babies (id, first_name, birth_date, created_by)
values ('a5200000-0000-4000-8000-000000000005', 'Aunt Baby', public.business_date_istanbul() - 10, 'a5000000-0000-4000-8000-000000000004');
insert into public.family_accounts (id, display_name, created_by)
values ('a5100000-0000-4000-8000-000000000004', 'Aunt Family', 'a5000000-0000-4000-8000-000000000004');
insert into public.family_account_babies (baby_id, family_account_id)
values ('a5200000-0000-4000-8000-000000000005', 'a5100000-0000-4000-8000-000000000004');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
values ('a5200000-0000-4000-8000-000000000005', 'a5000000-0000-4000-8000-000000000004', 'anne', true, array(select key from public.permissions));
select tests.eq((select count(*) from public.family_members where user_id = 'a5000000-0000-4000-8000-000000000004'), 2::bigint,
                'founding an own family is allowed even when already a member elsewhere');
