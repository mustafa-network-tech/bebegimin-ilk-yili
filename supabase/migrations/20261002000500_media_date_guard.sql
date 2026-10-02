-- =====================================================================
-- media.taken_on gets the same date rule as memories / milestones / letters
-- (content_date_guard): not more than 310 days before the birth date and not
-- in the future (one day of time-zone slack). A wrong date could silently
-- move a photo out of the official outputs (decision P-1 cutoff) or into
-- the wrong chapter.
--
-- Order (plan 5.6): report first, then the rule. Existing rows are never
-- changed or deleted; admin_media_date_report() lists them for support.
-- The rule only runs when taken_on is written (INSERT or UPDATE OF
-- taken_on), so status changes of legacy rows keep working.
-- =====================================================================
begin;

-- 1) Report (Super Admin) ----------------------------------------------------------------------
create or replace function public.admin_media_date_report()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform public.assert_admin_console('read', 30);
  with bad as (
    select m.id, m.baby_id, m.taken_on,
           case when m.taken_on < b.birth_date - 310 then 'date_before_birth' else 'date_in_future' end as reason
      from public.media m
      join public.babies b on b.id = m.baby_id
     where m.taken_on < b.birth_date - 310
        or m.taken_on > current_date + 1
  )
  select jsonb_build_object(
    'media_out_of_range', (select count(*) from bad),
    'by_reason', coalesce((select jsonb_object_agg(r.reason, r.n)
                             from (select reason, count(*) as n from bad group by reason) r), '{}'::jsonb),
    'sample', coalesce((select jsonb_agg(jsonb_build_object('media_id', x.id, 'baby_id', x.baby_id,
                                                            'taken_on', x.taken_on, 'reason', x.reason)
                                         order by x.baby_id, x.taken_on)
                          from (select * from bad order by baby_id, taken_on limit 50) x), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_media_date_report() from public, anon;
grant execute on function public.admin_media_date_report() to authenticated, service_role;

-- 2) Rule ------------------------------------------------------------------------------------------
create or replace function public.content_date_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_birth date;
  v_date date;
begin
  select birth_date into v_birth from public.babies where id = new.baby_id;
  if tg_table_name = 'memories' then
    v_date := new.memory_date;
  elsif tg_table_name = 'milestones' then
    v_date := new.achieved_on;
  elsif tg_table_name = 'media' then
    v_date := new.taken_on;
  else
    v_date := new.written_on;
  end if;
  -- Pregnancy memories are allowed (up to ~10 months before birth);
  -- future dates are not (except timezone slack of one day).
  if v_date < v_birth - 310 then
    raise exception 'date is too far before the birth date' using errcode = '22023', hint = 'date_before_birth';
  end if;
  if v_date > current_date + 1 then
    raise exception 'date cannot be in the future' using errcode = '22023', hint = 'date_in_future';
  end if;
  return new;
end;
$$;

create trigger media_date_guard before insert or update of taken_on on public.media
  for each row execute function public.content_date_guard();

commit;
