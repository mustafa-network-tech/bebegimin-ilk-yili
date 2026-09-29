-- The demo seed makes Defne 400 days old, i.e. LOCKED since Phase 3. The
-- permission / isolation / storage suites (10-60) exercise authorisation on
-- a WRITABLE archive, so Defne is moved to day 370: past her first birthday
-- but still inside the 375-day window. 70_lifecycle_mutation_lock_test.sql
-- locks her again and covers the read-only archive.
\set ON_ERROR_STOP 1
select tests.logout();
reset role;
update public.babies
   set birth_date = public.business_date_istanbul() - 370
 where id = tests.id('defne');
