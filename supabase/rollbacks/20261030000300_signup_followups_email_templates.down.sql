-- Rollback of 20261030000300_signup_followups_email_templates.sql.
-- Drops only the manual-mark and template tables; no user, family or subscription row is touched.
begin;

drop function if exists public.admin_save_email_template(text, text, text);
drop function if exists public.admin_email_templates();
drop function if exists public.admin_mark_email_sent(uuid, text, uuid);
drop function if exists public.admin_pending_signup_count();
drop function if exists public.admin_new_signups(text, integer, integer);

drop trigger if exists email_template_versions_immutable on public.email_template_versions;
drop table if exists public.email_template_versions;
drop table if exists public.email_templates;
drop table if exists public.email_followups;
drop function if exists public.email_template_versions_immutable();

delete from public.user_event_meta where key = 'signup_queue_started';

commit;
