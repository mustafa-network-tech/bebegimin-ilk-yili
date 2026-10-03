-- Small hardening after the 2026-10-02 review (D-3, D-4).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();

-- D-3: a client session cannot switch the legal-erasure bypass on.
set role authenticated;
select set_config('bebegimin.legal_erasure', 'on', false);
select tests.eq(public.legal_erasure_active(), false, 'a client role setting the switch itself gets false');
reset role;
select tests.eq(public.legal_erasure_active(), true, 'trusted context with the switch on (as inside the erasure trigger)');
select set_config('bebegimin.legal_erasure', '', false);
select tests.eq(public.legal_erasure_active(), false, 'off again');

-- D-4: the daily job runs on the Istanbul business date by default.
select tests.eq(pg_get_function_arguments('public.run_daily_jobs(date)'::regprocedure),
                'p_today date DEFAULT business_date_istanbul()', 'run_daily_jobs defaults to the Istanbul business date');
