-- Test helpers (plain SQL assertions, no pgTAP dependency).
create schema if not exists tests;
grant usage on schema tests to authenticated, anon, service_role;

create or replace function tests.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
$$;

create or replace function tests.expect_error(p_sql text, p_contains text default null) returns void
language plpgsql as $$
declare
  v_msg text;
  v_hint text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
    if p_contains is not null and position(p_contains in coalesce(v_msg, '') || ' ' || coalesce(v_hint, '')) = 0 then
      raise exception 'expected error containing "%" but got "%" (hint %) for: %', p_contains, v_msg, v_hint, p_sql;
    end if;
    raise notice 'ok - rejected (%): %', coalesce(p_contains, 'error'), left(regexp_replace(p_sql, '\s+', ' ', 'g'), 90);
    return;
  end;
  raise exception 'expected an error but statement succeeded: %', p_sql;
end;
$$;

create or replace function tests.count(p_sql text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into v;
  return v;
end;
$$;

create or replace function tests.eq(p_actual anyelement, p_expected anyelement, p_label text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice 'ok - %', p_label;
end;
$$;

grant execute on all functions in schema tests to authenticated, anon, service_role;

create or replace function tests.id(p_name text) returns uuid language sql immutable as $$
  select case p_name
    when 'anne'  then '11111111-1111-4111-8111-111111111111'
    when 'baba'  then '22222222-2222-4222-8222-222222222222'
    when 'teyze' then '33333333-3333-4333-8333-333333333333'
    when 'baska' then '44444444-4444-4444-8444-444444444444'
    when 'defne' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    when 'ege'   then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    when 'can'   then 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
  end::uuid;
$$;
grant execute on function tests.id(text) to authenticated, anon, service_role;

create or replace function tests.logout() returns void language sql as $$
  select set_config('request.jwt.claims', '', false);
$$;
grant execute on function tests.logout() to authenticated, anon, service_role;
