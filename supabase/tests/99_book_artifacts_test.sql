-- Phase 9: book premium gate and the verified client-render protocol.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('9e000000-0000-4000-8000-000000000001', 'book-anne@example.com'),
  ('9e000000-0000-4000-8000-000000000002', 'book-baba@example.com'),
  ('9e000000-0000-4000-8000-000000000011', 'book-teyze@example.com'),
  ('9e000000-0000-4000-8000-000000000021', 'book-yabanci@example.com'),
  ('9e000000-0000-4000-8000-000000000031', 'book-admin@example.com');
insert into public.platform_user_roles (user_id, role) values ('9e000000-0000-4000-8000-000000000031', 'super_admin');

-- Lale (LOCKED, will own the book), Mina (LOCKED sibling, no book), Açık (ACTIVE).
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select (public.create_baby('Lale', public.business_date_istanbul() - 400, 'anne')).id as lale \gset
select (public.create_baby('Mina', public.business_date_istanbul() - 390, 'anne')).id as mina \gset
select (public.create_baby('Açık', public.business_date_istanbul() - 30, 'anne')).id as active_baby \gset
select public.family_account_id_for_baby(:'lale') as acct \gset
reset role;
select tests.logout();

insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'lale', 'KTBABA2222', 'baba', true, '{}', '9e000000-0000-4000-8000-000000000001'),
  (:'lale', 'KTTEYZE222', 'teyze', false, '{view_memories,view_album}', '9e000000-0000-4000-8000-000000000001'),
  (:'mina', 'KTMNBA2222', 'baba', true, '{}', '9e000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000002');
select public.accept_invitation('KTBABA2222');
select public.accept_invitation('KTMNBA2222');
select tests.login('9e000000-0000-4000-8000-000000000011');
select public.accept_invitation('KTTEYZE222');
reset role;
select tests.logout();

-- Lale's archive.
insert into public.memories (id, baby_id, author_id, title, body, memory_date) values
  ('9e100000-0000-4000-8000-000000000001', :'lale', '9e000000-0000-4000-8000-000000000001', 'İlk gülüş', 'Sabah', public.business_date_istanbul() - 350);
insert into public.letters (baby_id, author_id, author_name, author_relation, body, written_on)
values (:'lale', '9e000000-0000-4000-8000-000000000011', 'Zeynep', 'teyze', 'Sevgili Lale', public.business_date_istanbul() - 200);
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status) values
  ('9e200000-0000-4000-8000-000000000001', :'lale', '9e000000-0000-4000-8000-000000000001', 'photo',
   :'lale' || '/9e200000-0000-4000-8000-000000000001/p.jpg', 'image/jpeg', public.business_date_istanbul() - 350, 'ready');

-- Legacy data written before the gate existed (Phase 9 migration marks such
-- rows legacy_quarantined). The guards are bypassed only to recreate them.
alter table public.book_projects disable trigger book_projects_insert_guard;
alter table public.book_exports disable trigger book_exports_guard;
alter table public.book_exports disable trigger book_exports_on_created;
insert into public.book_projects (id, baby_id, title, format, current_version, legacy_status, created_by)
values ('9e300000-0000-4000-8000-000000000001', :'lale', 'Lale''nin İlk Yılı', 'square_21', 2, 'legacy_quarantined',
        '9e000000-0000-4000-8000-000000000001');
insert into public.book_pages (id, project_id, baby_id, page_type, month_index, title, sort_order) values
  ('9e310000-0000-4000-8000-000000000001', '9e300000-0000-4000-8000-000000000001', :'lale', 'cover', null, 'Kapak', 0),
  ('9e310000-0000-4000-8000-000000000002', '9e300000-0000-4000-8000-000000000001', :'lale', 'month', 1, '1. Ayım', 1),
  ('9e310000-0000-4000-8000-000000000003', '9e300000-0000-4000-8000-000000000001', :'lale', 'one_year', null, 'Bir Yaşındayım', 2);
