-- Phase 8: immutable archive snapshots, output jobs and artifact pipeline.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('9d000000-0000-4000-8000-000000000001', 'output-anne@example.com'),
  ('9d000000-0000-4000-8000-000000000002', 'output-baba@example.com'),
  ('9d000000-0000-4000-8000-000000000011', 'output-teyze@example.com'),
  ('9d000000-0000-4000-8000-000000000012', 'output-hala@example.com'),
  ('9d000000-0000-4000-8000-000000000021', 'output-yabanci@example.com');
update public.profiles set display_name = 'Ayşe' where id = '9d000000-0000-4000-8000-000000000001';
update public.profiles set display_name = 'Zeynep' where id = '9d000000-0000-4000-8000-000000000011';

-- Defne (LOCKED, extended by 20 days), Ece (LOCKED sibling), Açık (ACTIVE).
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select (public.create_baby('Defne', public.business_date_istanbul() - 400, 'anne')).id as defne \gset
select (public.create_baby('Ece', public.business_date_istanbul() - 390, 'anne')).id as ece \gset
select (public.create_baby('Açık', public.business_date_istanbul() - 30, 'anne')).id as active_baby \gset
select public.family_account_id_for_baby(:'defne') as acct \gset
reset role;
select tests.logout();

insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'defne', 'UTBABA2222', 'baba', true, '{}', '9d000000-0000-4000-8000-000000000001'),
  (:'defne', 'UTTEYZE222', 'teyze', false, '{view_memories,view_album}', '9d000000-0000-4000-8000-000000000001'),
  (:'defne', 'UTHALA2222', 'hala', false, '{view_memories}', '9d000000-0000-4000-8000-000000000001'),
  (:'ece', 'UTECEBA222', 'baba', true, '{}', '9d000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000002');
select public.accept_invitation('UTBABA2222');
select public.accept_invitation('UTECEBA222');
select tests.login('9d000000-0000-4000-8000-000000000011');
select public.accept_invitation('UTTEYZE222');
select tests.login('9d000000-0000-4000-8000-000000000012');
select public.accept_invitation('UTHALA2222');
reset role;
select tests.logout();

-- Approved 20-day extension: Defne closed at day 395 and is LOCKED at 400.
insert into public.baby_extension_requests (baby_id, requested_by, requested_days)
values (:'defne', '9d000000-0000-4000-8000-000000000001', 20);
set app.lifecycle_extension_write = 'on';
update public.baby_extension_requests
   set status = 'approved', decided_by = '9d000000-0000-4000-8000-000000000002', decided_at = now()
 where baby_id = :'defne';
reset app.lifecycle_extension_write;

-- Lifecycle baseline after the extension; the output pipeline must never change it.
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select status as life_before, effective_close_date as close_before from public.baby_lifecycle_summary(:'defne') \gset
reset role;
select tests.logout();

-- Defne's archive (written while it was open, including the extension window).
insert into public.memories (id, baby_id, author_id, title, body, memory_date) values
  ('9d100000-0000-4000-8000-000000000001', :'defne', '9d000000-0000-4000-8000-000000000001', 'İlk gün', 'Merhaba', public.business_date_istanbul() - 399),
  ('9d100000-0000-4000-8000-000000000002', :'defne', '9d000000-0000-4000-8000-000000000011', 'Uzatmada', 'Teyze yazdı', public.business_date_istanbul() - 10);
insert into public.letters (baby_id, author_id, author_name, author_relation, body, written_on)
values (:'defne', '9d000000-0000-4000-8000-000000000011', 'Zeynep Teyze', 'teyze', 'Sevgili Defne', public.business_date_istanbul() - 200);
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status) values
  ('9d200000-0000-4000-8000-000000000001', :'defne', '9d000000-0000-4000-8000-000000000001', 'photo',
   :'defne' || '/9d200000-0000-4000-8000-000000000001/p.jpg', 'image/jpeg', public.business_date_istanbul() - 300, 'ready'),
  ('9d200000-0000-4000-8000-000000000002', :'defne', '9d000000-0000-4000-8000-000000000001', 'photo',
   :'defne' || '/9d200000-0000-4000-8000-000000000002/p.jpg', 'image/jpeg', public.business_date_istanbul() - 300, 'uploading');
