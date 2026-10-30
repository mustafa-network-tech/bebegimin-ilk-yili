-- Phase 12: parent-controlled Family Member downloads, one re-download policy
-- for Book / Film / HTML, audit and rate limits.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

-- A ready artifact of any product through the Phase 8 pipeline (the job is
-- leased directly so leftover queued jobs of other suites are not touched).
create or replace function tests.ready_artifact(p_baby uuid, p_product text, p_parent uuid, p_key text, p_file text)
returns uuid
language plpgsql
as $$
declare
  v_job uuid;
  v_art uuid;
  v_staging text;
  v_path text;
begin
  perform tests.login(p_parent);
  select r.job_id into v_job from public.request_output_job(p_baby, p_product, p_key) r;
  perform tests.logout();
  update public.output_jobs
     set status = 'running', attempts = attempts + 1, lease_owner = 'dl-worker',
         lease_expires_at = now() + interval '5 minutes', started_at = now(), heartbeat_at = now()
   where id = v_job;
  insert into public.output_job_attempts (job_id, attempt, worker) values (v_job, 1, 'dl-worker');
  select b.artifact_id, b.staging_path, b.storage_path into v_art, v_staging, v_path
    from public.output_artifact_begin(v_job, 'dl-worker', p_file, public.output_product_mime(p_product), repeat('a', 64), 100) b;
  insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', v_path, '{"size": 100}');
  insert into storage.objects (bucket_id, name, metadata) values ('output-artifacts', v_staging, '{"size": 100}');
  perform public.output_artifact_verify(v_art, 'dl-worker', repeat('a', 64));
  if public.output_artifact_publish(v_art, 'dl-worker') <> 'ready' then
    raise exception 'artifact fixture not ready';
  end if;
  return v_art;
end;
$$;

insert into auth.users (id, email) values
  ('a1000000-0000-4000-8000-000000000001', 'dl-anne@example.com'),
  ('a1000000-0000-4000-8000-000000000002', 'dl-baba@example.com'),
  ('a1000000-0000-4000-8000-000000000011', 'dl-teyze@example.com'),
  ('a1000000-0000-4000-8000-000000000012', 'dl-hala@example.com'),
  ('a1000000-0000-4000-8000-000000000013', 'dl-amca@example.com'),
  ('a1000000-0000-4000-8000-000000000014', 'dl-dayi@example.com'),
  ('a1000000-0000-4000-8000-000000000021', 'dl-baska-anne@example.com'),
  ('a1000000-0000-4000-8000-000000000031', 'dl-admin@example.com');
insert into public.platform_user_roles (user_id, role) values ('a1000000-0000-4000-8000-000000000031', 'super_admin');

set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000001');
select (public.create_baby('Ela', public.business_date_istanbul() - 400, 'anne')).id as ela \gset
select (public.create_baby('Mert', public.business_date_istanbul() - 395, 'anne')).id as mert \gset
select public.family_account_id_for_baby(:'ela') as acct \gset
select tests.login('a1000000-0000-4000-8000-000000000021');
select (public.create_baby('Uzak', public.business_date_istanbul() - 400, 'anne')).id as other_baby \gset
reset role;
select tests.logout();

insert into public.family_invitations (baby_id, code, relation, is_admin, permissions, created_by) values
  (:'ela', 'DLBABA2222', 'baba', true, '{}', 'a1000000-0000-4000-8000-000000000001'),
  (:'ela', 'DLTEYZE222', 'teyze', false, '{view_memories,view_album}', 'a1000000-0000-4000-8000-000000000001'),
  (:'ela', 'DLHALA2222', 'hala', false, '{view_memories,view_album}', 'a1000000-0000-4000-8000-000000000001'),
  (:'ela', 'DLAMCA2222', 'amca', false, '{view_memories}', 'a1000000-0000-4000-8000-000000000001'),
  (:'ela', 'DLDAYS2222', 'dayi', false, '{view_memories}', 'a1000000-0000-4000-8000-000000000001');
insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider, provider_subscription_id,
                                  current_period_end)
select :'acct', p.id, p.code, p.billing_period, 'active', 'mock', 'dl-sub', now() + interval '1 month'
  from public.subscription_plans p where p.code = 'normal_family' and p.billing_period = 'monthly';
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000002');
select public.accept_invitation('DLBABA2222');
select tests.login('a1000000-0000-4000-8000-000000000011');
select public.accept_invitation('DLTEYZE222');
select tests.login('a1000000-0000-4000-8000-000000000012');
select public.accept_invitation('DLHALA2222');
select tests.login('a1000000-0000-4000-8000-000000000013');
select public.accept_invitation('DLAMCA2222');
select tests.login('a1000000-0000-4000-8000-000000000014');
select public.accept_invitation('DLDAYS2222');
reset role;
select tests.logout();