insert into public.book_items (id, page_id, baby_id, item_type, memory_id, sort_order) values
  ('9e320000-0000-4000-8000-000000000001', '9e310000-0000-4000-8000-000000000002', :'lale', 'memory', '9e100000-0000-4000-8000-000000000001', 0);
insert into public.book_exports (project_id, baby_id, version, format, storage_path, page_count, size_bytes, legacy_status) values
  ('9e300000-0000-4000-8000-000000000001', :'lale', 1, 'square_21', :'lale' || '/9e300000-0000-4000-8000-000000000001/v1.pdf', 30, 1000, 'legacy_quarantined'),
  ('9e300000-0000-4000-8000-000000000001', :'lale', 2, 'square_21', :'lale' || '/9e300000-0000-4000-8000-000000000001/v2.pdf', 32, 1100, 'legacy_quarantined');
insert into storage.objects (bucket_id, name, metadata)
values ('books', :'lale' || '/9e300000-0000-4000-8000-000000000001/v2.pdf', '{"size": 1100}');
alter table public.book_projects enable trigger book_projects_insert_guard;
alter table public.book_exports enable trigger book_exports_guard;
alter table public.book_exports enable trigger book_exports_on_created;

-- Gate: LOCKED alone is not enough ------------------------------------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.eq((select access_block from public.book_access_state(:'active_baby')), 'premium_requires_locked', 'ACTIVE baby: locked first');
select tests.eq((select access_block from public.book_access_state(:'lale')), 'subscription_required', 'LOCKED without subscription');
select tests.eq(tests.count('select 1 from book_projects'), 0::bigint, 'legacy project hidden without the gate');
select tests.expect_error(format($q$insert into book_pages (project_id, baby_id, page_type, title, sort_order)
  values ('9e300000-0000-4000-8000-000000000001', %L, 'custom', 'Erken', 9)$q$, :'lale'), 'row-level security');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'book-nosub-0001'), 'subscription_required');
reset role;
select tests.logout();

insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'book-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'normal_family' and p.billing_period = 'monthly';

set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.eq((select access_block from public.book_access_state(:'lale')), 'entitlement_required', 'LOCKED + subscription, no entitlement');
select tests.eq(tests.count('select 1 from book_projects'), 0::bigint, 'still hidden without the book entitlement');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'book-noent-0001'), 'entitlement_required');
reset role;
select tests.logout();

-- Verified payments grant Lale's book (and only Lale's book).
insert into public.premium_orders (id, family_account_id, baby_id, product_id, product_code, price_minor, currency, provider, status, paid_at)
select '9e400000-0000-4000-8000-000000000001', :'acct', :'lale', p.id, p.code, p.price_minor, p.currency, 'mock', 'paid', now()
  from public.current_premium_products() p where p.code = 'first_year_book';
insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
values (:'acct', :'lale', 'first_year_book', '9e400000-0000-4000-8000-000000000001');

-- Entitled parent: configuration only, source archive untouched ---------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.eq((select access_block is null and has_project and renderer_enabled from public.book_access_state(:'lale')), true,
                'entitled parent may use the book');
select tests.eq(tests.count('select 1 from book_projects'), 1::bigint, 'legacy configuration is reusable after the gate');
select tests.eq(tests.count('select 1 from book_items'), 1::bigint, 'book items visible to the entitled parent');
select tests.eq(tests.count(format('select 1 from public.book_versions(%L)', :'lale')), 0::bigint, 'legacy exports are never listed');
select tests.expect_error($q$select 1 from book_exports$q$, 'permission denied');
select tests.eq(tests.count($q$select 1 from storage.objects where bucket_id = 'books'$q$), 0::bigint, 'legacy PDF files are not readable');
select tests.expect_error(format($q$insert into storage.objects (bucket_id, name) values ('books', %L)$q$,
                                 :'lale' || '/9e300000-0000-4000-8000-000000000001/v3.pdf'), 'row-level security');