insert into public.comments (baby_id, author_id, memory_id, body)
values (:'defne', '9d000000-0000-4000-8000-000000000011', '9d100000-0000-4000-8000-000000000001', 'Çok tatlı');
insert into public.time_capsules (id, baby_id, author_id, title, open_on)
values ('9d300000-0000-4000-8000-000000000001', :'defne', '9d000000-0000-4000-8000-000000000001', 'On sekiz yaş', current_date + 6000);
insert into public.time_capsule_contents (capsule_id, baby_id, body)
values ('9d300000-0000-4000-8000-000000000001', :'defne', 'GIZLI KAPSUL METNI');

-- Gates for snapshots and jobs -----------------------------------------------------------------------------
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select * from public.archive_snapshots$q$, 'permission denied');
select tests.expect_error($q$select * from public.output_jobs$q$, 'permission denied');
select tests.expect_error($q$select * from public.output_artifacts$q$, 'permission denied');
select tests.expect_error(format('select public.output_create_snapshot(%L, %L)', :'defne', 'first_year_book'), 'permission denied');
select tests.expect_error($q$select * from public.output_claim_jobs('w', array['first_year_book'])$q$, 'permission denied');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'active_baby', 'first_year_book', 'key-active-1'),
                          'premium_requires_locked');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_book', 'key-nosub-1'),
                          'subscription_required');
reset role;
select tests.logout();
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'output-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'normal_family' and p.billing_period = 'monthly';
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_book', 'key-noent-1'),
                          'entitlement_required');
reset role;
select tests.logout();
select tests.expect_error(format('select public.output_create_snapshot(%L, %L)', :'defne', 'first_year_book'), 'entitlement_required');
select tests.expect_error(format('select public.output_create_snapshot(%L, %L)', :'active_baby', 'first_year_book'), 'premium_requires_locked');
select tests.eq((select count(*) from public.archive_snapshots where baby_id in (:'defne', :'ece', :'active_baby')), 0::bigint,
                'no snapshot without LOCKED + entitlement');

-- Entitlements: Defne book + film, Ece book (as a verified payment would grant them).
insert into public.premium_orders (id, family_account_id, baby_id, product_id, product_code, price_minor, currency, provider, status, paid_at)
select v.id::uuid, :'acct', v.baby::uuid, p.id, p.code, p.price_minor, p.currency, 'mock', 'paid', now()
  from (values ('9d400000-0000-4000-8000-000000000001', :'defne', 'first_year_book'),
               ('9d400000-0000-4000-8000-000000000002', :'defne', 'first_year_film'),
               ('9d400000-0000-4000-8000-000000000003', :'ece', 'first_year_book')) v(id, baby, code)
  join public.current_premium_products() p on p.code = v.code;
insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
select o.family_account_id, o.baby_id, o.product_code, o.id from public.premium_orders o where o.id::text like '9d400000-%';

select tests.expect_error(format('select public.output_create_snapshot(%L, %L, %L)', :'defne', 'first_year_book',
                                 '9d000000-0000-4000-8000-000000000011'), 'not_parent');

set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000011');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_book', 'key-teyze-1'), 'not_parent');
select tests.login('9d000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_book', 'key-yabanci-1'), 'not found');
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_book', 'bad key!'), 'idempotency');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_html', 'key-html-1'),
                          'entitlement_required');

-- Idempotent job request -------------------------------------------------------------------------------------
select job_id as book_job, snapshot_id as snap, reused as first_reused
  from public.request_output_job(:'defne', 'first_year_book', 'book-key-0001') \gset
select tests.eq(:'first_reused'::boolean, false, 'first request creates the job');
select tests.eq((select job_id from public.request_output_job(:'defne', 'first_year_book', 'book-key-0001')), :'book_job'::uuid,
                'same idempotency key returns the same job');
select tests.eq((select job_id from public.request_output_job(:'defne', 'first_year_book', 'book-key-0002')), :'book_job'::uuid,
                'a queued job for the same snapshot is never duplicated');
select tests.login('9d000000-0000-4000-8000-000000000002');
select tests.eq((select job_id from public.request_output_job(:'defne', 'first_year_book', 'book-key-baba')), :'book_job'::uuid,
                'the other parent joins the same job');
select tests.eq((select job_status from public.baby_output_status(:'defne') where product_code = 'first_year_book'), 'queued',
                'status visible to the family');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.output_jobs where baby_id = :'defne'), 1::bigint, 'one job only');
