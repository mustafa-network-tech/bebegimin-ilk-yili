-- Phase 10: first-year film (at most 600 s), duration budget and film worker API.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into auth.users (id, email) values
  ('9f000000-0000-4000-8000-000000000001', 'film-anne@example.com'),
  ('9f000000-0000-4000-8000-000000000002', 'film-baba@example.com'),
  ('9f000000-0000-4000-8000-000000000011', 'film-teyze@example.com'),
  ('9f000000-0000-4000-8000-000000000021', 'film-yabanci@example.com');

set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select (public.create_baby('Nil', public.business_date_istanbul() - 400, 'anne')).id as nil \gset
select (public.create_baby('Açık', public.business_date_istanbul() - 30, 'anne')).id as active_baby \gset
select public.family_account_id_for_baby(:'nil') as acct \gset
reset role;
select tests.logout();
select (birth_date)::text as birth from public.babies where id = :'nil' \gset

insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'nil', 'FLBABA2222', 'baba', true, '{}', '9f000000-0000-4000-8000-000000000001'),
  (:'nil', 'FLTEYZE222', 'teyze', false, '{view_memories,view_album}', '9f000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000002');
select public.accept_invitation('FLBABA2222');
select tests.login('9f000000-0000-4000-8000-000000000011');
select public.accept_invitation('FLTEYZE222');
reset role;
select tests.logout();

-- Nil's archive: one memory + its photo (month 1), one video (month 2), one
-- milestone (month 4) and one family letter.
insert into public.memories (id, baby_id, author_id, title, body, memory_date) values
  ('9f100000-0000-4000-8000-000000000001', :'nil', '9f000000-0000-4000-8000-000000000001', 'İlk banyo', 'Çok güldük', :'birth'::date + 10);
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status, memory_id, width, height) values
  ('9f200000-0000-4000-8000-000000000001', :'nil', '9f000000-0000-4000-8000-000000000001', 'photo',
   :'nil' || '/9f200000-0000-4000-8000-000000000001/p.jpg', 'image/jpeg', :'birth'::date + 10, 'ready',
   '9f100000-0000-4000-8000-000000000001', 3024, 4032);
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status, duration_ms) values
  ('9f200000-0000-4000-8000-000000000002', :'nil', '9f000000-0000-4000-8000-000000000001', 'video',
   :'nil' || '/9f200000-0000-4000-8000-000000000002/v.mp4', 'video/mp4', :'birth'::date + 40, 'ready', 12000);
insert into public.milestones (baby_id, milestone_type_id, achieved_on, description, created_by)
select :'nil', t.id, :'birth'::date + 100, 'Emekledi', '9f000000-0000-4000-8000-000000000001'
  from public.milestone_types t where t.key = 'first_smile';
insert into public.letters (baby_id, author_id, author_name, author_relation, body, written_on)
values (:'nil', '9f000000-0000-4000-8000-000000000011', 'Zeynep', 'teyze', 'Canım Nil', :'birth'::date + 200);

-- Gate ---------------------------------------------------------------------------------------------------
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select access_block from public.film_access_state(:'active_baby')), 'premium_requires_locked', 'ACTIVE baby: no film');
select tests.expect_error(format('select * from public.film_plan(%L)', :'active_baby'), 'premium_requires_locked');
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'active_baby', 'film-active-01'), 'premium_requires_locked');
select tests.eq((select access_block from public.film_access_state(:'nil')), 'subscription_required', 'LOCKED without subscription');
reset role;
select tests.logout();
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'film-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'normal_family' and p.billing_period = 'monthly';
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select access_block from public.film_access_state(:'nil')), 'entitlement_required', 'LOCKED + subscription, no film');
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'nil', 'film-noent-01'), 'entitlement_required');
reset role;
select tests.logout();
insert into public.premium_orders (id, family_account_id, baby_id, product_id, product_code, price_minor, currency, provider, status, paid_at)
select '9f400000-0000-4000-8000-000000000001', :'acct', :'nil', p.id, p.code, p.price_minor, p.currency, 'mock', 'paid', now()
  from public.current_premium_products() p where p.code = 'first_year_film';
insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
values (:'acct', :'nil', 'first_year_film', '9f400000-0000-4000-8000-000000000001');

set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000011');
select tests.eq((select access_block from public.film_access_state(:'nil')), 'not_parent', 'family member cannot produce the film');
select tests.expect_error(format('select * from public.film_plan(%L)', :'nil'), 'not_parent');
select tests.expect_error(format($q$select public.film_update_settings(%L, '{}')$q$, :'nil'), 'not_parent');
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'nil', 'film-teyze-01'), 'not_parent');
select tests.login('9f000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.film_access_state(%L)', :'nil'), 'not found');

-- Settings ----------------------------------------------------------------------------------------------------
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select access_block is null and renderer_enabled from public.film_access_state(:'nil')), true, 'entitled parent may produce the film');
select tests.expect_error(format($q$select public.film_update_settings(%L, '{"music": true}')$q$, :'nil'), 'invalid film settings');
select tests.expect_error(format($q$select public.film_update_settings(%L, '{"include_videos": "yes"}')$q$, :'nil'), 'invalid film settings');
select tests.expect_error(format($q$select public.film_update_settings(%L, '{"excluded_ids": ["x"]}')$q$, :'nil'), 'invalid film settings');
select tests.expect_error(format($q$select public.film_update_settings(%L, %L)$q$, :'nil', json_build_object('title', repeat('a', 81))), 'invalid film settings');
select tests.eq(public.film_settings(:'nil') ->> 'include_videos', 'true', 'defaults include every kind');

-- Duration budget: proportional to content, never padded ---------------------------------------------------------
select tests.eq((select total_duration_ms || ':' || over_limit || ':' || photos || '/' || videos || '/' || memories || '/' || milestones
                        || '/' || letters || '/' || chapters from public.film_plan(:'nil')),
                '42500:false:1/1/1/1/1/4',
                'small archive: 4 s title + 4 chapter cards + 5 scenes + 4 s end = 42.5 s, no padding to 600 s');
select public.film_update_settings(:'nil', '{"include_videos": false}');
select tests.eq((select total_duration_ms from public.film_plan(:'nil')), 32000::bigint, 'videos off: the video and its empty chapter go');
select public.film_update_settings(:'nil', '{"include_videos": true, "title": "Nil''in ilk yılı"}');

-- Render request: preflight, frozen manifest, idempotency ------------------------------------------------------------
select job_id as job1, total_duration_ms as job1_total, reused as job1_reused from public.film_request_render(:'nil', 'film-req-0001') \gset
select tests.eq(:job1_total, 42500, 'manifest total equals the plan');
select tests.eq(:'job1_reused'::boolean, false, 'first request creates a job');
select tests.eq((select job_id from public.film_request_render(:'nil', 'film-req-0001')), :'job1'::uuid, 'same key returns the job');
select tests.eq((select job_id || ':' || reused from public.film_request_render(:'nil', 'film-req-0002')), :'job1' || ':true',
                'identical snapshot + settings join the waiting job');
select public.film_update_settings(:'nil', '{"include_letters": false, "title": "Nil''in ilk yılı"}');
select job_id as job2 from public.film_request_render(:'nil', 'film-req-0003') \gset
select public.film_update_settings(:'nil', '{"title": "Nil''in ilk yılı"}');
select job_id as job3 from public.film_request_render(:'nil', 'film-req-0004') \gset
select tests.eq((select job_status from public.film_state(:'nil')), 'queued', 'state shows the queued job');
reset role;
select tests.logout();
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'job1'), 'canceled:superseded',
                'a waiting job with older settings is superseded');
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'job2'), 'canceled:superseded',
                'every superseded job is closed');
