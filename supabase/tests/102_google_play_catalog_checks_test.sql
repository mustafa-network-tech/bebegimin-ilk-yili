-- Google Play catalog checks: server-normalized input, Super Admin boundary,
-- append-only audit history and secret-field stripping.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();
insert into public.platform_user_roles (user_id, role, granted_by)
values (tests.id('baska'), 'super_admin', tests.id('anne'))
on conflict (user_id, role) do update set revoked_at = null;

set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error(
  $q$select public.admin_record_google_play_catalog_check(
       'not_configured', 'com.mkdigitalsystems.bebegimin_ilk_yili', '[]', 'environment_not_configured')$q$,
  'not authorized');
select tests.expect_error($q$select * from public.admin_google_play_catalog_latest()$q$, 'not authorized');
select tests.expect_error($q$select * from public.google_play_catalog_checks$q$, 'permission denied');

select tests.login(tests.id('baska'));
select public.admin_record_google_play_catalog_check(
  'not_configured', 'com.mkdigitalsystems.bebegimin_ilk_yili', '[]', 'environment_not_configured') as missing_check \gset
select tests.eq((select connection_status from public.admin_google_play_catalog_latest()),
                'not_configured', 'missing API configuration is audited without a false verification');

select public.admin_record_google_play_catalog_check(
  'success',
  'com.mkdigitalsystems.bebegimin_ilk_yili',
  jsonb_build_array(jsonb_build_object(
    'kind', 'subscription',
    'product_id', 'small_family',
    'base_plan_id', 'monthly',
    'status', 'verified',
    'play_state', 'ACTIVE',
    'expected_price_minor', 29900,
    'play_price_minor', 29900,
    'expected_currency', 'TRY',
    'play_currency', 'TRY',
    'detail_code', null,
    'access_token', 'must-not-be-stored',
    'private_key', 'must-not-be-stored'
  )),
  null
) as success_check \gset

select tests.eq((select connection_status from public.admin_google_play_catalog_latest()),
                'success', 'successful API connection is stored');
select tests.eq((select results -> 0 ->> 'status' from public.admin_google_play_catalog_latest()),
                'verified', 'normalized catalog result is readable by Super Admin');
select tests.eq((select (results -> 0) ? 'access_token' from public.admin_google_play_catalog_latest()),
                false, 'access token field is stripped at the database boundary');
select tests.eq((select (results -> 0) ? 'private_key' from public.admin_google_play_catalog_latest()),
                false, 'private key field is stripped at the database boundary');
select tests.eq((select count(*) from public.admin_platform_audit_log('google_play', 10, 0)
                  where event_id = :'success_check'::bigint),
                1::bigint, 'catalog check appears in platform audit history');
select tests.expect_error(
  $q$select public.admin_record_google_play_catalog_check(
       'success', 'wrong.package', '[]', null)$q$,
  'invalid Google Play package');
select tests.expect_error(
  $q$select public.admin_record_google_play_catalog_check(
       'permission_denied', 'com.mkdigitalsystems.bebegimin_ilk_yili', '[]', null)$q$,
  'failed Google Play checks');

reset role;
select tests.logout();
select tests.expect_error(
  format('update public.google_play_catalog_checks set error_code = %L where id = %s', 'changed', :'missing_check'),
  'append-only');
update public.platform_user_roles set revoked_at = now()
 where user_id = tests.id('baska') and role = 'super_admin';