select tests.eq((select count(*) from public.output_projects where baby_id = :'defne'), 1::bigint, 'one project per product');
select tests.expect_error(format($q$update public.output_projects set baby_id = %L where id =
  (select project_id from public.output_jobs where id = %L)$q$, :'ece', :'book_job'), 'immutable');

-- Snapshot content and sealing -------------------------------------------------------------------------------
select tests.eq((select checksum from public.archive_snapshots where id = :'snap'),
                encode(sha256(convert_to((select content::text from public.archive_snapshots where id = :'snap'), 'UTF8')), 'hex'),
                'checksum is sha256 of the canonical JSON');
select tests.eq((select checksum from public.output_snapshot_payload(:'snap')),
                encode(sha256(convert_to((select content from public.output_snapshot_payload(:'snap')), 'UTF8')), 'hex'),
                'payload text hashes to the stored checksum');
select tests.eq((select (content ->> 'schema_version')::integer from public.archive_snapshots where id = :'snap'), 1, 'schema version 1');
select tests.eq((select item_counts from public.archive_snapshots where id = :'snap'),
                '{"media": 1, "letters": 1, "members": 4, "comments": 1, "memories": 2, "milestones": 0}'::jsonb,
                'item counts (ready media only)');
select tests.eq((select (content -> 'lifecycle' ->> 'extension_days')::integer from public.archive_snapshots where id = :'snap'), 20,
                'extension recorded in the snapshot');
select tests.eq((select count(*) from public.archive_snapshots s, jsonb_array_elements(s.content -> 'memories') m
                  where s.id = :'snap' and m ->> 'title' = 'Uzatmada'), 1::bigint,
                'content written during the extension is included');
select tests.eq((select (m -> 'author' ->> 'name') || '/' || (m -> 'author' ->> 'relation')
                   from public.archive_snapshots s, jsonb_array_elements(s.content -> 'memories') m
                  where s.id = :'snap' and m ->> 'title' = 'Uzatmada'), 'Zeynep/teyze',
                'author name and relation are copied into the snapshot');
select tests.eq(position('GIZLI KAPSUL' in (select content::text from public.archive_snapshots where id = :'snap')), 0,
                'sealed time capsules never enter a snapshot');
select tests.expect_error(format('update public.archive_snapshots set content = %L where id = %L', '{}', :'snap'), 'immutable');
select tests.expect_error(format('delete from public.archive_snapshots where id = %L', :'snap'), 'immutable');
-- Live profile changes do not alter the sealed snapshot; a new one is taken only if the archive changes.
update public.profiles set display_name = 'Zeynep Yeni' where id = '9d000000-0000-4000-8000-000000000011';
select tests.eq((select m -> 'author' ->> 'name' from public.archive_snapshots s, jsonb_array_elements(s.content -> 'memories') m
                  where s.id = :'snap' and m ->> 'title' = 'Uzatmada'), 'Zeynep', 'sealed snapshot keeps the original name');
update public.profiles set display_name = 'Zeynep' where id = '9d000000-0000-4000-8000-000000000011';
select tests.eq(public.output_create_snapshot(:'defne', 'first_year_film'), :'snap'::uuid, 'an identical archive reuses the snapshot');

-- Worker: claim, heartbeat, retry with backoff ------------------------------------------------------------------
select tests.eq((select count(*) from public.output_claim_jobs('worker-a', array['first_year_film'])), 0::bigint,
                'workers only claim products they render');
update public.platform_flags set enabled = false where key = 'output_worker';
select tests.eq((select count(*) from public.output_claim_jobs('worker-a', array['first_year_book'])), 0::bigint,
                'kill switch stops consumption');
update public.platform_flags set enabled = true where key = 'output_worker';
select tests.eq((select status from public.output_jobs where id = :'book_job'), 'queued', 'queued job kept while stopped');
select tests.eq((select job_id from public.output_claim_jobs('worker-a', array['first_year_book'])), :'book_job'::uuid, 'worker claims the job');
select tests.eq((select count(*) from public.output_claim_jobs('worker-b', array['first_year_book'])), 0::bigint,
                'a leased job is not claimed twice');
