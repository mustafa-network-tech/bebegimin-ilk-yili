-- Phase 13: catalog-wide security audit. Fails when a future migration
-- forgets RLS, opens a table or function to anon, adds a SECURITY DEFINER
-- function without a fixed search_path, or widens client write access.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
reset role;
select tests.logout();

select tests.eq((select coalesce(string_agg(c.relname, ','), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity), '',
                'every public table has row level security');

select tests.eq((select count(*) from information_schema.role_table_grants
                  where grantee = 'anon' and table_schema = 'public'), 0::bigint, 'anon has no table privilege at all');

select tests.eq((select coalesce(string_agg(p.proname, ',' order by p.proname), '') from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')), 'app_config',
                'anon can execute only app_config');

select tests.eq((select coalesce(string_agg(p.proname, ','), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.prosecdef
                    and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), '',
                'every SECURITY DEFINER function pins its search_path');

-- Client write surface: exactly these tables (everything else goes through RPCs).
select tests.eq((select string_agg(t, ',' order by t) from (
                   select table_name || ':' || string_agg(privilege_type, '+' order by privilege_type) as t
                     from information_schema.role_table_grants
                    where grantee = 'authenticated' and table_schema = 'public' and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
                    group by table_name) g),
                'babies:UPDATE,book_items:DELETE+INSERT+UPDATE,book_pages:DELETE+INSERT+UPDATE,book_projects:INSERT+UPDATE,'
                || 'comments:DELETE+INSERT+UPDATE,device_tokens:DELETE+INSERT+UPDATE,family_invitations:INSERT,'
                || 'family_members:DELETE+UPDATE,favorites:DELETE+INSERT,letters:DELETE+INSERT+UPDATE,'
                || 'media:DELETE+INSERT+UPDATE,memories:DELETE+INSERT+UPDATE,milestone_types:DELETE+INSERT+UPDATE,'
                || 'milestones:DELETE+INSERT+UPDATE,notifications:DELETE,profiles:UPDATE,time_capsules:DELETE',
                'authenticated write grants are exactly the reviewed set');

-- Service-only tables: no client privilege of any kind.
select tests.eq((select coalesce(string_agg(distinct table_name, ','), '') from information_schema.role_table_grants
                  where grantee = 'authenticated' and table_schema = 'public'
                    and table_name in ('archive_snapshots', 'output_projects', 'output_jobs', 'output_job_attempts',
                                       'output_artifacts', 'output_artifact_downloads', 'output_download_denials',
                                       'output_maintenance_runs', 'output_job_progress', 'book_render_manifests',
                                       'book_exports', 'film_render_manifests', 'film_job_progress', 'film_artifact_metadata',
                                       'html_artifact_metadata', 'artifact_download_permissions', 'billing_events',
                                       'platform_flags', 'platform_settings', 'legacy_grandfather_decisions',
                                       'admin_rate_limits', 'storage_cleanup_queue')), '',
                'pipeline, payment, audit and platform tables are service-only');

select tests.eq((select count(*) from storage.buckets where public), 0::bigint, 'no public storage bucket');
select tests.eq((select coalesce(string_agg(policyname, ','), '') from pg_policies
                  where schemaname = 'storage' and (qual like '%output-artifacts%' or with_check like '%output-artifacts%')
                    and cmd <> 'INSERT'), '', 'output artifacts are never readable through a Storage policy');
select tests.eq((select count(*) from pg_policies where schemaname = 'storage' and (qual like '%''books''%' or with_check like '%''books''%')),
                0::bigint, 'the legacy books bucket has no client policy');
select tests.eq((select coalesce(string_agg(c.relname, ','), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind = 'v'
                    and not coalesce('security_invoker=true' = any (c.reloptions), false)), '',
                'views run with the caller''s rights');
select tests.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname like 'admin\_%' and has_function_privilege('authenticated', p.oid, 'execute')
                    and not p.prosrc like '%assert_admin_console%'
                    -- admin_session only tells the caller whether they themselves are a Super Admin.
                    and p.proname not in ('admin_session')), 0::bigint,
                'every client-callable admin_* RPC goes through the console gate');
select tests.eq((select coalesce(string_agg(p.proname, ','), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname in ('platform_setting_int', 'legacy_content_included', 'output_jobs_quota',
                                                               'build_archive_snapshot_content', 'output_create_snapshot')
                    and has_function_privilege('authenticated', p.oid, 'execute')), '',
                'internal snapshot / settings helpers are not callable by clients');