update book_projects set title = 'Lale''nin Kitabı', format = 'square_21' where id = '9e300000-0000-4000-8000-000000000001';
update book_projects set current_version = 99, legacy_status = null where id = '9e300000-0000-4000-8000-000000000001';
reset role;
select tests.eq((select current_version || ':' || legacy_status from public.book_projects where id = '9e300000-0000-4000-8000-000000000001'),
                '2:legacy_quarantined', 'version and legacy marker cannot be forged');
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
insert into book_pages (id, project_id, baby_id, page_type, title, body, sort_order)
values ('9e310000-0000-4000-8000-000000000009', '9e300000-0000-4000-8000-000000000001', :'lale', 'custom', 'Özel sayfa', 'Not', 3);
update book_pages set is_hidden = true where id = '9e310000-0000-4000-8000-000000000003';
update book_pages set is_hidden = false where id = '9e310000-0000-4000-8000-000000000003';
insert into book_items (id, page_id, baby_id, item_type, media_id, sort_order, caption)
values ('9e320000-0000-4000-8000-000000000002', '9e310000-0000-4000-8000-000000000002', :'lale', 'media',
        '9e200000-0000-4000-8000-000000000001', 1, 'Açıklama');
select tests.eq(tests.count('select 1 from book_items'), 2::bigint, 'items can be added (configuration only)');
select tests.expect_error($q$delete from book_projects where id = '9e300000-0000-4000-8000-000000000001'$q$, 'permission denied');
select tests.expect_error(format($q$insert into book_projects (baby_id) values (%L)$q$, :'mina'), 'row-level security');
select tests.eq((select access_block from public.book_access_state(:'mina')), 'entitlement_required', 'sibling needs its own book');
reset role;
select tests.logout();
select tests.eq((select title from public.memories where id = '9e100000-0000-4000-8000-000000000001'), 'İlk gülüş',
                'source archive unchanged by book editing');

-- Family Member and strangers ----------------------------------------------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000011');
select tests.eq((select access_block from public.book_access_state(:'lale')), 'not_parent', 'family member cannot configure the book');
select tests.eq(tests.count('select 1 from book_projects'), 0::bigint, 'configuration hidden from family members');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'book-teyze-0001'), 'not_parent');
select tests.expect_error(format($q$insert into book_pages (project_id, baby_id, page_type, title, sort_order)
  values ('9e300000-0000-4000-8000-000000000001', %L, 'custom', 'Teyze', 9)$q$, :'lale'), 'row-level security');
select tests.login('9e000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.book_access_state(%L)', :'lale'), 'not found');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'book-stranger-01'), 'not found');
reset role;
select tests.logout();

-- Kill switch ---------------------------------------------------------------------------------------------------------
update public.platform_flags set enabled = false where key = 'book_renderer';
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.eq((select renderer_enabled from public.book_access_state(:'lale')), false, 'state shows the paused renderer');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'book-paused-0001'), 'book_renderer_disabled');
reset role;
select tests.logout();
update public.platform_flags set enabled = true where key = 'book_renderer';

-- Render start: snapshot + frozen manifest + lease ----------------------------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'bad key!'), 'idempotency');
select job_id as job1, snapshot_id as snap, attempt as job1_attempt, reused as job1_reused
  from public.book_render_start(:'lale', 'book-render-0001') \gset