select tests.eq(public.output_job_heartbeat(:'book_job', 'worker-a', 60), true, 'owner heartbeat extends the lease');
select tests.eq(public.output_job_heartbeat(:'book_job', 'worker-b', 60), false, 'foreign heartbeat is ignored');
select tests.eq(public.output_job_fail(:'book_job', 'worker-b', 'render_failed'), 'lease_lost', 'only the lease owner can fail a job');
select tests.eq(public.output_job_fail(:'book_job', 'worker-a', 'render_failed',
                  'boom at https://x.supabase.co/storage/v1/object/sign/a?token=abc123 Bearer eyJhbGci.x.y'), 'retry_scheduled',
                'failure schedules a retry');
select tests.eq((select position('abc123' in last_error) = 0 and position('eyJhbGci' in last_error) = 0 and position('https://' in last_error) = 0
                   from public.output_jobs where id = :'book_job'), true, 'URLs and tokens are never stored in errors');
select tests.eq((select available_at > now() + interval '25 seconds' from public.output_jobs where id = :'book_job'), true,
                'retry waits for the backoff');
select tests.eq((select count(*) from public.output_claim_jobs('worker-a', array['first_year_book'])), 0::bigint,
                'not claimable during backoff');
select tests.eq(public.output_retry_delay(1) < public.output_retry_delay(3) and public.output_retry_delay(20) = interval '1 hour', true,
                'exponential backoff capped at one hour');
update public.output_jobs set available_at = now() - interval '1 second' where id = :'book_job';
select tests.eq((select attempt from public.output_claim_jobs('worker-a', array['first_year_book'])), 2, 'second attempt');
-- A dead worker: the lease runs out and the job goes back to the queue.
update public.output_jobs set lease_expires_at = now() - interval '1 second' where id = :'book_job';
select tests.eq(public.output_job_heartbeat(:'book_job', 'worker-a', 60), false,
                'an expired lease cannot be revived by heartbeat');
select tests.eq(public.output_job_fail(:'book_job', 'worker-a', 'render_failed'), 'lease_lost',
                'an expired worker cannot change the job result');
select tests.eq(public.output_expire_leases(), 1, 'expired lease is reclaimed');
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'book_job'), 'queued:lease_expired',
                'reclaimed job is queued again');
select tests.eq((select string_agg(outcome, ',' order by attempt) from public.output_job_attempts where job_id = :'book_job'),
                'failed,lease_expired', 'every attempt is recorded');
update public.output_jobs set available_at = now() - interval '1 second' where id = :'book_job';
select tests.eq((select attempt from public.output_claim_jobs('worker-a', array['first_year_book'])), 3, 'third attempt');

-- Artifact: staging -> checksum verify -> DB record -> ready --------------------------------------------------------
select tests.expect_error(format($q$select * from public.output_artifact_begin(%L, 'worker-a', 'book.pdf', 'video/mp4', %L, 10)$q$,
                                 :'book_job', repeat('a', 64)), 'wrong file type');
select tests.expect_error(format($q$select * from public.output_artifact_begin(%L, 'worker-a', '../x.pdf', 'application/pdf', %L, 10)$q$,
                                 :'book_job', repeat('a', 64)), 'invalid file name');
select artifact_id as bad_art, staging_path as bad_staging
  from public.output_artifact_begin(:'book_job', 'worker-a', 'book.pdf', 'application/pdf', repeat('a', 64), 1000) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'bad_staging', '{"size": 1000}');
update public.output_jobs set lease_expires_at = now() - interval '1 second' where id = :'book_job';
select tests.eq(public.output_artifact_verify(:'bad_art', 'worker-a', repeat('a', 64)), 'lease_lost',
                'an expired worker cannot verify an artifact');
update public.output_jobs set lease_expires_at = now() + interval '1 minute' where id = :'book_job';
select tests.eq(public.output_artifact_verify(:'bad_art', 'worker-a', repeat('b', 64)), 'quarantined',
                'checksum mismatch quarantines the artifact');
select tests.eq((select status || ':' || failure_code from public.output_artifacts where id = :'bad_art'), 'quarantined:checksum_mismatch',
                'mismatch recorded');
select tests.expect_error(format($q$update public.output_artifacts set status = 'ready', ready_at = now() where id = %L$q$, :'bad_art'),
                          'invalid artifact transition');
select tests.expect_error(format($q$update public.output_artifacts set verified_sha256 = %L, verified_at = now(), status = 'verified' where id = %L$q$,
                                 repeat('b', 64), :'bad_art'), 'invalid artifact transition');