select tests.expect_error(format($q$update public.film_render_manifests set content = '{}' where job_id = %L$q$, :'job3'), 'immutable');
select tests.eq((select content ->> 'snapshot_id' = snapshot_id::text and content -> 'scenes' -> 0 ->> 'title' = 'Nil''in ilk yılı'
                   from public.film_render_manifests where job_id = :'job3'), true, 'manifest names its snapshot and the custom title');

-- Worker: claim, manifest, progress ---------------------------------------------------------------------------------
select tests.eq((select job_id from public.output_claim_jobs('film-worker-1', array['first_year_film'])), :'job3'::uuid, 'film worker claims the job');
select tests.expect_error(format($q$select * from public.film_job_manifest(%L, 'film-worker-2')$q$, :'job3'), 'lease_lost');
select manifest_content, manifest_checksum from public.film_job_manifest(:'job3', 'film-worker-1') \gset
select tests.eq(encode(sha256(convert_to(:'manifest_content', 'UTF8')), 'hex'), :'manifest_checksum'::text, 'manifest text hashes to its checksum');
select tests.eq((select string_agg(e ->> 'kind', ',' order by (e ->> 'index')::int) from jsonb_array_elements(:'manifest_content'::jsonb -> 'scenes') e),
                'title,chapter,memory,photo,chapter,video,chapter,milestone,chapter,letter,end', 'scene order: title, chapters in time order, letters, end');
select tests.eq((select string_agg(e ->> 'title', ',' order by (e ->> 'index')::int) from jsonb_array_elements(:'manifest_content'::jsonb -> 'scenes') e
                  where e ->> 'kind' = 'chapter'), '1. Ay,2. Ay,4. Ay,Ailemden sana', 'chapter titles');
select tests.eq((select (e ->> 'duration_ms')::int from jsonb_array_elements(:'manifest_content'::jsonb -> 'scenes') e where e ->> 'kind' = 'video'),
                8000, 'a 12 s video contributes an 8 s clip');
select tests.eq(public.film_job_progress_update(:'job3', 'film-worker-2', 50, 'encoding'), false, 'foreign worker cannot report progress');
select tests.eq(public.film_job_progress_update(:'job3', 'film-worker-1', 40, 'encoding'), true, 'owner reports progress');

-- Post-render validation: never above 600 s ---------------------------------------------------------------------------
select artifact_id as bad_art, staging_path as bad_staging, storage_path as bad_path
  from public.output_artifact_begin(:'job3', 'film-worker-1', 'ilk-yil-filmi.mp4', 'video/mp4', repeat('a', 64), 5000) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'bad_staging', '{"size": 5000}');
select tests.eq(public.output_artifact_verify(:'bad_art', 'film-worker-1', repeat('a', 64)), 'verified', 'worker hash verified');
update storage.objects set name = :'bad_path' where bucket_id = 'output-artifacts' and name = :'bad_staging';
select tests.eq(public.film_artifact_publish(:'bad_art', 'film-worker-1', 600001, 1920, 1080, 30, 'h264', 'aac'), 'duration_exceeded',
                'a probe above 600 s is never published');
select tests.eq((select status || ':' || last_error_code from public.output_jobs where id = :'job3'), 'poison:duration_exceeded',
                'duration overflow is not retried');
select tests.eq((select status from public.output_artifacts where id = :'bad_art'), 'quarantined', 'overlong file is quarantined');

-- Deterministic retry and media errors ---------------------------------------------------------------------------------
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select job_id as job4 from public.film_request_render(:'nil', 'film-req-0005') \gset
reset role;
select tests.logout();
select tests.eq((select m4.checksum = m3.checksum from public.film_render_manifests m3, public.film_render_manifests m4
                  where m3.job_id = :'job3' and m4.job_id = :'job4'), true, 'retry renders the identical manifest');
