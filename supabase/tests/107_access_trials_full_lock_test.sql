-- Manual 72 h trial + full lock without an entitlement.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();
select enabled as enforcement_before from public.platform_flags where key = 'subscription_enforcement' \gset

-- Fixtures (prefix d2) -------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('d2000000-0000-4000-8000-000000000001', 'tr-parent@example.com', '{"display_name":"Deneme Ebeveyn"}'),
  ('d2000000-0000-4000-8000-000000000002', 'tr-admin@example.com', '{"display_name":"Yonetici"}'),
  ('d2000000-0000-4000-8000-000000000003', 'tr-uye1@example.com', '{"display_name":"Uye Bir"}'),
  ('d2000000-0000-4000-8000-000000000004', 'tr-uye2@example.com', '{"display_name":"Uye Iki"}'),
  ('d2000000-0000-4000-8000-000000000005', 'tr-uye3@example.com', '{"display_name":"Uye Uc"}'),
  ('d2000000-0000-4000-8000-000000000006', 'tr-uye4@example.com', '{"display_name":"Uye Dort"}'),
  ('d2000000-0000-4000-8000-000000000007', 'tr-paid@example.com', '{"display_name":"Odeyen"}'),
  ('d2000000-0000-4000-8000-000000000008', 'tr-normal@example.com', '{"display_name":"Normal"}'),
  ('d2000000-0000-4000-8000-000000000009', 'tr-yeni@example.com', '{"display_name":"Yeni Kullanici"}');
insert into public.platform_user_roles (user_id, role, granted_by)
values ('d2000000-0000-4000-8000-000000000002', 'super_admin', tests.id('anne'));

insert into public.family_accounts (id, display_name, created_by, plan_exempt) values
  ('d2100000-0000-4000-8000-000000000001', 'Deneme Ailesi', 'd2000000-0000-4000-8000-000000000001', false),
  ('d2100000-0000-4000-8000-000000000007', 'Odeyen Aile', 'd2000000-0000-4000-8000-000000000007', false);
insert into public.family_account_members (family_account_id, user_id, role, relationship_label, status, activated_at) values
  ('d2100000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'parent', 'anne', 'active', now()),
  ('d2100000-0000-4000-8000-000000000007', 'd2000000-0000-4000-8000-000000000007', 'parent', 'anne', 'active', now());
insert into public.babies (id, first_name, birth_date, created_by) values
  ('d2200000-0000-4000-8000-000000000001', 'Deneme Bebek', public.business_date_istanbul() - 30, 'd2000000-0000-4000-8000-000000000001'),
  ('d2200000-0000-4000-8000-000000000007', 'Odeyen Bebek', public.business_date_istanbul() - 30, 'd2000000-0000-4000-8000-000000000007');
insert into public.family_account_babies (baby_id, family_account_id) values
  ('d2200000-0000-4000-8000-000000000001', 'd2100000-0000-4000-8000-000000000001'),
  ('d2200000-0000-4000-8000-000000000007', 'd2100000-0000-4000-8000-000000000007');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('d2200000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000001', 'anne', true, array(select key from public.permissions)),
  ('d2200000-0000-4000-8000-000000000007', 'd2000000-0000-4000-8000-000000000007', 'anne', true, array(select key from public.permissions));
insert into public.memories (baby_id, title, memory_date, author_id)
values ('d2200000-0000-4000-8000-000000000001', 'Mevcut ani', current_date, 'd2000000-0000-4000-8000-000000000001');
insert into public.subscriptions
  (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id, current_period_end)
select 'd2100000-0000-4000-8000-000000000007', p.id, p.code, 'monthly', 'active', 'test', 'trial-test-paid', now() + interval '20 days'
  from (select id, code from public.subscription_plans order by code limit 1) p;

update public.platform_flags set enabled = true where key = 'subscription_enforcement';

-- 1. No entitlement, no trial: full lock ----------------------------------------------------------------
set role authenticated;
select tests.login('d2000000-0000-4000-8000-000000000001');
select tests.eq((select allowed from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), false, 'locked: not allowed');
select tests.eq((select plan_required from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), true, 'locked: plan required');
select tests.eq((select reason from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), 'no_subscription', 'locked: reason');
select tests.eq(tests.count($q$select 1 from memories where baby_id = 'd2200000-0000-4000-8000-000000000001'$q$), 0::bigint,
                'locked: existing memories are not readable');
select tests.expect_error($q$insert into memories (baby_id, title, memory_date) values ('d2200000-0000-4000-8000-000000000001', 'x', current_date)$q$);
select tests.expect_error($q$insert into family_invitations (baby_id, relation) values ('d2200000-0000-4000-8000-000000000001', 'hala')$q$,
                          'row-level security');
select tests.expect_error($q$select public.create_time_capsule('d2200000-0000-4000-8000-000000000001', 'k', 'm', current_date + 30)$q$);
update public.babies set first_name = 'Degisti' where id = 'd2200000-0000-4000-8000-000000000001';
select tests.eq((select first_name from public.babies where id = 'd2200000-0000-4000-8000-000000000001'), 'Deneme Bebek',
                'locked: baby cannot be edited');
select tests.eq(public.can_read_baby_object('d2200000-0000-4000-8000-000000000001/profile/a.jpg'), true,
                'locked: the baby picture stays readable for the plan page');
select tests.expect_error($q$select * from public.create_baby('Ikinci', current_date - 5, 'anne')$q$, 'subscription_required');

-- The first baby of a brand-new user is always allowed.
select tests.login('d2000000-0000-4000-8000-000000000009');
select tests.eq((select first_name from public.create_baby('Ilk Bebek', current_date - 5, 'anne')), 'Ilk Bebek',
                'the first baby of a new family is allowed without a plan');

-- 2. Only a Super Admin grants a trial ----------------------------------------------------------------------
select tests.login('d2000000-0000-4000-8000-000000000008');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'kendime')$q$, 'not authorized');
select tests.login('d2000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'kendime')$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_revoke_trial('d2000000-0000-4000-8000-000000000001', 'kendime')$q$, 'not authorized');
select tests.expect_error($q$select count(*) from public.access_trials$q$, 'permission denied');

select tests.login('d2000000-0000-4000-8000-000000000002');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'x')$q$, 'reason must be');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-0000000000ee', 'gerekce var')$q$, 'user not found');
select tests.eq((select ends_at - starts_at from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'ilk uyelik denemesi')),
                interval '72 hours', 'the trial lasts exactly 72 hours, set by the server');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'ikinci deneme')$q$, 'trial_already_active');
