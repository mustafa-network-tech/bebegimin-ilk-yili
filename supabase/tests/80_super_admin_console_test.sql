-- Phase 5: Super Admin console RPCs. Platform role only (never family admin,
-- never client claims), audited decisions/corrections, SLA ordering, minimal
-- data, pagination, safe search, rate limit and kill switch.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

select tests.logout();
reset role;

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('96000000-0000-4000-8000-000000000003', 'admin-uc@example.com');
update public.profiles set display_name = 'Operasyon' where id = tests.id('baska');
insert into public.platform_user_roles (user_id, role, granted_by)
values (tests.id('baska'), 'super_admin', tests.id('anne'))
on conflict do nothing;
insert into public.platform_user_roles (user_id, role)
values ('96000000-0000-4000-8000-000000000003', 'super_admin');
insert into public.babies (id, first_name, birth_date, created_by) values
  ('93000000-0000-4000-8000-000000000001', 'Kuyruk', public.business_date_istanbul() - 373, tests.id('anne')),
  ('93000000-0000-4000-8000-000000000002', 'Uzak', public.business_date_istanbul() - 100, tests.id('anne')),
  ('93000000-0000-4000-8000-000000000003', 'Geçmiş', public.business_date_istanbul() - 100, tests.id('anne')),
  ('93000000-0000-4000-8000-000000000004', 'Yüzde_%', public.business_date_istanbul() - 100, tests.id('anne'));
insert into public.family_members (baby_id, user_id, relation, is_admin, permissions)
select b.id, tests.id('anne'), 'anne', true, array(select key from public.permissions)
  from public.babies b where b.id::text like '93000000-0000-4000-8000-00000000000_' and b.id::text <> '93000000-0000-4000-8000-000000000009';

set role authenticated;
select tests.login(tests.id('anne'));
select public.request_baby_extension('93000000-0000-4000-8000-000000000001', 5) as req_urgent \gset
select public.request_baby_extension('93000000-0000-4000-8000-000000000002', 20) as req_normal \gset
select public.request_baby_extension('93000000-0000-4000-8000-000000000003', 15) as req_late \gset
reset role;
select tests.logout();
-- Geçmiş passes its base close before anyone decides (job not run yet).
update public.babies set birth_date = public.business_date_istanbul() - 380 where id = '93000000-0000-4000-8000-000000000003';

-- Family admin is not a platform admin; client claims are not enough --------------------
set role authenticated;
select tests.login(tests.id('anne'));
select tests.eq((select is_super_admin from public.admin_session()), false, 'family admin is not a Super Admin');
select tests.eq((select console_enabled from public.admin_session()), false, 'family admin has no console');
select tests.expect_error($q$select * from public.admin_extension_queue()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_audit_log()$q$, 'not authorized');
select tests.expect_error($q$select * from public.admin_baby_lookup('Kuyruk')$q$, 'not authorized');
select tests.expect_error(
  format('select * from public.admin_preview_birth_date_correction(%L, %L)', '93000000-0000-4000-8000-000000000001', public.business_date_istanbul() - 1),
  'not authorized');
select tests.expect_error(format('select public.admin_decide_extension(%L, %L, %L)', :'req_normal', 'approved', 'x'), 'not authorized');
select tests.expect_error(
  format('select public.admin_correct_birth_date(%L, %L, %L)', '93000000-0000-4000-8000-000000000002', public.business_date_istanbul() - 101, 'x'),
  'not authorized');
select tests.expect_error($q$select * from public.platform_role_events$q$, 'permission denied');
select tests.expect_error($q$select * from public.admin_rate_limits$q$, 'permission denied');
select tests.expect_error($q$select public.assert_admin_console('read', 10)$q$, 'permission denied');

select set_config('request.jwt.claims', json_build_object(
  'sub', tests.id('anne'), 'role', 'authenticated', 'user_role', 'super_admin',
  'app_metadata', json_build_object('role', 'super_admin', 'roles', json_build_array('super_admin'))
)::text, false);
select tests.expect_error($q$select * from public.admin_extension_queue()$q$, 'not authorized');
select tests.eq((select is_super_admin from public.admin_session()), false, 'forged JWT claims do not make a Super Admin');

-- Queue: SLA ordering, expired read-only, minimal fields, pagination, safe search ------------
select tests.login(tests.id('baska'));
select tests.eq((select console_enabled from public.admin_session()), true, 'Super Admin has the console');
select tests.eq(
  (select request_id from public.admin_extension_queue('pending') limit 1),
  :'req_urgent'::uuid,
  'closest base close is first in the pending queue');