select tests.eq((select job_id from public.output_claim_jobs('film-worker-1', array['first_year_film'])), :'job4'::uuid, 'retry job claimed');
select tests.expect_error(format($q$select public.film_job_media_error(%L, 'film-worker-1', 'boom', null)$q$, :'job4'), 'invalid error code');
select tests.eq(public.film_job_media_error(:'job4', 'film-worker-1', 'media_corrupt', '9f200000-0000-4000-8000-000000000002'), 'poison',
                'a corrupt video ends the job without retries');
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select job_status || ':' || last_error_code || ':' || failed_media_id from public.film_state(:'nil')),
                'poison:media_corrupt:9f200000-0000-4000-8000-000000000002', 'the app learns which media to exclude');
select public.film_update_settings(:'nil', '{"title": "Nil''in ilk yılı", "excluded_ids": ["9F200000-0000-4000-8000-000000000002"]}');
select tests.eq(public.film_settings(:'nil') -> 'excluded_ids' ->> 0, '9f200000-0000-4000-8000-000000000002', 'excluded ids are normalised');
select job_id as job5, total_duration_ms as job5_total from public.film_request_render(:'nil', 'film-req-0006') \gset
select tests.eq(:job5_total, 32000, 'excluding the broken video shortens the film');
reset role;
select tests.logout();

-- Successful render ------------------------------------------------------------------------------------------------------
select tests.eq((select job_id from public.output_claim_jobs('film-worker-1', array['first_year_film'])), :'job5'::uuid, 'new job claimed');
select artifact_id as art, staging_path as art_staging, storage_path as art_path
  from public.output_artifact_begin(:'job5', 'film-worker-1', 'ilk-yil-filmi.mp4', 'video/mp4', repeat('b', 64), 8000) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art_staging', '{"size": 8000}');
select tests.eq(public.output_artifact_verify(:'art', 'film-worker-1', repeat('b', 64)), 'verified', 'film upload verified');
update storage.objects set name = :'art_path' where bucket_id = 'output-artifacts' and name = :'art_staging';
select tests.eq(public.film_artifact_publish(:'art', 'film-worker-1', 32000, 1280, 720, 30, 'h264', 'aac'), 'profile_mismatch',
                'output profile is enforced');
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select job_id as job6 from public.film_request_render(:'nil', 'film-req-0007') \gset
reset role;
select tests.logout();
select tests.eq((select job_id from public.output_claim_jobs('film-worker-1', array['first_year_film'])), :'job6'::uuid, 'job claimed again');
select artifact_id as art, staging_path as art_staging, storage_path as art_path
  from public.output_artifact_begin(:'job6', 'film-worker-1', 'ilk-yil-filmi.mp4', 'video/mp4', repeat('c', 64), 8000) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art_staging', '{"size": 8000}');
select tests.eq(public.output_artifact_verify(:'art', 'film-worker-1', repeat('c', 64)), 'verified', 'film upload verified');
update storage.objects set name = :'art_path' where bucket_id = 'output-artifacts' and name = :'art_staging';
select tests.eq(public.film_artifact_publish(:'art', 'film-worker-1', 36000, 1920, 1080, 30, 'h264', 'aac'), 'duration_mismatch',
                'a probe far from the manifest is rejected');
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select job_id as job7 from public.film_request_render(:'nil', 'film-req-0008') \gset
reset role;
select tests.logout();
select tests.eq((select job_id from public.output_claim_jobs('film-worker-1', array['first_year_film'])), :'job7'::uuid, 'job claimed');
select artifact_id as art, staging_path as art_staging, storage_path as art_path
  from public.output_artifact_begin(:'job7', 'film-worker-1', 'ilk-yil-filmi.mp4', 'video/mp4', repeat('d', 64), 8000) \gset
insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', :'art_staging', '{"size": 8000}');
select tests.eq(public.output_artifact_verify(:'art', 'film-worker-1', repeat('d', 64)), 'verified', 'film upload verified');
update storage.objects set name = :'art_path' where bucket_id = 'output-artifacts' and name = :'art_staging';
select tests.eq(public.film_artifact_publish(:'art', 'film-worker-1', 32040, 1920, 1080, 29.97, 'h264', 'aac'), 'ready',
                'valid film is published');