select tests.expect_error($q$select * from public.admin_grant_trial(tests.id('anne'), 'test erisimi olan')$q$, 'test_access_included');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-000000000007', 'abonelik var')$q$, 'subscription_active');

-- 3. During the trial everything is open, family invitations up to the smallest plan -------------------
select tests.login('d2000000-0000-4000-8000-000000000001');
select tests.eq((select allowed from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), true, 'trial: allowed');
select tests.eq((select reason from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), 'trial', 'trial: reason');
select tests.eq((select plan_required from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), false, 'trial: no plan screen');
select tests.eq((select trial_ends_at is not null from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), true, 'trial end is reported');
select tests.eq(tests.count($q$select 1 from memories where baby_id = 'd2200000-0000-4000-8000-000000000001'$q$), 1::bigint, 'trial: memories readable');
insert into memories (baby_id, title, memory_date) values ('d2200000-0000-4000-8000-000000000001', 'Deneme ani', current_date);
select tests.eq(tests.count($q$select 1 from memories where baby_id = 'd2200000-0000-4000-8000-000000000001'$q$), 2::bigint, 'trial: memories can be written');
update public.babies set first_name = 'Duzenlendi' where id = 'd2200000-0000-4000-8000-000000000001';
select tests.eq((select first_name from public.babies where id = 'd2200000-0000-4000-8000-000000000001'), 'Duzenlendi', 'trial: baby can be edited');
select tests.eq((select count(*) from public.create_baby('Kardes', current_date - 3, 'anne')), 1::bigint, 'trial: another baby can be added');
select tests.eq((select count(*) from public.request_subscription_checkout('d2100000-0000-4000-8000-000000000001', 'small_family', 'monthly', 'app_store')),
                1::bigint, 'trial: a real plan can still be bought');

reset role;
select tests.logout();
select tests.eq(public.trial_family_member_capacity(), 3, 'trial capacity = smallest current plan');
select tests.eq((select count(*) from public.subscriptions where family_account_id = 'd2100000-0000-4000-8000-000000000001'), 0::bigint,
                'a trial is never stored as a subscription');