select tests.eq((select status from public.output_jobs where id = :'book_job'), 'queued', 'job retries after a quarantined artifact');

update public.output_jobs set available_at = now() - interval '1 second' where id = :'book_job';
select tests.eq((select attempt from public.output_claim_jobs('worker-a', array['first_year_book'])), 4, 'fourth attempt');
select artifact_id as art, staging_path as art_staging, storage_path as art_path, version as art_version
  from public.output_artifact_begin(:'book_job', 'worker-a', 'book.pdf', 'application/pdf', repeat('c', 64), 2048) \gset
select tests.eq(:'art_path'::text, format('%s/first_year_book/%s/v2/book.pdf', :'defne', :'snap'),
                'artifact path is namespaced baby/product/snapshot/version');
select tests.eq(public.output_artifact_verify(:'art', 'worker-a', repeat('c', 64)), 'quarantined', 'missing staged object is never verified');
update public.output_jobs set available_at = now() - interval '1 second' where id = :'book_job';
select tests.eq((select attempt from public.output_claim_jobs('worker-a', array['first_year_book'])), 5, 'fifth attempt');
select artifact_id as art, staging_path as art_staging, storage_path as art_path
  from public.output_artifact_begin(:'book_job', 'worker-a', 'book.pdf', 'application/pdf', repeat('c', 64), 2048) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art_staging', '{"size": 2048}');
select tests.eq(public.output_artifact_verify(:'art', 'worker-a', repeat('c', 64)), 'verified', 'matching checksum verifies');
update public.output_jobs set lease_expires_at = now() - interval '1 second' where id = :'book_job';
select tests.eq(public.output_artifact_publish(:'art', 'worker-a'), 'lease_lost',
                'an expired worker cannot publish an artifact');
update public.output_jobs set lease_expires_at = now() + interval '1 minute' where id = :'book_job';
select tests.eq(public.output_artifact_publish(:'art', 'worker-a'), 'quarantined', 'publish needs the object at its final path');
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'book_job'), 'poison:object_missing',
                'max attempts reached: job is poisoned');
select tests.expect_error(format($q$update public.output_jobs set status = 'queued', finished_at = null where id = %L$q$, :'book_job'),
                          'immutable');
select tests.expect_error(format('delete from public.output_jobs where id = %L', :'book_job'), 'permanent');
update storage.objects set name = :'art_path' where bucket_id = 'output-artifacts' and name = :'art_staging';

-- A fresh request after poison creates a new job for the same snapshot, which succeeds.
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select job_id as book_job2, reused as second_reused from public.request_output_job(:'defne', 'first_year_book', 'book-key-0003') \gset
reset role;
select tests.logout();
select tests.eq(:'second_reused'::boolean, false, 'poisoned job does not block a new request');
select tests.eq((select job_id from public.output_claim_jobs('worker-a', array['first_year_book'])), :'book_job2'::uuid, 'new job claimed');
select artifact_id as art2, staging_path as art2_staging, storage_path as art2_path
  from public.output_artifact_begin(:'book_job2', 'worker-a', 'book.pdf', 'application/pdf', repeat('d', 64), 4096) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art2_staging', '{"size": 4096}');
select tests.eq(public.output_artifact_verify(:'art2', 'worker-a', repeat('d', 64)), 'verified', 'verified');
update storage.objects set name = :'art2_path' where bucket_id = 'output-artifacts' and name = :'art2_staging';
select tests.eq(public.output_artifact_publish(:'art2', 'worker-a'), 'ready', 'artifact ready');
select tests.eq((select status from public.output_jobs where id = :'book_job2'), 'succeeded', 'job succeeded');
select tests.expect_error(format('delete from public.output_artifacts where id = %L', :'art2'), 'permanent');
select tests.expect_error(format($q$update public.output_artifacts set storage_path = 'x' where id = %L$q$, :'art2'), 'immutable');

-- A queued request is re-checked at claim time. Closing the subscription
-- keeps the snapshot but cancels work that should no longer consume capacity.
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select job_id as unsub_job from public.request_output_job(:'defne', 'first_year_film', 'film-unsub-0001') \gset
reset role;
select tests.logout();
update public.subscriptions set status = 'expired' where provider_subscription_id = 'output-sub';
select tests.expect_error(format('select public.output_create_snapshot(%L, %L)', :'defne', 'first_year_film'),
                          'subscription_required');
