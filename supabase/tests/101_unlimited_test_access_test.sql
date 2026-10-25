-- UUID-based unlimited test access: no financial records, no cross-family
-- access, and immediate return to paid gates after revocation.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();

select tests.eq(
  (select count(*) from public.test_access_grants
    where enabled and user_id in (
      '11111111-1111-4111-8111-111111111111',
      '22222222-2222-4222-8222-222222222222',
      '44444444-4444-4444-8444-444444444444',
      '098ed0fd-b95a-42bb-8bdb-16050541466f'
    )),
  3::bigint,
  'all approved UUIDs present in the local seed receive unlimited access'
);

insert into auth.users (id, email, raw_user_meta_data) values
  ('9b000000-0000-4000-8000-000000000001', 'test-access-admin@example.com', '{"display_name":"Test Admin"}'),
  ('9b000000-0000-4000-8000-000000000002', 'unlimited-parent@example.com', '{"display_name":"Unlimited Parent"}'),
  ('9b000000-0000-4000-8000-000000000003', 'normal-parent@example.com', '{"display_name":"Normal Parent"}'),
  ('9b000000-0000-4000-8000-000000000004', 'other-family@example.com', '{"display_name":"Other Family"}'),
  ('9b000000-0000-4000-8000-000000000005', 'new-member@example.com', '{"display_name":"New Member"}');

insert into public.platform_user_roles (user_id, role, granted_by)
values ('9b000000-0000-4000-8000-000000000001', 'super_admin', '9b000000-0000-4000-8000-000000000001');

insert into public.family_accounts (id, display_name, created_by) values
  ('9b100000-0000-4000-8000-000000000001', 'Unlimited Family', '9b000000-0000-4000-8000-000000000002'),
  ('9b100000-0000-4000-8000-000000000002', 'Normal Family', '9b000000-0000-4000-8000-000000000003');
insert into public.family_account_members
  (family_account_id, user_id, role, relationship_label, status, activated_at) values
  ('9b100000-0000-4000-8000-000000000001', '9b000000-0000-4000-8000-000000000002', 'parent', 'anne', 'active', now()),
  ('9b100000-0000-4000-8000-000000000002', '9b000000-0000-4000-8000-000000000003', 'parent', 'anne', 'active', now()),
  ('9b100000-0000-4000-8000-000000000002', '9b000000-0000-4000-8000-000000000004', 'family_member', 'teyze', 'active', now());

insert into public.babies (id, first_name, birth_date, created_by) values
  ('9b200000-0000-4000-8000-000000000001', 'Unlimited Baby', public.business_date_istanbul() - 400,
   '9b000000-0000-4000-8000-000000000002'),
  ('9b200000-0000-4000-8000-000000000002', 'Normal Baby', public.business_date_istanbul() - 400,
   '9b000000-0000-4000-8000-000000000003');
insert into public.family_account_babies (baby_id, family_account_id) values
  ('9b200000-0000-4000-8000-000000000001', '9b100000-0000-4000-8000-000000000001'),
  ('9b200000-0000-4000-8000-000000000002', '9b100000-0000-4000-8000-000000000002');
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('9b200000-0000-4000-8000-000000000001', '9b000000-0000-4000-8000-000000000002', 'anne', true,
   array(select key from public.permissions)),
  ('9b200000-0000-4000-8000-000000000002', '9b000000-0000-4000-8000-000000000003', 'anne', true,
   array(select key from public.permissions)),
  ('9b200000-0000-4000-8000-000000000002', '9b000000-0000-4000-8000-000000000004', 'teyze', false,
   '{view_memories,view_album}');

update public.platform_flags set enabled = true where key = 'subscription_enforcement';

set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000002');
select tests.eq(public.baby_subscription_ok('9b200000-0000-4000-8000-000000000001'), false,
                'test parent starts behind the normal subscription gate');
select tests.expect_error(
  $q$select * from public.request_output_job('9b200000-0000-4000-8000-000000000001', 'first_year_book', 'before-grant-0001')$q$,
  'subscription_required');

select tests.login('9b000000-0000-4000-8000-000000000001');
select tests.eq(public.admin_set_test_access('9b000000-0000-4000-8000-000000000002', true, 'Approved test fixture'),
                'granted', 'Super Admin grants unlimited test access');
select tests.eq((select access_enabled from public.admin_test_access_users('unlimited-parent@example.com', 'active', 10, 0)),
                true, 'Super Admin read model shows the active grant');

select tests.login('9b000000-0000-4000-8000-000000000003');
select tests.expect_error($q$select * from public.admin_test_access_users(null, 'all', 10, 0)$q$, 'not authorized');

select tests.login('9b000000-0000-4000-8000-000000000002');
select tests.eq(public.baby_subscription_ok('9b200000-0000-4000-8000-000000000001'), true,
                'test family gets all subscription-gated content rights');
select tests.eq((select reason from public.baby_access_state('9b200000-0000-4000-8000-000000000001')),
                'test_access', 'client access state identifies the server-side test grant');
select tests.eq((select count(*) from public.baby_entitlements('9b200000-0000-4000-8000-000000000001')),
                3::bigint, 'all three digital products are included without purchases');
select tests.expect_error(
  $q$select * from public.request_subscription_checkout('9b100000-0000-4000-8000-000000000001', 'large_family', 'monthly', 'google_play')$q$,
  'test_access_included');
select tests.expect_error(
  $q$select * from public.request_premium_purchase('9b200000-0000-4000-8000-000000000001', 'first_year_book', 'google_play')$q$,
  'test_access_included');

select job_id as book_job from public.request_output_job(
  '9b200000-0000-4000-8000-000000000001', 'first_year_book', 'test-book-0001') \gset
