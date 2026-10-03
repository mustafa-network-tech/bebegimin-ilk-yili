-- Phase 13: legacy cutoff and grandfather decisions, rollout report, release
-- health, output quotas and client configuration.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('a2000000-0000-4000-8000-000000000001', 'rel-anne@example.com'),
  ('a2000000-0000-4000-8000-000000000031', 'rel-admin@example.com');
insert into public.platform_user_roles (user_id, role) values ('a2000000-0000-4000-8000-000000000031', 'super_admin');

-- A legacy baby: 500 days old, no extension, with content written before the
-- lifecycle existed, some of it dated on / after its close date (birth + 375;
-- decision P-1 of 2026-10-02).
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000001');
select (public.create_baby('Eski', public.business_date_istanbul() - 500, 'anne')).id as old_baby \gset
select public.family_account_id_for_baby(:'old_baby') as acct \gset
reset role;
select tests.logout();
select birth_date::text as birth from public.babies where id = :'old_baby' \gset

insert into public.memories (id, baby_id, author_id, title, memory_date) values
  ('a2100000-0000-4000-8000-000000000001', :'old_baby', 'a2000000-0000-4000-8000-000000000001', 'İlk yıl içinde', :'birth'::date + 100),
  ('a2100000-0000-4000-8000-000000000004', :'old_baby', 'a2000000-0000-4000-8000-000000000001', 'Son gün', :'birth'::date + 374),
  ('a2100000-0000-4000-8000-000000000002', :'old_baby', 'a2000000-0000-4000-8000-000000000001', 'Tavan günü', :'birth'::date + 405),
  ('a2100000-0000-4000-8000-000000000003', :'old_baby', 'a2000000-0000-4000-8000-000000000001', 'Legacy sonrası', :'birth'::date + 450);
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status) values
  ('a2200000-0000-4000-8000-000000000001', :'old_baby', 'a2000000-0000-4000-8000-000000000001', 'photo',
   :'old_baby' || '/a2200000-0000-4000-8000-000000000001/p.jpg', 'image/jpeg', :'birth'::date + 460, 'ready');
insert into public.comments (baby_id, author_id, memory_id, body)
values (:'old_baby', 'a2000000-0000-4000-8000-000000000001', 'a2100000-0000-4000-8000-000000000003', 'Legacy yorum');
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'rel-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'small_family' and p.billing_period = 'monthly';
insert into public.premium_orders (id, family_account_id, baby_id, product_id, product_code, price_minor, currency, provider, status, paid_at)
select 'a2400000-0000-4000-8000-000000000001', :'acct', :'old_baby', p.id, p.code, p.price_minor, p.currency, 'mock', 'paid', now()
  from public.current_premium_products() p where p.code = 'first_year_html';
insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
values (:'acct', :'old_baby', 'first_year_html', 'a2400000-0000-4000-8000-000000000001');

-- Legacy cutoff -------------------------------------------------------------------------------------------
select public.output_create_snapshot(:'old_baby', 'first_year_html') as snap1 \gset
select tests.eq((select string_agg(m ->> 'title', ',' order by m ->> 'memory_date') from public.archive_snapshots s,
                        jsonb_array_elements(s.content -> 'memories') m where s.id = :'snap1'),
                'İlk yıl içinde,Son gün', 'only content before the close date (birth + 375 without an extension) is sealed');
select tests.eq((select jsonb_array_length(content -> 'media') || ':' || jsonb_array_length(content -> 'comments')
                   from public.archive_snapshots where id = :'snap1'), '0:0', 'post-cutoff media and their comments stay out');
select tests.eq((select count(*) from public.memories where baby_id = :'old_baby'), 4::bigint, 'legacy content is never deleted');

set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000001');
select tests.expect_error(format($q$select public.admin_set_legacy_grandfather(%L, true, 'aile talebiyle eklendi')$q$, :'old_baby'),
                          'not authorized');
select tests.login('a2000000-0000-4000-8000-000000000031');
select tests.expect_error(format($q$select public.admin_set_legacy_grandfather(%L, true, 'kısa')$q$, :'old_baby'), 'reason');
select tests.eq(public.admin_set_legacy_grandfather(:'old_baby', true, 'Aile destek talebi #1234: eski anılar da dahil edilsin'), true,
                'Super Admin grandfathers the legacy content with a reason');
