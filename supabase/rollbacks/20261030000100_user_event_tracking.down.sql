-- Rollback of 20261030000100_user_event_tracking.sql.
-- Removes only the tracking objects; no subscription, family, baby or user row is touched.
-- The recorded events themselves are dropped with the table.
begin;

drop trigger if exists user_events_auth_insert on auth.users;
drop trigger if exists user_events_auth_update on auth.users;
drop trigger if exists user_events_family_account on public.family_accounts;
drop trigger if exists user_events_baby_link on public.family_account_babies;
drop trigger if exists user_events_subscription on public.subscriptions;

drop function if exists public.purge_user_events(interval);
drop function if exists public.admin_payment_problems(integer, integer);
drop function if exists public.admin_conversion_funnel(integer);
drop function if exists public.admin_user_activity_summary(uuid);
drop function if exists public.admin_user_activity(uuid, integer, integer);
drop function if exists public.user_payment_problem(uuid);
drop function if exists public.user_events_has_access(uuid, text, text);
drop function if exists public.user_events_parent_accounts(uuid);
drop function if exists public.user_events_on_subscription();
drop function if exists public.user_events_on_baby_link();
drop function if exists public.user_events_on_family_account();
drop function if exists public.user_events_on_auth_user();
drop function if exists public.record_server_user_event(uuid, text, text, text, text, text, text, uuid);
drop function if exists public.user_events_write(uuid, uuid, text, text, text, text, text, text);

drop table if exists public.user_events;
drop table if exists public.user_event_meta;

commit;
