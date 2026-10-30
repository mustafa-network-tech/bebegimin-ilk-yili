-- Rollback of 20261029000200_plan_required_gate.sql.
-- Restores baby_access_state() without plan_required and drops family_accounts.plan_exempt.
begin;

drop trigger family_members_single_family_guard on public.family_members;
drop function public.family_members_single_family_guard();

drop function public.baby_access_state(uuid);

create function public.baby_access_state(p_baby_id uuid)
returns table (
  allowed boolean,
  reason text,
  is_parent boolean,
  family_account_id uuid,
  subscription_status text,
  plan_code text
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

  return query select
    public.baby_subscription_ok(p_baby_id),
    case
      when v_account is not null and public.family_account_has_test_access(v_account) then 'test_access'
      when not public.subscription_enforcement_enabled() then 'enforcement_off'
      when v_account is null then 'account_unmapped'
      when v_sub.status is null then 'no_subscription'
      when public.subscription_grants_access(v_sub.status, v_sub.current_period_end) then 'ok'
      when v_sub.status = 'past_due' then 'payment_issue'
      else 'subscription_ended'
    end,
    v_parent,
    v_account,
    v_sub.status::text,
    v_sub.plan_code::text;
end;
$$;

revoke all on function public.baby_access_state(uuid) from public, anon;
grant execute on function public.baby_access_state(uuid) to authenticated, service_role;

alter table public.family_accounts drop column plan_exempt;

commit;
