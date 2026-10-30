-- Phase 11: offline HTML archive (ZIP) requests, worker API and publish.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('ab000000-0000-4000-8000-000000000001', 'html-anne@example.com'),
  ('ab000000-0000-4000-8000-000000000011', 'html-teyze@example.com'),
  ('ab000000-0000-4000-8000-000000000021', 'html-yabanci@example.com');

set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000001');
select (public.create_baby('Ada', public.business_date_istanbul() - 400, 'anne')).id as ada \gset
select (public.create_baby('Açık', public.business_date_istanbul() - 30, 'anne')).id as active_baby \gset
select public.family_account_id_for_baby(:'ada') as acct \gset
reset role;
select tests.logout();

insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'ada', 'HTTEYZE222', 'teyze', false, '{view_memories,view_album}', 'ab000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000011');
select public.accept_invitation('HTTEYZE222');
reset role;
select tests.logout();

insert into public.memories (baby_id, author_id, title, body, memory_date)
select :'ada', 'ab000000-0000-4000-8000-000000000001', '<script>alert(1)</script> İlk gün', 'Gülüş & sevinç', b.birth_date + 3
  from public.babies b where b.id = :'ada';

-- Gate ---------------------------------------------------------------------------------------------------
set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000001');
select tests.eq((select access_block from public.html_access_state(:'active_baby')), 'premium_requires_locked', 'ACTIVE baby: no archive');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'active_baby', 'html-active-01'), 'premium_requires_locked');
select tests.eq(tests.count(format('select 1 from public.html_state(%L)', :'active_baby')), 0::bigint, 'ACTIVE: nothing listed');
select tests.eq((select access_block from public.html_access_state(:'ada')), 'subscription_required', 'LOCKED without subscription');
reset role;
select tests.logout();
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'html-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'normal_family' and p.billing_period = 'monthly';
set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'ada', 'html-noent-01'), 'entitlement_required');
reset role;
select tests.logout();
insert into public.premium_orders (id, family_account_id, baby_id, product_id, product_code, price_minor, currency, provider, status, paid_at)
select 'ab400000-0000-4000-8000-000000000001', :'acct', :'ada', p.id, p.code, p.price_minor, p.currency, 'mock', 'paid', now()
  from public.current_premium_products() p where p.code = 'first_year_html';
insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
values (:'acct', :'ada', 'first_year_html', 'ab400000-0000-4000-8000-000000000001');

set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000011');
select tests.eq((select access_block from public.html_access_state(:'ada')), 'not_parent', 'family member cannot create the archive');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'ada', 'html-teyze-01'), 'not_parent');
select tests.login('ab000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.html_access_state(%L)', :'ada'), 'not found');
select tests.expect_error(format('select * from public.html_state(%L)', :'ada'), 'not found');

-- Requests: idempotent, joined, kill switch -------------------------------------------------------------------
select tests.login('ab000000-0000-4000-8000-000000000001');
select tests.eq((select access_block is null and renderer_enabled from public.html_access_state(:'ada')), true, 'entitled parent may create the archive');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'ada', 'bad key!'), 'idempotency');
select job_id as job1, snapshot_id as snap1, reused as job1_reused from public.html_request_render(:'ada', 'html-req-0001') \gset
select tests.eq(:'job1_reused'::boolean, false, 'first request creates a job');
select tests.eq((select job_id from public.html_request_render(:'ada', 'html-req-0001')), :'job1'::uuid, 'same key returns the job');
select tests.eq((select job_id || ':' || reused from public.html_request_render(:'ada', 'html-req-0002')), :'job1' || ':true',
                'same snapshot joins the waiting job');
select tests.eq((select job_status || ':' || progress_stage from public.html_state(:'ada')), 'queued:queued', 'state shows the queued job');
reset role;
select tests.logout();
update public.platform_flags set enabled = false where key = 'html_renderer';
set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000001');
select tests.eq((select renderer_enabled from public.html_access_state(:'ada')), false, 'state shows the paused builder');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'ada', 'html-paused-01'), 'html_renderer_disabled');
reset role;
select tests.logout();
update public.platform_flags set enabled = true where key = 'html_renderer';

-- Worker ------------------------------------------------------------------------------------------------------
select tests.eq((select coalesce(bool_and(product_code = 'first_year_film'), true)
                   from public.output_claim_jobs('film-only', array['first_year_film'], 10)), true,
                'a film-only worker never takes archive jobs');
select tests.eq((select job_id from public.output_claim_jobs('out-1', array['first_year_film', 'first_year_html'])), :'job1'::uuid,
                'output worker claims the archive job');
