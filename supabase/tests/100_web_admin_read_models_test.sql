-- Web admin read models: database role checks, kill switch, safe filters,
-- pagination and redaction. No production data is required.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

insert into public.platform_user_roles (user_id, role, granted_by)
values (tests.id('baska'), 'super_admin', tests.id('anne'))
on conflict (user_id, role) do update set revoked_at = null;

-- A normal authenticated account cannot call any web-admin read model.
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$select public.admin_dashboard_summary()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_users_families()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_subscription_plans()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_subscriptions()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_premium_products()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_purchase_records()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_payment_events()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_platform_audit_log()$q$, 'not authorized');

-- The database-backed role grants access; results are real database values.
select tests.login(tests.id('baska'));
select tests.eq((public.admin_dashboard_summary() ->> 'users_total')::bigint > 0, true, 'dashboard uses real users');
select tests.eq((select count(*) from public.admin_users_families(null, 'all', 1, 0)), 1::bigint, 'users are paginated');
select tests.eq((select total_count from public.admin_users_families(null, 'all', 1, 0) limit 1) > 1, true, 'user total count returned');
select tests.expect_error($q$select * from public.admin_users_families(null, 'bogus')$q$, 'invalid status');
select tests.expect_error(format('select * from public.admin_users_families(%L)', repeat('x', 61)), 'too long');

select tests.eq((select count(*) from public.admin_subscription_plans()), 6::bigint, 'six subscription catalog rows');
select tests.eq((select google_product_id from public.admin_subscription_plans()
                  where plan_code = 'small_family' and billing_period = 'monthly'),
                'small_family', 'Google subscription product id');
select tests.eq((select google_base_plan_id from public.admin_subscription_plans()
                  where plan_code = 'small_family' and billing_period = 'monthly'),
                'monthly', 'Google base plan id');
select tests.expect_error($q$select * from public.admin_subscriptions('unknown')$q$, 'invalid status');
select tests.expect_error($q$select * from public.admin_subscriptions('all', 'unknown')$q$, 'invalid plan');

select tests.eq((select count(*) from public.admin_premium_products()), 3::bigint, 'three premium products');
select tests.eq((select google_product_id from public.admin_premium_products()
                  where product_code = 'first_year_book'), 'first_year_book', 'Google one-time product id');
select tests.expect_error($q$select * from public.admin_purchase_records('unknown')$q$, 'invalid status');
select tests.expect_error($q$select * from public.admin_payment_events('unknown')$q$, 'invalid event kind');
select tests.expect_error($q$select * from public.admin_payment_events('all', 'unknown')$q$, 'invalid result');
select tests.expect_error($q$select * from public.admin_platform_audit_log('unknown')$q$, 'invalid audit source');

-- Store payloads and tokens are intentionally absent from the returned schema.
select tests.expect_error(
  $q$select payload from public.admin_payment_events()$q$,
  'column "payload" does not exist'
);
select tests.expect_error(
  $q$select purchase_token from public.admin_purchase_records()$q$,
  'column "purchase_token" does not exist'
);

-- Kill switch applies to all new read models.
reset role;
select tests.logout();
update public.platform_flags set enabled = false, note = 'web admin test' where key = 'admin_console';
set role authenticated;
select tests.login(tests.id('baska'));
select tests.expect_error($q$select public.admin_dashboard_summary()$q$, 'admin_console_disabled');

-- Revoking the role takes effect immediately.
reset role;
select tests.logout();
update public.platform_flags set enabled = true, note = 'web admin test complete' where key = 'admin_console';
update public.platform_user_roles set revoked_at = now()
 where user_id = tests.id('baska') and role = 'super_admin';
set role authenticated;
select tests.login(tests.id('baska'));
select tests.expect_error($q$select public.admin_dashboard_summary()$q$, 'not authorized');

reset role;
select tests.logout();
update public.platform_user_roles set revoked_at = null
 where user_id = tests.id('baska') and role = 'super_admin';