select tests.eq((select count(*) from public.output_claim_jobs('worker-a', array['first_year_film'])), 0::bigint,
                'a worker never claims a job after the subscription closes');
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'unsub_job'),
                'canceled:subscription_inactive', 'the queued job is canceled with an explicit reason');
update public.subscriptions set status = 'active' where provider_subscription_id = 'output-sub';

-- Ece's book, to prove isolation between siblings.
select public.output_create_snapshot(:'ece', 'first_year_book') as ece_snap \gset
insert into public.output_projects (id, family_account_id, baby_id, product_code)
values ('9d500000-0000-4000-8000-000000000001', :'acct', :'ece', 'first_year_book');
insert into public.output_jobs (id, project_id, snapshot_id, family_account_id, baby_id, product_code, idempotency_key)
values ('9d600000-0000-4000-8000-000000000001', '9d500000-0000-4000-8000-000000000001', :'ece_snap', :'acct', :'ece',
        'first_year_book', 'ece-book-0001');
select tests.eq((select job_id from public.output_claim_jobs('worker-a', array['first_year_book'])),
                '9d600000-0000-4000-8000-000000000001'::uuid, 'Ece job claimed');
select artifact_id as ece_art, staging_path as ece_staging, storage_path as ece_path
  from public.output_artifact_begin('9d600000-0000-4000-8000-000000000001', 'worker-a', 'book.pdf', 'application/pdf',
                                    repeat('e', 64), 100) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'ece_path', '{"size": 100}');
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'ece_staging', '{"size": 100}');
select tests.eq(public.output_artifact_verify(:'ece_art', 'worker-a', repeat('e', 64)), 'verified', 'Ece verified');
delete from storage.objects where bucket_id = 'output-artifacts' and name = :'ece_staging';
select tests.eq(public.output_artifact_publish(:'ece_art', 'worker-a'), 'ready', 'Ece artifact ready');
-- A file dropped under Defne's folder without an artifact row.
insert into storage.objects (bucket_id, name, metadata)
values ('output-artifacts', format('%s/first_year_book/%s/v9/book.pdf', :'defne', :'ece_snap'), '{"size": 100}');

-- Downloads ---------------------------------------------------------------------------------------------------------
-- Phase 12: a Family Member downloads only what a parent shared with them.
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select public.set_artifact_download_permission(:'defne', '9d000000-0000-4000-8000-000000000011', 'first_year_book', true);
select tests.login('9d000000-0000-4000-8000-000000000011');
select tests.eq((select storage_path || ':' || expires_in from public.request_output_download(:'art2')), :'art2_path' || ':60',
                'family member the parent shared the book with gets a short-lived download');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts'), 0::bigint,
                'authenticated clients cannot list the artifact bucket directly');
select tests.expect_error(format('select public.can_read_output_object(%L)', :'art2_path'), 'permission denied');
select tests.eq((select download_block from public.baby_output_status(:'defne') where product_code = 'first_year_book'), null::text,
                'status shows the download as available');
select tests.login('9d000000-0000-4000-8000-000000000012');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'art2'), 'permission_denied');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts'), 0::bigint, 'not shared, no file');
select tests.login('9d000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'art2'), 'not found');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts'), 0::bigint, 'outsider sees no file');
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts'), 0::bigint,
                'parents also download only through the fixed-lifetime endpoint');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts' and name like 'staging/%'), 0::bigint,
                'staging objects are never readable');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'bad_art'), 'artifact_not_ready');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('output-artifacts', 'x/y.pdf')$q$, 'row-level security');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.output_artifact_downloads where artifact_id = :'art2'), 1::bigint, 'the grant is logged');
select tests.eq((select count(*) from information_schema.columns
                  where table_schema = 'public' and table_name = 'output_artifact_downloads'
                    and column_name ~ 'url|token|signature'), 0::bigint, 'download log has no URL or token column');
select tests.expect_error($q$delete from public.output_artifact_downloads$q$, 'append-only');

-- Subscription ends: artifact kept, download refused. Entitlement revoked: same.
update public.subscriptions set status = 'expired' where provider_subscription_id = 'output-sub';
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'art2'), 'subscription_required');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts'), 0::bigint, 'no file without a subscription');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'defne', 'first_year_film', 'film-key-0001'),
                          'subscription_required');