reset role;
select tests.logout();
select public.output_create_snapshot(:'old_baby', 'first_year_html') as snap2 \gset
select tests.eq(:'snap2'::uuid <> :'snap1'::uuid, true, 'the decision produces a new sealed snapshot');
select tests.eq((select jsonb_array_length(content -> 'memories') || ':' || jsonb_array_length(content -> 'media') || ':'
                        || jsonb_array_length(content -> 'comments') from public.archive_snapshots where id = :'snap2'),
                '4:1:1', 'grandfathered: legacy content, media and comments are included');
select tests.eq((select jsonb_array_length(content -> 'memories') from public.archive_snapshots where id = :'snap1'), 2,
                'the earlier sealed snapshot is unchanged');
select tests.eq((select count(*) from public.activity_logs where baby_id = :'old_baby' and action = 'legacy_grandfathered'
                    and details ->> 'reason' like 'Aile destek talebi%'), 1::bigint, 'the decision is audited with its reason');
select tests.expect_error($q$update public.legacy_grandfather_decisions set include = false$q$, 'append-only');
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000031');
select public.admin_set_legacy_grandfather(:'old_baby', false, 'Karar geri alındı: aile vazgeçti');
reset role;
select tests.logout();
select tests.eq(public.legacy_content_included(:'old_baby'), false, 'the latest decision wins');

-- Rollout report ------------------------------------------------------------------------------------------
insert into public.babies (id, first_name, birth_date, created_by)
values ('a2300000-0000-4000-8000-000000000001', 'Eşleşmemiş', public.business_date_istanbul() - 50, 'a2000000-0000-4000-8000-000000000001');
delete from public.family_account_babies where baby_id = 'a2300000-0000-4000-8000-000000000001';
insert into storage.objects (bucket_id, name, metadata)
values ('baby-media', :'old_baby' || '/a2900000-0000-4000-8000-000000000009/kayip.jpg', '{"size": 10}');
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select public.admin_legacy_rollout_report()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_release_health()$q$, 'not authorized');
select tests.login('a2000000-0000-4000-8000-000000000031');
select public.admin_legacy_rollout_report() as report \gset
select tests.eq((:'report'::jsonb -> 'babies_locked_ids') ? :'old_baby', true, 'babies past the lifecycle are reported as LOCKED');
select tests.eq((select (e ->> 'items')::int from jsonb_array_elements(:'report'::jsonb -> 'post_cutoff_content') e
                  where e ->> 'baby_id' = :'old_baby'), 3, 'items on / after the close date are counted per baby');
select tests.eq((:'report'::jsonb -> 'unmapped_babies') ? 'a2300000-0000-4000-8000-000000000001', true,
                'babies without a family account are reported (never merged automatically)');
select tests.eq((:'report'::jsonb -> 'orphan_media_sample') ? (:'old_baby' || '/a2900000-0000-4000-8000-000000000009/kayip.jpg'), true,
                'orphan storage objects are reported');

-- Release health ----------------------------------------------------------------------------------------------
select tests.eq((select count(*) from public.admin_release_health()), 10::bigint, 'ten rollout checks');
select tests.eq((select status || ':' || value from public.admin_release_health() where check_name = 'demo_accounts'), 'critical:4',
                'the seeded demo accounts are a critical finding (never in production)');
select tests.eq((select status from public.admin_release_health() where check_name = 'lifecycle_mismatch'), 'ok', 'lifecycle invariants hold');
reset role;
select tests.logout();
select tests.eq((select count(*) from storage.objects where name like '%kayip.jpg'), 1::bigint, 'orphan objects are reported, never deleted');
-- Corrupt data cannot be written through the API (babies_guard refuses a
-- future birth date); simulate an out-of-band corruption to prove the check.
alter table public.babies disable trigger babies_guard;
alter table public.babies disable trigger babies_lifecycle_guard;
update public.babies set birth_date = public.business_date_istanbul() + 3 where id = 'a2300000-0000-4000-8000-000000000001';
alter table public.babies enable trigger babies_guard;
alter table public.babies enable trigger babies_lifecycle_guard;
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000031');
select tests.eq((select status || ':' || value from public.admin_release_health() where check_name = 'lifecycle_mismatch'), 'critical:1',
                'a birth date in the future is flagged critical');
reset role;
select tests.logout();
alter table public.babies disable trigger babies_guard;
alter table public.babies disable trigger babies_lifecycle_guard;
update public.babies set birth_date = public.business_date_istanbul() - 50 where id = 'a2300000-0000-4000-8000-000000000001';
alter table public.babies enable trigger babies_guard;
alter table public.babies enable trigger babies_lifecycle_guard;