insert into public.family_invitations (baby_id, code, relation, created_by) values
  ('d2200000-0000-4000-8000-000000000001', 'TRKLDAV222', 'teyze', 'd2000000-0000-4000-8000-000000000001'),
  ('d2200000-0000-4000-8000-000000000001', 'TRKLDAV223', 'hala', 'd2000000-0000-4000-8000-000000000001'),
  ('d2200000-0000-4000-8000-000000000001', 'TRKLDAV224', 'amca', 'd2000000-0000-4000-8000-000000000001'),
  ('d2200000-0000-4000-8000-000000000001', 'TRKLDAV225', 'dayi', 'd2000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('d2000000-0000-4000-8000-000000000003');
select tests.eq((select public.accept_invitation('TRKLDAV222')), 'd2200000-0000-4000-8000-000000000001'::uuid, 'trial: member 1 joins');
select tests.login('d2000000-0000-4000-8000-000000000004');
select public.accept_invitation('TRKLDAV223');
select tests.login('d2000000-0000-4000-8000-000000000005');
select public.accept_invitation('TRKLDAV224');
select tests.login('d2000000-0000-4000-8000-000000000006');
select tests.expect_error($q$select public.accept_invitation('TRKLDAV225')$q$, 'family_capacity_full');

-- 4. Expiry: locked again, nothing deleted ---------------------------------------------------------------------
reset role;
select tests.logout();
alter table public.access_trials disable trigger access_trials_guard;
update public.access_trials set starts_at = now() - interval '73 hours', ends_at = now() - interval '1 hour'
 where user_id = 'd2000000-0000-4000-8000-000000000001';
alter table public.access_trials enable trigger access_trials_guard;
set role authenticated;
select tests.login('d2000000-0000-4000-8000-000000000001');
select tests.eq((select allowed from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), false, 'expired trial: locked');
select tests.eq((select plan_required from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), true, 'expired trial: plan screen');
select tests.eq(tests.count($q$select 1 from memories where baby_id = 'd2200000-0000-4000-8000-000000000001'$q$), 0::bigint, 'expired trial: not readable');
select tests.expect_error($q$insert into family_invitations (baby_id, relation) values ('d2200000-0000-4000-8000-000000000001', 'hala')$q$,
                          'row-level security');
select tests.login('d2000000-0000-4000-8000-000000000003');
select tests.eq(tests.count($q$select 1 from memories where baby_id = 'd2200000-0000-4000-8000-000000000001'$q$), 0::bigint,
                'expired trial: family members are locked as well');
reset role;
select tests.eq((select count(*) from public.memories where baby_id = 'd2200000-0000-4000-8000-000000000001'), 2::bigint,
                'expired trial: no memory was deleted');
select tests.eq((select count(*) from public.family_members where baby_id = 'd2200000-0000-4000-8000-000000000001'), 4::bigint,
                'expired trial: family and members are kept');

-- 5. Repeat trials need the explicit flag; revoke is audited -------------------------------------------------------
set role authenticated;
select tests.login('d2000000-0000-4000-8000-000000000002');
select tests.expect_error($q$select * from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'tekrar')$q$, 'trial_already_used');
select tests.eq((select count(*) from public.admin_grant_trial('d2000000-0000-4000-8000-000000000001', 'bilincli yenileme', true)),
                1::bigint, 'an explicit repeat trial is possible');
select tests.eq((select repeat_grant from public.admin_user_trials('d2000000-0000-4000-8000-000000000001') where status = 'live'),
                true, 'the repeat is marked');
select tests.eq((select count(*) from public.admin_user_trials('d2000000-0000-4000-8000-000000000001')), 2::bigint, 'history lists both trials');
select tests.eq(public.admin_revoke_trial('d2000000-0000-4000-8000-000000000001', 'erken bitirildi'), 'revoked', 'revoke');
select tests.eq(public.admin_revoke_trial('d2000000-0000-4000-8000-000000000001', 'tekrar'), 'unchanged', 'revoke twice is a no-op');
select tests.login('d2000000-0000-4000-8000-000000000001');
select tests.eq((select allowed from public.baby_access_state('d2200000-0000-4000-8000-000000000001')), false, 'revoked trial: locked');
reset role;
select tests.eq((select count(*) from public.trial_events where user_id = 'd2000000-0000-4000-8000-000000000001' and action = 'granted'),
                2::bigint, 'both grants are audited');
select tests.eq((select count(*) from public.trial_events where user_id = 'd2000000-0000-4000-8000-000000000001' and action = 'revoked'),
                1::bigint, 'the revoke is audited');
select tests.expect_error($q$update public.trial_events set reason = 'degistir' where action = 'granted'$q$, 'append-only');
select tests.expect_error($q$update public.access_trials set grant_reason = 'degistir' where user_id = 'd2000000-0000-4000-8000-000000000001'$q$,
                          'only be revoked');

-- 6. A paying family is untouched; an ended subscription is fully locked --------------------------------------------
set role authenticated;
select tests.login('d2000000-0000-4000-8000-000000000007');
select tests.eq((select allowed from public.baby_access_state('d2200000-0000-4000-8000-000000000007')), true, 'paying family is open');
reset role;
update public.subscriptions set status = 'expired' where provider_subscription_id = 'trial-test-paid';
set role authenticated;
select tests.login('d2000000-0000-4000-8000-000000000007');
select tests.eq((select reason from public.baby_access_state('d2200000-0000-4000-8000-000000000007')), 'subscription_ended', 'ended: reason');
select tests.eq((select plan_required from public.baby_access_state('d2200000-0000-4000-8000-000000000007')), true, 'ended: full lock goes to the plan screen');

-- Cleanup ------------------------------------------------------------------------------------------------------------
reset role;
select tests.logout();
update public.platform_flags set enabled = :'enforcement_before' where key = 'subscription_enforcement';
delete from public.platform_user_roles where user_id = 'd2000000-0000-4000-8000-000000000002' and role = 'super_admin';