-- Ela owns all three products, Mert only the book.
insert into public.premium_orders (id, family_account_id, baby_id, product_id, product_code, price_minor, currency, provider, status, paid_at)
select gen_random_uuid(), :'acct', b.baby, p.id, p.code, p.price_minor, p.currency, 'mock', 'paid', now()
  from public.current_premium_products() p
  join (values (:'ela'::uuid, 'first_year_book'), (:'ela'::uuid, 'first_year_film'), (:'ela'::uuid, 'first_year_html'),
               (:'mert'::uuid, 'first_year_book')) b(baby, code) on b.code = p.code;
insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
select o.family_account_id, o.baby_id, o.product_code, o.id from public.premium_orders o where o.family_account_id = :'acct';

select tests.ready_artifact(:'ela', 'first_year_book', 'a1000000-0000-4000-8000-000000000001', 'dl-book-0001', 'kitap.pdf') as book \gset
select tests.ready_artifact(:'ela', 'first_year_film', 'a1000000-0000-4000-8000-000000000001', 'dl-film-0001', 'film.mp4') as film \gset
select tests.ready_artifact(:'ela', 'first_year_html', 'a1000000-0000-4000-8000-000000000001', 'dl-html-0001', 'arsiv.zip') as html \gset
select tests.ready_artifact(:'mert', 'first_year_book', 'a1000000-0000-4000-8000-000000000001', 'dl-mert-0001', 'kitap.pdf') as mert_book \gset

-- Parents: the same re-download rule for every product, no grant needed --------------------------------------
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000002');
select tests.eq((select count(*) from (select public.authorize_artifact_download(x) from unnest(array[:'book', :'film', :'html']::uuid[]) x) q
                  where true), 3::bigint, 'parent request on all three products');
select tests.eq((select bool_and(allowed and expires_in = 60)
                   from unnest(array[:'book', :'film', :'html']::uuid[]) x, public.authorize_artifact_download(x)), true,
                'parent (Baba) downloads Book, Film and HTML alike');

-- Family Member: never downloads (decision P-12, 2026-10-02) -----------------------------------------------------
select tests.login('a1000000-0000-4000-8000-000000000011');
select tests.eq((select reason from public.authorize_artifact_download(:'book')), 'not_parent', 'a Family Member is refused the book');
select tests.eq((select bool_and(not allowed and reason = 'not_parent')
                   from unnest(array[:'book', :'film', :'html']::uuid[]) x, public.authorize_artifact_download(x)), true,
                'and the film and the archive');
select tests.eq(tests.count(format('select 1 from public.book_versions(%L)', :'ela')), 0::bigint, 'member sees no book version');
select tests.eq((select artifact_id is null from public.film_state(:'ela')), true, 'member sees no film');
select tests.eq((select artifact_id is null from public.html_state(:'ela')), true, 'member sees no archive');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'book'), 'not_parent');
-- Production / purchase endpoints are closed to members.
select tests.expect_error(format($q$select public.set_artifact_download_permission(%L, %L, 'first_year_book', true)$q$, :'ela',
                                 'a1000000-0000-4000-8000-000000000011'), 'not_parent');
select tests.expect_error(format('select * from public.artifact_download_permission_list(%L)', :'ela'), 'not_parent');
select tests.expect_error(format('select * from public.book_render_start(%L, %L)', :'ela', 'dl-teyze-0001'), 'not_parent');
select tests.expect_error(format('select * from public.film_request_render(%L, %L)', :'ela', 'dl-teyze-0002'), 'not_parent');
select tests.expect_error(format($q$select public.film_update_settings(%L, '{}')$q$, :'ela'), 'not_parent');
select tests.expect_error(format('select * from public.html_request_render(%L, %L)', :'ela', 'dl-teyze-0003'), 'not_parent');
select tests.expect_error(format('select * from public.request_output_job(%L, %L, %L)', :'ela', 'first_year_book', 'dl-teyze-0004'), 'not_parent');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'ela', 'first_year_book', 'app_store'), 'not_parent');
select tests.expect_error(format('select * from public.request_premium_purchase(%L, %L, %L)', :'mert', 'first_year_film', 'app_store'), 'not found');
select tests.eq((select reason from public.authorize_artifact_download(:'mert_book')), 'not_found', 'another baby''s artifact (IDOR)');
select tests.login('a1000000-0000-4000-8000-000000000012');
select tests.eq((select reason from public.authorize_artifact_download(:'book')), 'not_parent', 'Hala is refused too');
select tests.login('a1000000-0000-4000-8000-000000000021');
select tests.eq((select reason from public.authorize_artifact_download(:'book')), 'not_found', 'another family account cannot use the artifact id');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'book'), 'not found');

-- Parents cannot share any more; revoking stays possible ------------------------------------------------------------
select tests.login('a1000000-0000-4000-8000-000000000001');
select tests.expect_error(format($q$select public.set_artifact_download_permission(%L, %L, 'first_year_book', true)$q$, :'ela',
                                 'a1000000-0000-4000-8000-000000000011'), 'member_downloads_disabled');
select tests.eq(public.set_artifact_download_permission(:'ela', 'a1000000-0000-4000-8000-000000000011', 'first_year_book', false), false,
                'revoking stays possible (idempotent clean-up)');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.artifact_download_permissions where baby_id = :'ela' and revoked_at is null), 0::bigint,
                'no active grant');