select tests.eq((select sla from public.admin_extension_queue('pending') where request_id = :'req_urgent'), 'urgent', 'two days before close is urgent');
select tests.eq((select sla from public.admin_extension_queue('pending') where request_id = :'req_normal'), 'normal', 'far away close is normal');
select tests.eq((select requested_days from public.admin_extension_queue('pending') where request_id = :'req_normal'), 20::smallint, 'requested days shown');
select tests.eq((select requested_by_name from public.admin_extension_queue('pending') where request_id = :'req_normal'), 'Elif', 'requester display name shown');
select tests.eq((select count(*) from public.admin_extension_queue('pending') where request_id = :'req_late'), 0::bigint, 'passed-close request is not pending');
select tests.eq((select status from public.admin_extension_queue('expired') where request_id = :'req_late'), 'expired', 'passed-close request shows as expired');
select tests.eq((select count(*) from public.admin_extension_queue('all', null, 1, 0)), 1::bigint, 'page size is respected');
select tests.eq((select total_count from public.admin_extension_queue('all', null, 1, 0) limit 1) >= 3, true, 'total count for pagination');
select tests.eq((select count(*) from public.admin_extension_queue('all', null, 1000, 0)) <= 100, true, 'page size is capped at 100');
select tests.eq((select count(*) from public.admin_extension_queue('all', 'kuyr')), 1::bigint, 'case-insensitive name search');
select tests.eq((select count(*) from public.admin_extension_queue('all', '%')), 0::bigint, 'wildcards are escaped in search');
select tests.eq((select count(*) from public.admin_baby_lookup('e_%')), 1::bigint, 'underscore and percent match literally');
select tests.eq((select count(*) from public.admin_extension_queue('all', :'req_normal')), 1::bigint, 'search by request id');
select tests.expect_error($q$select * from public.admin_extension_queue('bogus')$q$, 'invalid status');
select tests.expect_error(format('select * from public.admin_extension_queue(%L, %L)', 'all', repeat('x', 61)), 'too long');

-- Decisions: expired cannot be approved, note required to reject, immutable result --------
select tests.eq(public.admin_decide_extension(:'req_late', 'approved', 'geç'), 'expired', 'expired request cannot be approved');
select tests.eq((select status from public.admin_extension_queue('expired') where request_id = :'req_late'), 'expired', 'expired stays read-only');
select tests.expect_error(format('select public.admin_decide_extension(%L, %L)', :'req_normal', 'rejected'), 'decision_note_required');
select tests.eq(public.admin_decide_extension(:'req_normal', 'approved', 'Hastane süreci'), 'approved', 'Super Admin approves with a note');
select tests.expect_error(format('select public.admin_decide_extension(%L, %L, %L)', :'req_normal', 'rejected', 'tekrar'), 'immutable');
select tests.eq((select decided_by_name from public.admin_extension_queue('decided') where request_id = :'req_normal'), 'Operasyon', 'decider shown');
select tests.eq((select decision_note from public.admin_extension_queue('decided') where request_id = :'req_normal'), 'Hastane süreci', 'decision note shown');

-- Audit log: atomic with the decision, allow-listed details only ----------------------------
select tests.eq((select count(*) from public.admin_audit_log('extension_approved') a
                  where a.baby_id = '93000000-0000-4000-8000-000000000002'), 1::bigint, 'decision audited exactly once');
select tests.eq((select details ->> 'note' from public.admin_audit_log('extension_approved') a
                  where a.baby_id = '93000000-0000-4000-8000-000000000002'), 'Hastane süreci', 'audit keeps the decision note');
select tests.eq((select actor_name from public.admin_audit_log('extension_approved') a
                  where a.baby_id = '93000000-0000-4000-8000-000000000002'), 'Operasyon', 'audit names the actor');
select tests.eq((select count(*) from public.admin_audit_log(null, null, 100, 0) a where a.details ? 'uploader_id'), 0::bigint, 'audit hides non-allow-listed details');
select tests.eq((select count(*) from public.admin_audit_log(null, null, 100, 0) a where a.action = 'memory_created'), 0::bigint, 'audit is limited to lifecycle actions');
select tests.expect_error($q$select * from public.admin_audit_log('memory_created')$q$, 'invalid action');

-- Birth date: preview before confirm, audited correction, no new extension right -----------
select tests.eq((select would_lock from public.admin_preview_birth_date_correction('93000000-0000-4000-8000-000000000001', public.business_date_istanbul() - 400)),
                true, 'preview shows the profile would lock');
select tests.eq((select would_reopen from public.admin_preview_birth_date_correction(tests.id('defne'), public.business_date_istanbul() - 300)),
                true, 'preview shows a locked profile would reopen');