reset role;
select tests.logout();
select tests.eq((select status from public.output_artifacts where id = :'art2'), 'ready', 'artifact is preserved');
update public.subscriptions set status = 'active' where provider_subscription_id = 'output-sub';
update public.product_entitlements set status = 'revoked', revoked_at = now(), revoke_reason = 'refunded'
 where source_order_id = '9d400000-0000-4000-8000-000000000001';
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'art2'), 'entitlement_required');
select tests.eq((select count(*) from storage.objects where bucket_id = 'output-artifacts' and name = :'art2_path'), 0::bigint,
                'refunded product: file unreadable');
reset role;
select tests.logout();

-- A queued job whose entitlement is revoked is canceled, not rendered.
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select job_id as film_job from public.request_output_job(:'defne', 'first_year_film', 'film-key-0002') \gset
reset role;
select tests.logout();
update public.product_entitlements set status = 'revoked', revoked_at = now(), revoke_reason = 'refunded'
 where source_order_id = '9d400000-0000-4000-8000-000000000002';
select tests.eq((select count(*) from public.output_claim_jobs('worker-a', array['first_year_film'])), 0::bigint, 'revoked product not rendered');
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'film_job'), 'canceled:entitlement_revoked',
                'job canceled');

-- Maintenance: stale staging, quarantine retention, orphans --------------------------------------------------------
insert into storage.objects (bucket_id, name, metadata, created_at)
values ('output-artifacts', 'staging/9d700000-0000-4000-8000-000000000001/lost.pdf', '{"size": 5}', now() - interval '3 hours');
update storage.objects set created_at = now() - interval '3 hours'
 where bucket_id = 'output-artifacts' and name = format('%s/first_year_book/%s/v9/book.pdf', :'defne', :'ece_snap');
select public.output_pipeline_maintenance(interval '2 hours', interval '0 seconds') as maint \gset
select tests.eq((:'maint'::jsonb ->> 'orphan_objects')::integer, 2, 'old files without a live artifact row are queued as orphans');
select tests.eq((:'maint'::jsonb ->> 'purged_quarantine')::integer, 3, 'quarantined artifacts are purged after retention');
select tests.eq((select count(*) from public.storage_cleanup_queue where bucket_id = 'output-artifacts' and path = :'bad_staging'), 1::bigint,
                'purged quarantine file queued for cleanup');
select tests.eq((select count(*) from public.storage_cleanup_queue
                  where bucket_id = 'output-artifacts' and path = format('%s/first_year_book/%s/v9/book.pdf', :'defne', :'ece_snap')), 1::bigint,
                'unregistered file under Defne queued');
select tests.eq((select count(*) from public.storage_cleanup_queue where bucket_id = 'output-artifacts' and path in (:'art2_path', :'ece_path')),
                0::bigint, 'ready artifacts are never cleaned up');
select tests.eq((select count(*) from public.output_artifacts where status = 'quarantined' and purged_at is null and baby_id = :'defne'), 0::bigint,
                'quarantine retention purges old quarantined artifacts');
select tests.eq((select count(*) from public.output_maintenance_runs), 1::bigint, 'maintenance run recorded');

-- Observability ---------------------------------------------------------------------------------------------------------
select tests.eq((public.output_pipeline_metrics() -> 'first_year_book' -> 'jobs' ->> 'succeeded')::integer, 2, 'succeeded jobs counted');
select tests.eq((public.output_pipeline_metrics() -> 'first_year_book' ->> 'retries')::integer, 4, 'retries counted');
select tests.eq((public.output_pipeline_metrics() -> 'first_year_book' -> 'failure_codes' ->> 'checksum_mismatch')::integer, 1,
                'failure codes counted');
select tests.eq((public.output_pipeline_metrics() -> 'first_year_book' ->> 'artifact_bytes_max')::integer, 4096, 'artifact size tracked');
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.expect_error($q$select public.admin_output_metrics()$q$, 'not authorized');
reset role;
select tests.logout();

-- Nothing here touches the lifecycle.
set role authenticated;
select tests.login('9d000000-0000-4000-8000-000000000001');
select tests.eq((select status from public.baby_lifecycle_summary(:'defne')), :'life_before', 'lifecycle unchanged');
select tests.eq((select effective_close_date from public.baby_lifecycle_summary(:'defne')), :'close_before'::date, 'close date unchanged');
reset role;
select tests.logout();