select tests.eq((select enabled from public.platform_flags where key = 'member_downloads'), false, 'member downloads are retired');
-- A grant row that predates the decision (or is written by mistake) opens nothing.
insert into public.artifact_download_permissions (family_account_id, baby_id, product_code, member_user_id, granted_by)
values (:'acct', :'ela', 'first_year_book', 'a1000000-0000-4000-8000-000000000011', 'a1000000-0000-4000-8000-000000000001');
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000011');
select tests.eq((select reason from public.authorize_artifact_download(:'book')), 'not_parent', 'a stray grant never opens a download');
reset role;
select tests.logout();

-- Subscription lapse and renewal: kept, closed, reopened without a new purchase -------------------------------------
update public.subscriptions set status = 'expired', current_period_end = now() - interval '1 day' where family_account_id = :'acct';
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000001');
select tests.eq((select reason from public.authorize_artifact_download(:'film')), 'subscription_required', 'parent: subscription lapsed');
reset role;
select tests.logout();
update public.subscriptions set status = 'active', current_period_end = now() + interval '1 month' where family_account_id = :'acct';
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000001');
select tests.eq((select allowed from public.authorize_artifact_download(:'film')), true, 'renewed: same artifact again, no new purchase');
reset role;
select tests.logout();

-- A downgrade below the active member count never affects the parents --------------------------------------------------
update public.subscriptions s set plan_id = p.id, plan_code = p.code
  from public.subscription_plans p
 where s.family_account_id = :'acct' and p.code = 'small_family' and p.billing_period = 'monthly';
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000002');
select tests.eq((select allowed from public.authorize_artifact_download(:'book')), true, 'parents are not counted against capacity');
reset role;
select tests.logout();
update public.subscriptions s set plan_id = p.id, plan_code = p.code
  from public.subscription_plans p
 where s.family_account_id = :'acct' and p.code = 'normal_family' and p.billing_period = 'monthly';

-- Refund / chargeback: the entitlement ends, every download closes ------------------------------------------------------
update public.product_entitlements set status = 'revoked', revoked_at = now()
 where family_account_id = :'acct' and baby_id = :'ela' and product_code = 'first_year_html';
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000001');
select tests.eq((select reason from public.authorize_artifact_download(:'html')), 'entitlement_required', 'refunded archive: parent refused');
select tests.eq((select allowed from public.authorize_artifact_download(:'book')), true, 'other products unaffected');
reset role;
select tests.logout();

-- Leaving the family still ends any leftover grant ---------------------------------------------------------------------
update public.family_account_members set status = 'removed', removed_at = now()
 where family_account_id = :'acct' and user_id = 'a1000000-0000-4000-8000-000000000011';
select tests.eq((select count(*) from public.artifact_download_permissions
                  where member_user_id = 'a1000000-0000-4000-8000-000000000011' and revoked_at is null), 0::bigint,
                'membership end revokes every grant');
update public.family_account_members set status = 'active', removed_at = null
 where family_account_id = :'acct' and user_id = 'a1000000-0000-4000-8000-000000000011';

-- Audit and rate limits ------------------------------------------------------------------------------------------------------
select tests.eq((select count(*) from public.output_artifact_downloads where artifact_id = :'book' and role = 'parent') > 0, true,
                'downloads are audited with the role');
select tests.eq((select count(*) from public.output_artifact_downloads where artifact_id = :'book' and role = 'family_member'), 0::bigint,
                'no Family Member download was ever granted');
select tests.eq((select count(*) from public.output_download_denials where artifact_id = :'book' and reason = 'not_parent') > 0, true,
                'refusals are audited with their reason');
set role authenticated;
select tests.login('a1000000-0000-4000-8000-000000000001');
-- Each download is its own request (one statement each).
select set_config('dl.mert_book', :'mert_book', false);
do $$
declare
  v_allowed integer := 0;
  v_row record;
begin
  for i in 1..12 loop
    select * into v_row from public.authorize_artifact_download(current_setting('dl.mert_book')::uuid);
    if v_row.allowed then
      v_allowed := v_allowed + 1;
    end if;
  end loop;
  perform tests.eq(v_allowed, 10, 'at most 10 grants per artifact and user in 10 minutes');
end;
$$;
select tests.eq((select reason from public.authorize_artifact_download(:'mert_book')), 'rate_limited', 'then rate limited');
select tests.expect_error(format('select * from public.request_output_download(%L)', :'mert_book'), 'rate_limited');
select tests.expect_error($q$select * from public.admin_download_audit(7)$q$, 'not authorized');
select tests.expect_error($q$select * from public.output_download_denials$q$, 'permission denied');
select tests.expect_error($q$select * from public.artifact_download_permissions$q$, 'permission denied');
select tests.login('a1000000-0000-4000-8000-000000000031');
select tests.eq((select n from public.admin_download_audit(7) where product_code = 'first_year_book' and outcome = 'denied:rate_limited') >= 1,
                true, 'Super Admin sees refusals by reason');
reset role;
select tests.logout();