-- Quotas ----------------------------------------------------------------------------------------------------------
update public.platform_settings set value = '{"first_year_book": 30, "first_year_film": 12, "first_year_html": 1}'
 where key = 'output_daily_quota';
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000001');
select tests.eq((select reused from public.html_request_render(:'old_baby', 'rel-html-0001')), false, 'first archive request of the day');
reset role;
select tests.logout();
-- A changed snapshot would need a new job: the daily quota refuses it.
update public.profiles set display_name = 'Yeni' where id = 'a2000000-0000-4000-8000-000000000001';
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'old_baby', 'rel-html-0002'), 'quota_exceeded');
reset role;
select tests.logout();
update public.platform_settings set value = '{"first_year_book": 30, "first_year_film": 12, "first_year_html": 6}'
 where key = 'output_daily_quota';

-- Client configuration ----------------------------------------------------------------------------------------------
set role anon;
select tests.eq((select min_supported_build from public.app_config()), 1, 'anyone can read the minimum client build');
select tests.expect_error($q$select public.path_uuid('a/b', 1)$q$, 'permission denied');
reset role;
update public.platform_settings set value = '7' where key = 'client_min_build';
set role authenticated;
select tests.eq((select min_supported_build from public.app_config()), 7, 'raising the minimum build forces old clients to upgrade');
select tests.eq(public.path_segment('a/b', 2), 'b', 'policy helpers still work for signed-in users');
reset role;
update public.platform_settings set value = '1' where key = 'client_min_build';
set role authenticated;
select tests.expect_error($q$select * from public.platform_settings$q$, 'permission denied');
select tests.expect_error($q$update public.platform_settings set value = '0'$q$, 'permission denied');
reset role;

-- Legal erasure (KVKK): a baby with purchases and outputs can be deleted ----------------------------------------
select tests.ready_artifact(:'old_baby', 'first_year_html', 'a2000000-0000-4000-8000-000000000001', 'rel-erase-0001', 'arsiv.zip') as erase_art \gset
select storage_path as erase_path from public.output_artifacts where id = :'erase_art' \gset
set role authenticated;
select tests.login('a2000000-0000-4000-8000-000000000001');
select tests.eq((select allowed from public.authorize_artifact_download(:'erase_art')), true, 'the archive was downloaded before erasure');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.archive_snapshots where baby_id = :'old_baby') > 0, true, 'snapshots exist before erasure');
select tests.expect_error(format('delete from public.archive_snapshots where baby_id = %L', :'old_baby'), 'immutable');
select tests.eq((select count(*) from public.delete_baby_for_user('a2000000-0000-4000-8000-000000000001', :'old_baby')) > 0, true,
                'a baby with purchases and outputs can be erased');
select tests.eq((select count(*) from public.babies where id = :'old_baby'), 0::bigint, 'the baby is gone');
select tests.eq((select (select count(*) from public.archive_snapshots where baby_id = :'old_baby')
                      + (select count(*) from public.output_projects where baby_id = :'old_baby')
                      + (select count(*) from public.output_jobs where baby_id = :'old_baby')
                      + (select count(*) from public.output_artifacts where baby_id = :'old_baby')
                      + (select count(*) from public.output_artifact_downloads where artifact_id = :'erase_art')), 0::bigint,
                'personal content (snapshots, outputs, download audit) is erased');
select tests.eq((select count(*) from public.storage_cleanup_queue where bucket_id = 'output-artifacts' and path = :'erase_path'), 1::bigint,
                'output files are queued for physical deletion');
select tests.eq((select baby_id is null and status = 'paid' from public.premium_orders where id = 'a2400000-0000-4000-8000-000000000001'), true,
                'the order is kept for legal retention without the baby link');
select tests.eq((select baby_id is null from public.product_entitlements where source_order_id = 'a2400000-0000-4000-8000-000000000001'), true,
                'the entitlement record is kept without the baby link');
select tests.expect_error($q$delete from public.archive_snapshots where id = (select id from public.archive_snapshots limit 1)$q$, 'immutable');
select tests.expect_error($q$delete from public.product_entitlements where id = (select id from public.product_entitlements limit 1)$q$, 'permanent');
select tests.eq(public.legal_erasure_active(), false, 'the erasure switch never leaks out of its transaction');