select tests.eq(:'job1_reused'::boolean, false, 'first start creates the render job');
select tests.eq(:job1_attempt, 1, 'first attempt leased to the parent');
select tests.eq((select job_id from public.book_render_start(:'lale', 'book-render-0001')), :'job1'::uuid, 'same key resumes the same job');
select tests.eq((select reused from public.book_render_start(:'lale', 'book-render-0001')), true, 'resume is flagged as reused');
-- Configuration edits after the start never change the frozen manifest.
update book_projects set title = 'Sonradan değişti', format = 'a4_portrait' where id = '9e300000-0000-4000-8000-000000000001';
select snapshot_content, snapshot_checksum, manifest_content, manifest_checksum from public.book_render_payload(:'job1') \gset
select tests.eq(encode(sha256(convert_to(:'snapshot_content', 'UTF8')), 'hex'), :'snapshot_checksum'::text, 'payload snapshot hashes to its checksum');
select tests.eq(encode(sha256(convert_to(:'manifest_content', 'UTF8')), 'hex'), :'manifest_checksum'::text, 'payload manifest hashes to its checksum');
select tests.eq((:'manifest_content'::jsonb ->> 'title'), 'Lale''nin Kitabı', 'manifest keeps the title at start time');
select tests.eq((:'manifest_content'::jsonb ->> 'format'), 'square_21', 'manifest keeps the format at start time');
select tests.eq(jsonb_array_length(:'manifest_content'::jsonb -> 'book_pages'), 4, 'manifest holds every page (hidden ones included)');
select tests.eq((select string_agg(p ->> 'page_type', ',' order by (p ->> 'sort_order')::int)
                   from jsonb_array_elements(:'manifest_content'::jsonb -> 'book_pages') p),
                'cover,month,one_year,custom', 'chapter order including "Bir Yaşındayım" is frozen');
select tests.eq((select i ->> 'caption' from jsonb_array_elements(:'manifest_content'::jsonb -> 'book_pages') p,
                        jsonb_array_elements(p -> 'book_items') i where i ->> 'item_type' = 'media'), 'Açıklama',
                'item captions are part of the manifest');
select tests.eq((:'snapshot_content'::jsonb -> 'baby' ->> 'id'), :'lale'::text, 'snapshot belongs to the baby');
select tests.eq(public.book_render_heartbeat(:'job1'), true, 'owner heartbeat extends the lease');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.book_render_manifests where job_id = :'job1'), 1::bigint, 'one manifest per job');
select tests.expect_error(format($q$update public.book_render_manifests set content = '{}' where job_id = %L$q$, :'job1'), 'immutable');
select tests.expect_error(format($q$delete from public.book_render_manifests where job_id = %L$q$, :'job1'), 'immutable');
select tests.eq((select lease_owner from public.output_jobs where id = :'job1'), 'book-client:9e000000-0000-4000-8000-000000000001',
                'lease belongs to the parent''s client');

set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000002');
select tests.expect_error(format('select * from public.book_render_payload(%L)', :'job1'), 'not found');
select tests.expect_error(format('select public.book_render_heartbeat(%L)', :'job1'), 'not found');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'lale', 'book-baba-0001'), 'book_render_in_progress');
select tests.login('9e000000-0000-4000-8000-000000000011');
select tests.expect_error(format('select * from public.book_render_payload(%L)', :'job1'), 'not found');

-- Upload: only the exact staging path of the caller's live attempt -----------------------------------------------------
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.expect_error(format($q$select * from public.book_artifact_begin(%L, %L, 0)$q$, :'job1', repeat('d', 64)), 'checksum and size');
select artifact_id as art, staging_path as art_staging, storage_path as art_path
  from public.book_artifact_begin(:'job1', repeat('d', 64), 4096) \gset
select tests.eq(:'art_path'::text, format('%s/first_year_book/%s/v1/ilk-yil-kitabi.pdf', :'lale', :'snap'),
                'official PDF path is baby/product/snapshot/version');
select tests.expect_error(format($q$insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', %L, '{"size": 4096}')$q$,
                                 :'art_path'), 'row-level security');
select tests.expect_error(format($q$insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', %L, '{"size": 4096}')$q$,
                                 'staging/' || gen_random_uuid() || '/ilk-yil-kitabi.pdf'), 'row-level security');
select tests.login('9e000000-0000-4000-8000-000000000002');
select tests.expect_error(format($q$insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', %L, '{"size": 4096}')$q$,
                                 :'art_staging'), 'row-level security');
select tests.expect_error(format('select * from public.book_artifact_begin(%L, %L, 10)', :'job1', repeat('d', 64)), 'not found');
select tests.login('9e000000-0000-4000-8000-000000000001');
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art_staging', '{"size": 4096}');
select tests.eq(tests.count($q$select 1 from storage.objects where bucket_id = 'output-artifacts'$q$), 0::bigint,
                'clients cannot read the output bucket directly');