select tests.eq((select duration_ms || ':' || width || 'x' || height || ':' || video_codec || '/' || audio_codec
                   from public.film_artifact_metadata where artifact_id = :'art'), '32040:1920x1080:h264/aac', 'probe metadata stored');
select tests.expect_error(format($q$update public.film_artifact_metadata set duration_ms = 1 where artifact_id = %L$q$, :'art'), 'append-only');
select tests.eq(:'art_path'::text like :'nil' || '/first_year_film/%/v%/ilk-yil-filmi.mp4', true, 'film path names the snapshot and version');

set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select job_status || ':' || progress_percent || ':' || duration_ms || ':' || coalesce(download_block, 'ok')
                   from public.film_state(:'nil')), 'succeeded:100:32040:ok', 'state shows the ready film');
select tests.eq((select storage_path from public.request_output_download(:'art')), :'art_path'::text, 'parent downloads the MP4');
select tests.login('9f000000-0000-4000-8000-000000000011');
select tests.eq((select coalesce(download_block, 'ok') from public.film_state(:'nil')), 'ok', 'family member with album access may download');
select tests.login('9f000000-0000-4000-8000-000000000021');
select tests.expect_error(format('select * from public.film_state(%L)', :'nil'), 'not found');
reset role;
select tests.logout();

-- Kill switch and empty films -------------------------------------------------------------------------------------------
update public.platform_flags set enabled = false where key = 'film_renderer';
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select renderer_enabled from public.film_access_state(:'nil')), false, 'state shows the paused renderer');
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'nil', 'film-paused-01'), 'film_renderer_disabled');
reset role;
select tests.logout();
update public.platform_flags set enabled = true where key = 'film_renderer';
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select public.film_update_settings(:'nil', json_build_object(
  'include_videos', false, 'include_milestones', false, 'include_memory_texts', false, 'include_letters', false,
  'excluded_ids', json_build_array('9f200000-0000-4000-8000-000000000001'))::jsonb);
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'nil', 'film-empty-01'), 'film_empty');
select public.film_update_settings(:'nil', '{}');
reset role;
select tests.logout();

-- Large archives: compression, refusal (never truncation), suggestion --------------------------------------------------------
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status)
select g.id, :'nil', '9f000000-0000-4000-8000-000000000001', 'photo', :'nil' || '/' || g.id || '/p.jpg', 'image/jpeg',
       :'birth'::date + 1 + (g.n % 360), 'ready'
  from (select n, gen_random_uuid() as id from generate_series(1, 200) n) g;
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select base_duration_ms > 600000 and not over_limit and total_duration_ms between 595000 and 600000
                   from public.film_plan(:'nil')), true, 'too long at base durations: scenes are shortened to fit 600 s');
reset role;
select tests.logout();
insert into public.media (id, baby_id, uploader_id, kind, storage_path, mime_type, taken_on, status)
select g.id, :'nil', '9f000000-0000-4000-8000-000000000001', 'photo', :'nil' || '/' || g.id || '/p.jpg', 'image/jpeg',
       :'birth'::date + 1 + (g.n % 360), 'ready'
  from (select n, gen_random_uuid() as id from generate_series(1, 130) n) g;
set role authenticated;
select tests.login('9f000000-0000-4000-8000-000000000001');
select tests.eq((select over_limit and excess_ms > 0 and min_duration_ms > 600000 from public.film_plan(:'nil')), true,
                'even minimum durations exceed 600 s: plan reports the excess');
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'nil', 'film-long-0001'), 'film_too_long');
select public.film_update_settings(:'nil', public.film_suggest_settings(:'nil'));
select tests.eq((select not over_limit and total_duration_ms <= 600000 and photos < 331 and photos > 100 from public.film_plan(:'nil')), true,
                'the suggested selection fits and keeps most photos');
select tests.eq((select total_duration_ms <= 600000 from public.film_request_render(:'nil', 'film-long-0002')), true,
                'the edited selection renders');
reset role;
select tests.logout();
