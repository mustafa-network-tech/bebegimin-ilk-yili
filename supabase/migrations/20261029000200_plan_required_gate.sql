-- =====================================================================
-- Mandatory plan for new families.
--
-- A new account either joins an existing family (invitation) or picks a plan.
-- A parent whose family has never had a subscription cannot enter the app
-- until one is bought; the app routes them to the plans.
--   * family_accounts.plan_exempt : families that existed before this rule are
--       exempt (grandfathered); every later family starts with false.
--   * baby_access_state()         : new column plan_required = enforcement on,
--       account mapped, not exempt, no test access and no subscription row at
--       all. An ended / past-due subscription stays the readable renewal state.
-- Nothing changes while `subscription_enforcement` is off.
-- =====================================================================
begin;

alter table public.family_accounts add column plan_exempt boolean not null default false;
update public.family_accounts set plan_exempt = true;

drop function public.baby_access_state(uuid);

create function public.baby_access_state(p_baby_id uuid)
returns table (
  allowed boolean,
  reason text,
  is_parent boolean,
  family_account_id uuid,
  subscription_status text,
  plan_code text,
  plan_required boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_sub record;
  v_parent boolean;
  v_reason text;
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  v_parent := v_account is not null and public.family_account_is_parent(v_account);
  select s.status, s.plan_code, s.current_period_end into v_sub
    from public.subscriptions s
   where s.family_account_id = v_account
   order by public.subscription_grants_access(s.status, s.current_period_end) desc, s.updated_at desc
   limit 1;

  v_reason := case
    when v_account is not null and public.family_account_has_test_access(v_account) then 'test_access'
    when not public.subscription_enforcement_enabled() then 'enforcement_off'
    when v_account is null then 'account_unmapped'
    when v_sub.status is null then 'no_subscription'
    when public.subscription_grants_access(v_sub.status, v_sub.current_period_end) then 'ok'
    when v_sub.status = 'past_due' then 'payment_issue'
    else 'subscription_ended'
  end;

  return query select
    public.baby_subscription_ok(p_baby_id),
    v_reason,
    v_parent,
    v_account,
    v_sub.status::text,
    v_sub.plan_code::text,
    v_reason = 'no_subscription'
      and not coalesce((select a.plan_exempt from public.family_accounts a where a.id = v_account), true);
end;
$$;

revoke all on function public.baby_access_state(uuid) from public, anon;
grant execute on function public.baby_access_state(uuid) to authenticated, service_role;

-- One family per person --------------------------------------------------------------------------
-- A user either joins an existing family or founds their own (and buys its plan);
-- never both. Every way into a baby's circle (create_baby, accept_invitation,
-- add_member_from_sibling) inserts into family_members, so the rule lives here.
-- Trusted contexts (service role, support, migrations) are not restricted, and
-- people who already sit in several families keep what they have.
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

revoke all on function public.family_members_single_family_guard() from public, anon, authenticated;
grant execute on function public.family_members_single_family_guard() to service_role;

create trigger family_members_single_family_guard
  before insert on public.family_members
  for each row execute function public.family_members_single_family_guard();

commit;