select tests.eq((select status_after from public.admin_preview_birth_date_correction(tests.id('defne'), public.business_date_istanbul() - 300)),
                'ACTIVE', 'preview shows the status after');
select tests.eq((select effective_close_after - base_close_after from public.admin_preview_birth_date_correction('93000000-0000-4000-8000-000000000002', public.business_date_istanbul() - 110)),
                20, 'preview keeps the approved extension');
select tests.eq((select birth_date from public.admin_baby_lookup(tests.id('defne')::text)), public.business_date_istanbul() - 400, 'preview changes nothing');
select tests.expect_error(format('select * from public.admin_preview_birth_date_correction(%L, %L)', tests.id('defne'), current_date + 10), 'invalid birth date');
select tests.expect_error($q$select * from public.admin_baby_lookup('K')$q$, 'search_too_short');
select tests.eq((select content_count from public.admin_baby_lookup('Kuyruk')), 0::bigint, 'lookup shows content count');
select tests.eq((select content_count from public.admin_baby_lookup(tests.id('defne')::text)) > 0, true, 'lookup by id');
select tests.eq((select status from public.admin_baby_lookup(tests.id('defne')::text)), 'LOCKED', 'lookup shows lifecycle status');

select tests.expect_error(
  format('select public.admin_correct_birth_date(%L, %L, %L)', '93000000-0000-4000-8000-000000000002', public.business_date_istanbul() - 110, ' '),
  'birth_date_reason_required');
select tests.eq(
  public.admin_correct_birth_date('93000000-0000-4000-8000-000000000002', public.business_date_istanbul() - 110, 'Nüfus kaydı'),
  public.business_date_istanbul() - 110,
  'console correction succeeds with a reason');
select tests.eq((select count(*) from public.admin_audit_log('birth_date_corrected') a
                  where a.baby_id = '93000000-0000-4000-8000-000000000002'), 1::bigint, 'correction audited');
select tests.eq((select details ->> 'reason' from public.admin_audit_log('birth_date_corrected') a
                  where a.baby_id = '93000000-0000-4000-8000-000000000002'), 'Nüfus kaydı', 'correction reason audited');
reset role;
select tests.logout();
select tests.eq((select count(*) from public.baby_extension_requests where baby_id = '93000000-0000-4000-8000-000000000002'), 1::bigint,
                'correction creates no second extension right');
select tests.eq((select status from public.baby_extension_requests where baby_id = '93000000-0000-4000-8000-000000000002'), 'approved',
                'correction keeps the decided extension');
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$select public.request_baby_extension('93000000-0000-4000-8000-000000000002', 5)$q$, 'already requested');

-- Kill switch -----------------------------------------------------------------------------
reset role;
select tests.logout();
update public.platform_flags set enabled = false, note = 'Faz 5 testi' where key = 'admin_console';
set role authenticated;
select tests.login(tests.id('baska'));
select tests.eq((select console_enabled from public.admin_session()), false, 'disabled console is reported');
select tests.expect_error($q$select * from public.admin_extension_queue()$q$, 'admin_console_disabled');
reset role;
select tests.logout();
update public.platform_flags set enabled = true, note = 'Faz 5 testi sonrası' where key = 'admin_console';

-- Role grants/revokes are audited; a revoked admin loses the console ------------------------
select tests.eq((select count(*) from public.platform_role_events
                  where user_id = '96000000-0000-4000-8000-000000000003' and event = 'granted'), 1::bigint, 'role grant audited');

-- Rate limit (second admin, so the rest of the suite is unaffected) -------------------------
set role authenticated;
select tests.login('96000000-0000-4000-8000-000000000003');
do $$
declare
  v_limited boolean := false;
begin
  for i in 1..250 loop
    begin
      perform count(*) from public.admin_audit_log(null, null, 1, 0);
    exception when others then
      if sqlerrm like '%rate limit%' then
        v_limited := true;
        exit;
      end if;
      raise;
    end;
  end loop;
  if not v_limited then
    raise exception 'FAIL console reads were never rate limited';
  end if;
  raise notice 'ok - console reads are rate limited per admin';
end $$;

reset role;
select tests.logout();
update public.platform_user_roles set revoked_at = now()
 where user_id = '96000000-0000-4000-8000-000000000003' and role = 'super_admin';
select tests.eq((select count(*) from public.platform_role_events
                  where user_id = '96000000-0000-4000-8000-000000000003' and event = 'revoked'), 1::bigint, 'role revoke audited');
set role authenticated;
select tests.login('96000000-0000-4000-8000-000000000003');
select tests.eq((select is_super_admin from public.admin_session()), false, 'revoked admin loses the role');
select tests.expect_error($q$select * from public.admin_extension_queue()$q$, 'not authorized');

reset role;
select tests.logout();