select tests.expect_error(format($q$select * from public.html_job_payload(%L, 'out-2')$q$, :'job1'), 'lease_lost');
select snapshot_content, snapshot_checksum from public.html_job_payload(:'job1', 'out-1') \gset
select tests.eq(encode(sha256(convert_to(:'snapshot_content', 'UTF8')), 'hex'), :'snapshot_checksum'::text, 'payload is the sealed snapshot text');
select tests.eq(position('<script>' in :'snapshot_content') > 0, true, 'raw user text reaches the worker (it must escape it)');
select tests.eq(public.output_job_progress_update(:'job1', 'out-2', 50, 'media'), false, 'foreign worker cannot report progress');
select tests.eq(public.output_job_progress_update(:'job1', 'out-1', 50, 'media'), true, 'owner reports progress');

select artifact_id as art, staging_path as art_staging, storage_path as art_path
  from public.output_artifact_begin(:'job1', 'out-1', 'ilk-yil-arsivi.zip', 'application/zip', repeat('e', 64), 9000) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art_staging', '{"size": 9000}');
select tests.eq(public.output_artifact_verify(:'art', 'out-1', repeat('e', 64)), 'verified', 'zip verified');
update storage.objects set name = :'art_path' where bucket_id = 'output-artifacts' and name = :'art_staging';
select tests.expect_error(format($q$select public.html_artifact_publish(%L, 'out-1', 2, 100, 0, %L)$q$, :'art', repeat('f', 64)), 'invalid archive metadata');
select tests.expect_error(format($q$select public.html_artifact_publish(%L, 'out-2', 12, 100, 0, %L)$q$, :'art', repeat('f', 64)), 'lease_lost');
select tests.eq(public.html_artifact_publish(:'art', 'out-1', 12, 30000, 1, repeat('f', 64)), 'ready', 'archive published');
select tests.eq((select entry_count || ':' || content_bytes || ':' || skipped_media from public.html_artifact_metadata where artifact_id = :'art'),
                '12:30000:1', 'bundle metadata stored');
select tests.expect_error(format($q$update public.html_artifact_metadata set entry_count = 1 where artifact_id = %L$q$, :'art'), 'append-only');
select tests.eq(:'art_path'::text like :'ada' || '/first_year_html/' || :'snap1' || '/v1/ilk-yil-arsivi.zip', true,
                'archive path names the snapshot and version');

set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000001');
select tests.eq((select job_status || ':' || progress_percent || ':' || entry_count || ':' || skipped_media || ':' || coalesce(download_block, 'ok')
                   from public.html_state(:'ada')), 'succeeded:100:12:1:ok', 'state shows the ready archive');
select tests.eq((select job_id || ':' || reused from public.html_request_render(:'ada', 'html-req-0003')), :'job1' || ':true',
                'the archive of an unchanged snapshot is not built twice');
select tests.eq((select storage_path || ':' || sha256 from public.request_output_download(:'art')), :'art_path' || ':' || repeat('e', 64),
                'parent downloads the ZIP; the same sha256 on every download');
select tests.eq((select sha256 from public.request_output_download(:'art')), repeat('e', 64), 're-download returns the same checksum');
select tests.login('ab000000-0000-4000-8000-000000000011');
select tests.eq((select artifact_id is null from public.html_state(:'ada')), true, 'the archive is hidden from a Family Member');
-- Decision P-12 (2026-10-02): nothing can be shared with Family Members.
select tests.login('ab000000-0000-4000-8000-000000000001');
select tests.expect_error(
  format('select public.set_artifact_download_permission(%L, %L, %L, true)', :'ada', 'ab000000-0000-4000-8000-000000000011',
         'first_year_html'),
  'member_downloads_disabled');
select tests.login('ab000000-0000-4000-8000-000000000011');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'art'), 'not_parent');
reset role;
select tests.logout();

-- A changed snapshot (a live display name changed) builds a new archive version.
update public.profiles set display_name = 'Yeni Ad' where id = 'ab000000-0000-4000-8000-000000000001';
set role authenticated;
select tests.login('ab000000-0000-4000-8000-000000000001');
select job_id as job2, snapshot_id as snap2, reused as job2_reused from public.html_request_render(:'ada', 'html-req-0004') \gset
select tests.eq(:'job2_reused'::boolean, false, 'a new snapshot gets a new job');
select tests.eq(:'snap2'::uuid <> :'snap1'::uuid, true, 'with a new sealed snapshot');
reset role;
select tests.logout();
