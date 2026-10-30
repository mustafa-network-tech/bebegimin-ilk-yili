-- =====================================================================
-- Release health: the demo accounts of supabase/seed.sql (known password,
-- auto-filled by DEMO_MODE builds) are reported as 'critical'. They belong
-- to development / staging only; production must report 0 (go-live gate,
-- docs/operations/release-runbook.md).
-- =====================================================================
begin;

create or replace function public.admin_release_health()
returns table (check_name text, value numeric, status text, detail text)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v numeric;
  function_status text;
begin
  perform public.assert_admin_console('read', 60);

  -- Lifecycle integrity: data that the lifecycle rules can never produce.
  select count(*) into v from public.babies b
   where b.birth_date > public.business_date_istanbul()
      or (select count(*) from public.baby_extension_requests e where e.baby_id = b.id and e.status = 'approved') > 1
      or exists (select 1 from public.baby_extension_requests e
                  where e.baby_id = b.id and e.status = 'approved' and e.requested_days not between 1 and 30);
  return query select 'lifecycle_mismatch'::text, v, case when v > 0 then 'critical' else 'ok' end, 'babies breaking lifecycle invariants';

  select coalesce(extract(epoch from now() - min(j.created_at)) / 60, 0) into v
    from public.output_jobs j where j.status = 'queued' and j.available_at <= now();
  return query select 'output_queue_age_minutes', round(v, 1),
                      case when v > 120 then 'critical' when v > 30 then 'warn' else 'ok' end, 'oldest claimable job';

  select count(*) into v from public.output_jobs j where j.status = 'poison' and j.finished_at > now() - interval '24 hours';
  return query select 'output_jobs_poison_24h', v, case when v > 10 then 'critical' when v > 3 then 'warn' else 'ok' end,
                      'jobs that ended without retry';

  select count(*) into v from public.output_artifacts a
   where a.status = 'quarantined' and a.failure_code in ('checksum_mismatch', 'size_mismatch', 'object_missing')
     and a.created_at > now() - interval '24 hours';
  return query select 'artifact_checksum_failures_24h', v, case when v > 5 then 'critical' when v > 0 then 'warn' else 'ok' end,
                      'quarantined uploads';

  select count(*) into v from public.output_download_denials d
   where d.requested_at > now() - interval '1 hour' and d.reason not in ('rate_limited');
  return query select 'download_denials_1h', v, case when v > 500 then 'critical' when v > 100 then 'warn' else 'ok' end,
                      'refused download requests';

  select count(*) into v from public.billing_events e where e.result = 'rejected' and e.received_at > now() - interval '24 hours';
  return query select 'payment_webhook_rejections_24h', v, case when v > 20 then 'critical' when v > 5 then 'warn' else 'ok' end,
                      'store events that could not be applied';

  -- Webhook lag proxy: live paid subscriptions but no store event for 48 h.
  select coalesce(extract(epoch from now() - max(e.received_at)) / 3600, 0) into v from public.billing_events e;
  function_status := case
    when exists (select 1 from public.subscriptions s where s.provider in ('app_store', 'google_play')
                   and s.status in ('active', 'grace', 'past_due')) and v > 48 then 'warn' else 'ok' end;
  return query select 'payment_webhook_silence_hours', round(v, 1), function_status, 'hours since the last store event';

  select count(*) into v from public.storage_cleanup_queue q where q.created_at < now() - interval '24 hours';
  return query select 'storage_cleanup_backlog', v, case when v > 1000 then 'warn' else 'ok' end, 'queued deletions older than 24 h';

  select count(*) into v from public.subscriptions s where s.over_capacity;
  return query select 'subscriptions_over_capacity', v, case when v > 0 then 'warn' else 'ok' end, 'downgraded below active members';

  -- The demo users of supabase/seed.sql have a published password. They are
  -- expected in development / staging and must never exist in production.
  select count(*) into v from auth.users u
   where u.id in ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
                  '33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444')
      or lower(u.email) in ('anne@example.com', 'baba@example.com', 'teyze@example.com', 'baska@example.com');
  return query select 'demo_accounts', v, case when v > 0 then 'critical' else 'ok' end,
                      'seed demo users with a known password (must be 0 in production)';
end;
$$;

commit;
