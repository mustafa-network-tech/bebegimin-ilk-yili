-- =====================================================================
-- Web admin RPC return-type compatibility.
--
-- Supabase Auth stores auth.users.email as character varying while the
-- public admin contract intentionally exposes it as text. PL/pgSQL table
-- returns require the RETURN QUERY tuple descriptor to match exactly, so
-- cast the managed Auth value at the boundary. The authorization gate,
-- kill switch and per-admin rate limit remain unchanged.
-- =====================================================================
begin;

create or replace function public.admin_users_families(
  p_search text default null,
  p_status text default 'all',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  email text,
  display_name text,
  user_created_at timestamptz,
  family_count bigint,
  families jsonb,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pattern text;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  perform public.assert_admin_console('read', 120);
  if p_status is null or p_status not in ('all', 'with_family', 'without_family') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;
  v_pattern := public.admin_search_pattern(p_search);

  return query
  with users as (
    select u.id, u.email::text as email, p.display_name, u.created_at,
           count(distinct fam.family_account_id) filter (where fam.status <> 'removed') as family_count,
           coalesce(jsonb_agg(distinct jsonb_build_object(
             'id', fa.id,
             'display_name', fa.display_name,
             'account_status', fa.status,
             'member_role', fam.role,
             'member_status', fam.status,
             'baby_count', (select count(*) from public.family_account_babies fab where fab.family_account_id = fa.id)
           )) filter (where fa.id is not null), '[]'::jsonb) as families
      from auth.users u
      left join public.profiles p on p.id = u.id
      left join public.family_account_members fam on fam.user_id = u.id
      left join public.family_accounts fa on fa.id = fam.family_account_id
     where v_pattern is null
        or coalesce(u.email, '') ilike v_pattern escape '\'
        or coalesce(p.display_name, '') ilike v_pattern escape '\'
        or u.id::text = btrim(p_search)
     group by u.id, u.email, p.display_name, u.created_at
  ), filtered as (
    select * from users u
     where p_status = 'all'
        or (p_status = 'with_family' and u.family_count > 0)
        or (p_status = 'without_family' and u.family_count = 0)
  )
  select f.id, f.email, f.display_name, f.created_at, f.family_count, f.families, count(*) over ()
    from filtered f
   order by f.created_at desc, f.id
   limit v_limit offset v_offset;
end;
$$;

revoke all on function public.admin_users_families(text, text, integer, integer)
  from public, anon;
grant execute on function public.admin_users_families(text, text, integer, integer)
  to authenticated, service_role;

commit;
