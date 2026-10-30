-- Rollback of 20261029000300_single_family_guard_joins_only.sql: back to the
-- 20261029000200 guard (also refuses founding a second family).
begin;

create or replace function public.family_members_single_family_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
begin
  if auth.uid() is null then
    return new;
  end if;
  select fab.family_account_id into v_account
    from public.family_account_babies fab where fab.baby_id = new.baby_id;
  if v_account is null then
    return new;
  end if;
  if exists (
    select 1
      from public.family_members fm
      join public.family_account_babies fab on fab.baby_id = fm.baby_id
     where fm.user_id = new.user_id and fab.family_account_id <> v_account
  ) then
    raise exception 'already in another family' using errcode = 'P0001', hint = 'already_in_another_family';
  end if;
  return new;
end;
$$;

commit;