select tests.expect_error(format($q$select * from public.book_artifact_publish(%L, %L, 10)$q$, :'art',
                                 'book-client:9e000000-0000-4000-8000-000000000001'), 'permission denied');
reset role;
select tests.logout();

-- Finalize (book-artifact-finalize Edge Function, service role) -----------------------------------------------------------
select tests.eq(public.output_artifact_verify(:'art', 'book-client:9e000000-0000-4000-8000-000000000002', repeat('d', 64)), 'lease_lost',
                'another parent''s client cannot verify the upload');
select tests.eq(public.output_artifact_verify(:'art', 'book-client:9e000000-0000-4000-8000-000000000001', repeat('d', 64)), 'verified',
                'server-side hash matches the declared checksum');
update storage.objects set name = :'art_path' where bucket_id = 'output-artifacts' and name = :'art_staging';
select tests.expect_error(format($q$select * from public.book_artifact_publish(%L, %L, 0)$q$, :'art',
                                 'book-client:9e000000-0000-4000-8000-000000000001'), 'invalid page count');
select status as pub_status, export_id as export1, book_version as export1_version
  from public.book_artifact_publish(:'art', 'book-client:9e000000-0000-4000-8000-000000000001', 48) \gset
select tests.eq(:'pub_status'::text, 'ready', 'publish turns the artifact ready');
select tests.eq(:export1_version, 3, 'book version continues after the legacy versions');
select tests.eq((select status from public.output_jobs where id = :'job1'), 'succeeded', 'render job succeeded');
select tests.eq((select artifact_id = :'art'::uuid and bucket_id = 'output-artifacts' and storage_path = :'art_path'
                        and format = 'square_21' and page_count = 48 and size_bytes = 4096 and legacy_status is null
                   from public.book_exports where id = :'export1'), true,
                'export row is bound to the artifact (format from the frozen manifest)');
select tests.eq((select current_version from public.book_projects where id = '9e300000-0000-4000-8000-000000000001'), 3,
                'project version bumped by the publish step');
select tests.eq((select count(*) from public.notifications where type = 'book_generated' and baby_id = :'lale'), 2::bigint,
                'baba and teyze are notified (the requester is not)');
select tests.expect_error(format($q$insert into public.book_exports (project_id, baby_id, version, format, storage_path, page_count)
  values ('9e300000-0000-4000-8000-000000000001', %L, 9, 'square_21', %L, 1)$q$, :'lale',
  :'lale' || '/9e300000-0000-4000-8000-000000000001/v9.pdf'), 'book_export_requires_artifact');
select tests.expect_error(format($q$insert into public.book_exports (project_id, baby_id, version, format, storage_path, page_count, size_bytes,
                                                                   artifact_id, bucket_id)
  values ('9e300000-0000-4000-8000-000000000001', %L, 9, 'square_21', %L, 1, 4096, %L, 'output-artifacts')$q$, :'lale', :'art_path', :'art'),
  'publish step only');
select tests.expect_error(format($q$update public.book_exports set page_count = 1 where id = %L$q$, :'export1'), 'immutable');

-- Versions and downloads --------------------------------------------------------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.eq((select version || ':' || page_count || ':' || coalesce(download_block, 'ok')
                   from public.book_versions(:'lale')), '3:48:ok', 'parent sees the official version');
select tests.eq((select storage_path from public.request_output_download(:'art')), :'art_path'::text, 'parent can download');
select tests.login('9e000000-0000-4000-8000-000000000011');
select tests.eq(tests.count(format('select 1 from public.book_versions(%L)', :'lale')), 0::bigint, 'a Family Member sees no version');
-- Decision P-12 (2026-10-02): the parents cannot share downloads any more.
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.expect_error(
  format('select public.set_artifact_download_permission(%L, %L, %L, true)', :'lale', '9e000000-0000-4000-8000-000000000011',
         'first_year_book'),
  'member_downloads_disabled');
