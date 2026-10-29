-- =====================================================================
-- Narrow the one-family-per-person guard to JOINING someone else's family.
--
-- 20261029000200 also stopped a Family Member from founding their own family
-- by adding a baby. That case is deliberately left as it was (decided later), so
-- the guard now only refuses entering a family the user did not found while
-- they already belong to another one. Founding a family is always allowed.
-- =====================================================================
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
  -- The founder's own family (create_baby makes the account just before this row).
  if exists (select 1 from public.family_accounts a where a.id = v_account and a.created_by = new.user_id) then
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
