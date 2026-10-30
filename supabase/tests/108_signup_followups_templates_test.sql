-- Yeni Kayıtlar (derived pending list, manual "sent" marks) and editable templates.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();

-- Fixtures (prefix d3) ------------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('d3000000-0000-4000-8000-000000000002', 'su-admin@example.com', '{"display_name":"Yonetici"}'),
  ('d3000000-0000-4000-8000-000000000003', 'su-normal@example.com', '{"display_name":"Normal"}'),
  ('d3000000-0000-4000-8000-000000000004', 'su-yeni1@example.com', '{"display_name":"Yeni Bir"}'),
  ('d3000000-0000-4000-8000-000000000005', 'su-yeni2@example.com', '{"display_name":"Yeni Iki"}');
-- Created before the queue existed: must never show up as "new".
insert into auth.users (id, email, raw_user_meta_data, created_at) values
  ('d3000000-0000-4000-8000-000000000006', 'su-eski@example.com', '{"display_name":"Eski Uye"}',
   (select value - interval '10 days' from public.user_event_meta where key = 'signup_queue_started'));
insert into public.platform_user_roles (user_id, role, granted_by)
values ('d3000000-0000-4000-8000-000000000002', 'super_admin', tests.id('anne'))
on conflict do nothing;

-- 1. Admin only -------------------------------------------------------------------------------------
set role authenticated;
select tests.login('d3000000-0000-4000-8000-000000000003');
select tests.expect_error($q$select * from public.admin_new_signups()$q$, 'not authorized');
select tests.expect_error($q$select public.admin_pending_signup_count()$q$, 'not authorized');
select tests.expect_error($q$select public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000004', 'welcome')$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_email_templates()$q$, 'not authorized');
select tests.expect_error($q$select public.admin_save_email_template('welcome', 'a', 'b')$q$, 'not authorized');
select tests.expect_error($q$select * from public.email_followups$q$, 'permission denied');
select tests.expect_error($q$select * from public.email_templates$q$, 'permission denied');

-- 2. The pending list is derived, with a safe start ---------------------------------------------------------
select tests.login('d3000000-0000-4000-8000-000000000002');
select tests.expect_error($q$select * from public.admin_new_signups('bogus')$q$, 'invalid status');
select tests.eq((select count(*) from public.admin_new_signups('pending', 100, 0)
                  where user_id in ('d3000000-0000-4000-8000-000000000004', 'd3000000-0000-4000-8000-000000000005')),
                2::bigint, 'new sign-ups wait automatically');
select tests.eq((select count(*) from public.admin_new_signups('all', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000006'),
                0::bigint, 'users from before the queue are never listed as new');
select tests.eq((select count(*) from public.admin_new_signups('all', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000002'),
                0::bigint, 'platform admins are not listed');
select tests.eq((select public.admin_pending_signup_count() >= 3), true, 'the menu counter counts pending sign-ups');
select tests.eq((select email_verified_at is null from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000004'), true, 'verification status is shown');
select tests.eq((select trial_status from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000004'), 'none', 'trial status is shown');

-- 3. Manual marks: idempotent, nobody is deleted ------------------------------------------------------------
select tests.expect_error($q$select public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000004', 'bogus')$q$, 'invalid template');
select tests.expect_error($q$select public.admin_mark_email_sent('d3000000-0000-4000-8000-0000000000ee', 'welcome')$q$, 'user not found');
select tests.eq(public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000004', 'welcome'), 'marked', 'first mark');
select tests.eq(public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000004', 'welcome'), 'already_marked', 'second mark is a no-op');
select tests.eq((select count(*) from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000004'), 0::bigint, 'a marked user leaves the pending list');
select tests.eq((select count(*) from public.admin_new_signups('sent', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000004' and welcome_marked_at is not null), 1::bigint,
                'the sent list keeps the history');
select tests.eq((select welcome_marked_by_name from public.admin_new_signups('sent', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000004'), 'Yonetici', 'who marked it is kept');
select tests.eq((select count(*) from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000005'), 1::bigint, 'the other user is still pending');
reset role;
select tests.eq((select count(*) from auth.users where id in ('d3000000-0000-4000-8000-000000000004', 'd3000000-0000-4000-8000-000000000005')),
                2::bigint, 'no user is ever deleted by this module');

-- 4. Trial e-mail marks belong to a real trial of that user ----------------------------------------------------
set role authenticated;
select tests.login('d3000000-0000-4000-8000-000000000002');
select trial_id as su_trial from public.admin_grant_trial('d3000000-0000-4000-8000-000000000005', 'yeni uye denemesi') \gset
select tests.eq((select trial_status from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000005'), 'live', 'a live trial is shown in the list');
select tests.expect_error($q$select public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000005', 'trial_activated')$q$, 'trial does not belong');
select tests.expect_error(format('select public.admin_mark_email_sent(%L, %L, %L)', 'd3000000-0000-4000-8000-000000000004', 'trial_activated', :'su_trial'), 'trial does not belong');
select tests.eq(public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000005', 'trial_activated', :'su_trial'::uuid), 'marked', 'trial mail marked');
select tests.eq(public.admin_mark_email_sent('d3000000-0000-4000-8000-000000000005', 'trial_activated', :'su_trial'::uuid), 'already_marked', 'trial mark is idempotent');
select tests.eq((select trial_email_marked_at is not null from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000005'), true, 'the trial mail mark is shown');
select tests.eq((select count(*) from public.admin_new_signups('pending', 100, 0)
                  where user_id = 'd3000000-0000-4000-8000-000000000005'), 1::bigint,
                'a trial mail does not remove the user from the welcome queue');

-- 5. Editable, versioned templates ---------------------------------------------------------------------------------
select tests.eq((select count(*) from public.admin_email_templates()), 2::bigint, 'two template slots exist');
select tests.eq((select version from public.admin_email_templates() where kind = 'welcome'), 0, 'drafts start empty');
select tests.expect_error($q$select public.admin_save_email_template('bogus', 'a', 'b')$q$, 'invalid template');
select tests.expect_error($q$select public.admin_save_email_template('welcome', 'Merhaba {{ad}}', 'Kod: {{kart_no}}')$q$, 'unknown placeholder');
select tests.expect_error(format('select public.admin_save_email_template(%L, %L, %L)', 'welcome', repeat('x', 201), 'b'), 'too long');
select tests.expect_error(format('select public.admin_save_email_template(%L, %L, %L)', 'welcome', 'a', repeat('x', 10001)), 'too long');
select tests.eq(public.admin_save_email_template('welcome', 'Hoş geldin {{ad}}', E'Merhaba {{ ad }},\n\nDeneme bitişi: {{deneme_bitis}}'), 1, 'first save is version 1');
select tests.eq(public.admin_save_email_template('welcome', 'Hoş geldin {{ad}}', 'Güncel metin'), 2, 'every save is a new version');
select tests.eq((select body from public.admin_email_templates() where kind = 'welcome'), 'Güncel metin', 'the latest text is returned');
select tests.eq((select updated_by_name from public.admin_email_templates() where kind = 'welcome'), 'Yonetici', 'who saved it is returned');
select tests.eq((select version from public.admin_email_templates() where kind = 'trial_activated'), 0, 'the other template is untouched');
reset role;
select tests.eq((select count(*) from public.email_template_versions where kind = 'welcome'), 2::bigint, 'both versions are kept');
select tests.expect_error($q$update public.email_template_versions set body = 'x' where kind = 'welcome'$q$, 'append-only');
select tests.expect_error($q$delete from public.email_template_versions where kind = 'welcome'$q$, 'append-only');

-- 6. Deleting a user removes their marks, nothing else -------------------------------------------------------------------
delete from auth.users where id in ('d3000000-0000-4000-8000-000000000004', 'd3000000-0000-4000-8000-000000000005');
select tests.eq((select count(*) from public.email_followups where user_id::text like 'd3000000-%'), 0::bigint,
                'account deletion removes the marks');
delete from public.platform_user_roles where user_id = 'd3000000-0000-4000-8000-000000000002' and role = 'super_admin';