select tests.eq((select sha256 from public.book_versions(:'lale')), repeat('d', 64), 'checksum offered for client-side verification');
select tests.login('9e000000-0000-4000-8000-000000000011');
select tests.eq(tests.count(format('select 1 from public.book_versions(%L)', :'lale')), 0::bigint,
                'a Family Member still sees no version');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'art'), 'not_parent');
select tests.login('9e000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.book_versions(%L)', :'lale'), 'not found');
reset role;
select tests.logout();

-- Re-render: supersede, client failure, retry with the frozen inputs ----------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select job_id as job2 from public.book_render_start(:'lale', 'book-render-0002') \gset
select tests.eq((:'manifest_content'::jsonb ->> 'title') <> (select manifest_content::jsonb ->> 'title' from public.book_render_payload(:'job2')),
                true, 'a new render freezes the current configuration');
select job_id as job3 from public.book_render_start(:'lale', 'book-render-0003') \gset
select tests.expect_error(format('select public.book_render_fail(%L, %L)', :'job3', 'boom'), 'invalid error code');
select tests.eq(public.book_render_fail(:'job3', 'render_failed'), 'retry_scheduled', 'client failure schedules a retry');
select tests.eq((select attempt || ':' || reused from public.book_render_start(:'lale', 'book-render-0003')), '2:true',
                'the same request re-leases its job');
reset role;
select tests.logout();
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'job2'), 'canceled:superseded',
                'an older attempt of the same parent is superseded');
select tests.eq((select string_agg(outcome, ',' order by attempt) from public.output_job_attempts where job_id = :'job3'),
                'failed', 'failed attempt recorded; second attempt running');
select tests.eq((select count(*) from public.book_render_manifests where job_id = :'job3'), 1::bigint, 'retry keeps one frozen manifest');

-- Expired client lease: the job returns to the queue and another parent may take over.
update public.output_jobs set lease_expires_at = now() - interval '1 second' where id = :'job3';
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.book_render_payload(%L)', :'job3'), 'lease_lost');
select tests.login('9e000000-0000-4000-8000-000000000002');
select job_id as job4 from public.book_render_start(:'lale', 'book-baba-0002') \gset
reset role;
select tests.logout();
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'job3'), 'canceled:superseded',
                'the stale queued job is superseded by the new render');

-- Access ends while rendering -------------------------------------------------------------------------------------------
update public.subscriptions set status = 'expired', current_period_end = now() - interval '1 day' where family_account_id = :'acct';
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000002');
select tests.expect_error(format('select * from public.book_render_payload(%L)', :'job4'), 'subscription_required');
select tests.expect_error(format('select * from public.book_artifact_begin(%L, %L, 10)', :'job4', repeat('e', 64)), 'subscription_required');
select tests.eq(tests.count('select 1 from book_projects'), 0::bigint, 'configuration closes with the subscription');
select tests.eq((select download_block from public.book_versions(:'lale')), 'subscription_required',
                'artifact kept, download closed while the subscription is inactive');
reset role;
select tests.logout();
update public.subscriptions set status = 'active', current_period_end = now() + interval '1 month' where family_account_id = :'acct';

-- Legacy report ------------------------------------------------------------------------------------------------------------
set role authenticated;
select tests.login('9e000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select * from public.admin_legacy_book_report()$q$, 'not authorized');
select tests.login('9e000000-0000-4000-8000-000000000031');
select tests.eq((select project_legacy::text || ':' || legacy_exports || ':' || official_exports || ':' || lifecycle_active::text
                   from public.admin_legacy_book_report() where project_id = '9e300000-0000-4000-8000-000000000001'),
                'true:2:1:false', 'legacy project and exports are reported, official ones counted separately');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.book_exports where legacy_status = 'legacy_quarantined' and baby_id = :'lale'), 2::bigint,
                'legacy exports are never deleted');
select tests.eq((select count(*) from storage.objects where bucket_id = 'books' and name like :'lale' || '/%'), 1::bigint,
                'legacy files are kept');
select tests.eq((select count(*) from public.product_entitlements where baby_id = :'mina'), 0::bigint,
                'no entitlement is granted automatically');