select job_id as html_job from public.request_output_job(
  '9b200000-0000-4000-8000-000000000001', 'first_year_html', 'test-html-0001') \gset
select job_id as film_job from public.request_output_job(
  '9b200000-0000-4000-8000-000000000001', 'first_year_film', 'test-film-0001') \gset

reset role;
select tests.logout();

create or replace function tests.test_access_ready_artifact(p_job uuid, p_file text, p_hash text)
returns uuid
language plpgsql
as $$
declare
  v_art uuid;
  v_staging text;
  v_path text;
  v_mime text;
begin
  update public.output_jobs
     set status = 'running', attempts = attempts + 1, lease_owner = 'test-access-worker',
         lease_expires_at = now() + interval '5 minutes', started_at = now()
   where id = p_job;
  insert into public.output_job_attempts (job_id, attempt, worker)
  values (p_job, 1, 'test-access-worker');
  select public.output_product_mime(j.product_code) into v_mime
    from public.output_jobs j where j.id = p_job;
  select b.artifact_id, b.staging_path, b.storage_path into v_art, v_staging, v_path
    from public.output_artifact_begin(p_job, 'test-access-worker', p_file, v_mime, p_hash, 100) b;
  insert into storage.objects (bucket_id, name, metadata) values
    ('output-artifacts', v_path, '{"size":100}'),
    ('output-artifacts', v_staging, '{"size":100}');
  perform public.output_artifact_verify(v_art, 'test-access-worker', p_hash);
  if public.output_artifact_publish(v_art, 'test-access-worker') <> 'ready' then
    raise exception 'test artifact did not become ready';
  end if;
  return v_art;
end;
$$;

select tests.test_access_ready_artifact(:'book_job', 'kitap.pdf', repeat('a', 64)) as book_art \gset
select tests.test_access_ready_artifact(:'html_job', 'arsiv.zip', repeat('b', 64)) as html_art \gset
select tests.test_access_ready_artifact(:'film_job', 'film.mp4', repeat('c', 64)) as film_art \gset

-- Unlimited seats apply without manufacturing a subscription row.
select public.family_account_activate_member(
  '9b100000-0000-4000-8000-000000000001', '9b000000-0000-4000-8000-000000000005', false, 'teyze',
  '9b000000-0000-4000-8000-000000000002');
select tests.eq(public.family_account_active_member_count('9b100000-0000-4000-8000-000000000001'),
                1, 'test family activates a new Family Member without a paid plan');
select tests.expect_error(
  $q$select public.family_account_activate_member('9b100000-0000-4000-8000-000000000002',
       '9b000000-0000-4000-8000-000000000005', false, 'teyze', '9b000000-0000-4000-8000-000000000003')$q$,
  'subscription_required');

select tests.eq((select count(*) from public.subscriptions where family_account_id = '9b100000-0000-4000-8000-000000000001'),
                0::bigint, 'test access creates no subscription');
select tests.eq((select count(*) from public.subscription_checkout_intents where family_account_id = '9b100000-0000-4000-8000-000000000001'),
                0::bigint, 'test access creates no checkout intent');
select tests.eq((select count(*) from public.premium_orders where family_account_id = '9b100000-0000-4000-8000-000000000001'),
                0::bigint, 'test access creates no premium order');
select tests.eq((select count(*) from public.product_entitlements where family_account_id = '9b100000-0000-4000-8000-000000000001'),
                0::bigint, 'test access creates no paid entitlement');

set role authenticated;
select tests.login('9b000000-0000-4000-8000-000000000002');
select tests.eq((select bool_and(allowed)
                   from unnest(array[:'book_art', :'html_art', :'film_art']::uuid[]) a,
                        public.authorize_artifact_download(a)),
                true, 'test parent downloads PDF, ZIP and MP4');

select tests.login('9b000000-0000-4000-8000-000000000004');
select tests.eq((select allowed from public.authorize_artifact_download(:'book_art')), false,
                'another family cannot download a private test artifact');
select tests.eq((select reason from public.authorize_artifact_download(:'book_art')), 'not_found',
                'cross-family denial does not reveal the artifact');

select tests.login('9b000000-0000-4000-8000-000000000003');
select tests.expect_error(
  $q$select * from public.request_output_job('9b200000-0000-4000-8000-000000000002', 'first_year_book', 'normal-book-0001')$q$,
  'subscription_required');

select tests.login('9b000000-0000-4000-8000-000000000001');
select tests.eq(public.admin_set_test_access('9b000000-0000-4000-8000-000000000002', false, 'Fixture revocation test'),
                'revoked', 'Super Admin revokes test access');
select tests.eq((select count(*) from public.admin_test_access_events('9b000000-0000-4000-8000-000000000002', 10, 0)),
                2::bigint, 'grant and revocation are both audited');

select tests.login('9b000000-0000-4000-8000-000000000002');
select tests.expect_error(
  $q$select * from public.request_output_job('9b200000-0000-4000-8000-000000000001', 'first_year_book', 'after-revoke-0001')$q$,
  'subscription_required');
select tests.eq((select allowed from public.authorize_artifact_download(:'book_art')), false,
                'revocation closes future free downloads');
select tests.eq((select reason from public.authorize_artifact_download(:'book_art')), 'subscription_required',
                'revoked family returns to the normal payment gate');

reset role;
select tests.logout();
update public.platform_flags set enabled = false where key = 'subscription_enforcement';
delete from public.platform_user_roles where user_id = '9b000000-0000-4000-8000-000000000001' and role = 'super_admin';
drop function tests.test_access_ready_artifact(uuid, text, text);
