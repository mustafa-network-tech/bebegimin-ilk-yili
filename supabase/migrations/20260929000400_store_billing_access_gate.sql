-- =====================================================================
-- Phase 6 follow-up (product decisions of 2026-09-29):
--   1. Payment provider: App Store / Google Play in-app subscriptions.
--   2. When the family subscription is not active, nobody in that family
--      (parents and Family Members) can use the archive; the app sends them
--      to the payment page. Enforced on the server (RLS, write guards,
--      Storage), switched on with the `subscription_enforcement` flag once
--      the store products are live.
--
-- Store binding: the app passes the parent's checkout intent id as Apple
-- `appAccountToken` / Google `obfuscatedAccountId`; the server only trusts
-- the value it reads back from the store (bound_intent_id).
-- Lifecycle and entitlements are never changed by any of this.
-- =====================================================================
begin;

-- Store product mapping (placeholder ids; replace with the ids configured in
-- App Store Connect / Play Console through a later migration).
-- App Store: one product per plan and period, same subscription group.
-- Google Play: <productId>:<basePlanId>.
insert into public.subscription_plan_provider_products (provider, provider_product_id, plan_id)
select 'app_store', 'bebegimin.' || p.code || '.' || p.billing_period, p.id
  from public.subscription_plans p where p.version = 1
on conflict do nothing;
insert into public.subscription_plan_provider_products (provider, provider_product_id, plan_id)
select 'google_play', p.code || ':' || p.billing_period, p.id
  from public.subscription_plans p where p.version = 1
on conflict do nothing;

alter table public.subscriptions add column last_event_at timestamptz;

-- Store product ids of the current catalog (the app shows the store's
-- localized price next to the catalog price).
create or replace function public.subscription_store_products(p_provider text)
returns table (plan_code text, billing_period text, provider_product_id text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.code, p.billing_period, pp.provider_product_id
    from public.current_subscription_plans() p
    join public.subscription_plan_provider_products pp on pp.plan_id = p.id and pp.provider = p_provider
   order by p.max_family_members, p.billing_period;
$$;

revoke all on function public.subscription_store_products(text) from public, anon;
grant execute on function public.subscription_store_products(text) to authenticated, service_role;

-- Checkout per store ----------------------------------------------------------------------
drop function public.request_subscription_checkout(uuid, text, text);

create or replace function public.request_subscription_checkout(
  p_family_account_id uuid,
  p_plan_code text,
  p_billing_period text,
  p_provider text default null
)
returns table (
  intent_id uuid,
  provider text,
  provider_product_id text,
  plan_code text,
  billing_period text,
  price_minor integer,
  currency text,
  max_family_members integer,
  active_family_members integer,
  would_exceed_capacity boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := coalesce(p_provider, public.billing_active_provider());
  v_plan public.subscription_plans;
  v_product text;
  v_intent uuid;
  v_active integer;
begin
  if auth.uid() is null or not public.family_account_is_parent(p_family_account_id) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if v_provider not in ('mock', 'app_store', 'google_play') then
    raise exception 'unknown provider' using errcode = '22023';
  end if;
  select * into v_plan from public.current_subscription_plans() p
   where p.code = p_plan_code and p.billing_period = p_billing_period;
  if not found then
    raise exception 'unknown plan' using errcode = '22023';
  end if;
  select pp.provider_product_id into v_product
    from public.subscription_plan_provider_products pp
   where pp.provider = v_provider and pp.plan_id = v_plan.id;
  if v_product is null then
    raise exception 'plan is not sold by this provider' using errcode = '55000';
  end if;
  v_active := public.family_account_active_member_count(p_family_account_id);

  insert into public.subscription_checkout_intents (family_account_id, requested_by, plan_id, provider, price_minor, currency)
  values (p_family_account_id, auth.uid(), v_plan.id, v_provider, v_plan.price_minor, v_plan.currency)
  returning id into v_intent;

  return query select v_intent, v_provider, v_product, v_plan.code, v_plan.billing_period,
                      v_plan.price_minor, v_plan.currency, v_plan.max_family_members::integer, v_active,
                      v_active > v_plan.max_family_members;
end;
$$;

revoke all on function public.request_subscription_checkout(uuid, text, text, text) from public, anon;
grant execute on function public.request_subscription_checkout(uuid, text, text, text) to authenticated, service_role;

-- Provider event projection (extended) --------------------------------------------------------
-- Additional normalised payload fields:
--   bound_intent_id                   intent id read back from the store receipt
--   previous_provider_subscription_id Google linkedPurchaseToken (plan change)
--   event_time                        provider signing time; older events never
--                                     overwrite newer state
create or replace function public.billing_apply_event(
  p_provider text,
  p_provider_event_id text,
  p_event_type text,
  p_payload jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event bigint;
  v_status text;
  v_plan public.subscription_plans;
  v_sub public.subscriptions;
  v_intent public.subscription_checkout_intents;
  v_account uuid;
  v_sub_ext text := nullif(p_payload ->> 'provider_subscription_id', '');
  v_prev_ext text := nullif(p_payload ->> 'previous_provider_subscription_id', '');
  v_intent_id text := coalesce(nullif(p_payload ->> 'bound_intent_id', ''), nullif(p_payload ->> 'checkout_intent_id', ''));
  v_event_time timestamptz := nullif(p_payload ->> 'event_time', '')::timestamptz;
begin
  if p_provider is null or p_provider_event_id is null or p_event_type is null or p_payload is null then
    raise exception 'incomplete event' using errcode = '22023';
  end if;
  insert into public.billing_events (provider, provider_event_id, event_type, payload)
  values (p_provider, p_provider_event_id, p_event_type, p_payload)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_event;
  if v_event is null then
    return 'duplicate';
  end if;

  begin
    if v_sub_ext is null then
      raise exception 'provider_subscription_id is required';
    end if;
    if nullif(p_payload ->> 'bound_intent_id', '') is not null
       and nullif(p_payload ->> 'checkout_intent_id', '') is not null
       and p_payload ->> 'bound_intent_id' <> p_payload ->> 'checkout_intent_id' then
      raise exception 'store-bound account does not match the checkout intent';
    end if;
    v_status := case p_payload ->> 'status'
      when 'trialing' then 'trialing'
      when 'active' then 'active'
      when 'in_grace_period' then 'grace'
      when 'grace' then 'grace'
      when 'past_due' then 'past_due'
      when 'canceled' then 'canceled'
      when 'cancelled' then 'canceled'
      when 'expired' then 'expired'
    end;
    if v_status is null then
      raise exception 'unknown provider status %', p_payload ->> 'status';
    end if;
    select p.* into v_plan
      from public.subscription_plan_provider_products pp
      join public.subscription_plans p on p.id = pp.plan_id
     where pp.provider = p_provider and pp.provider_product_id = p_payload ->> 'provider_product_id';
    if not found then
      raise exception 'unknown provider product';
    end if;

    select * into v_sub from public.subscriptions s
     where s.provider = p_provider and s.provider_subscription_id = v_sub_ext
     for update;
    if v_sub.id is null and v_prev_ext is not null then
      select * into v_sub from public.subscriptions s
       where s.provider = p_provider and s.provider_subscription_id = v_prev_ext
       for update;
    end if;

    if v_intent_id is not null then
      select * into v_intent from public.subscription_checkout_intents i
       where i.id = v_intent_id::uuid and i.provider = p_provider
       for update;
      if not found then
        raise exception 'unknown checkout intent';
      end if;
    end if;

    if v_sub.id is null then
      if v_intent.id is null then
        raise exception 'a checkout intent is required for a new subscription';
      end if;
      if v_intent.status <> 'open' or v_intent.expires_at <= now() then
        raise exception 'checkout intent is not open';
      end if;
      if v_intent.plan_id <> v_plan.id then
        raise exception 'product does not match the checkout intent';
      end if;
      if nullif(p_payload ->> 'family_account_id', '') is not null
         and (p_payload ->> 'family_account_id')::uuid <> v_intent.family_account_id then
        raise exception 'family account mismatch';
      end if;
      v_account := v_intent.family_account_id;
      insert into public.subscriptions (family_account_id, plan_id, plan_code, billing_period, status, provider,
                                        provider_customer_id, provider_subscription_id, current_period_start,
                                        current_period_end, cancel_at_period_end, last_event_at)
      values (v_account, v_plan.id, v_plan.code, v_plan.billing_period, v_status, p_provider,
              p_payload ->> 'provider_customer_id', v_sub_ext,
              (p_payload ->> 'current_period_start')::timestamptz, (p_payload ->> 'current_period_end')::timestamptz,
              coalesce((p_payload ->> 'cancel_at_period_end')::boolean, false), coalesce(v_event_time, now()))
      returning * into v_sub;
      update public.subscription_checkout_intents set status = 'consumed', consumed_at = now() where id = v_intent.id;
    else
      v_account := v_sub.family_account_id;
      if (v_intent.id is not null and v_intent.family_account_id <> v_account)
         or (nullif(p_payload ->> 'family_account_id', '') is not null
             and (p_payload ->> 'family_account_id')::uuid <> v_account) then
        raise exception 'family account mismatch';
      end if;
      if v_event_time is not null and v_sub.last_event_at is not null and v_event_time < v_sub.last_event_at then
        -- Out-of-order delivery: keep the newer state.
        update public.billing_events set result = 'applied', family_account_id = v_account, subscription_id = v_sub.id,
                                         error = 'stale event ignored'
         where id = v_event;
        return 'stale';
      end if;
      update public.subscriptions
         set plan_id = v_plan.id, plan_code = v_plan.code, billing_period = v_plan.billing_period,
             status = v_status,
             provider_subscription_id = v_sub_ext,
             provider_customer_id = coalesce(p_payload ->> 'provider_customer_id', provider_customer_id),
             current_period_start = coalesce((p_payload ->> 'current_period_start')::timestamptz, current_period_start),
             current_period_end = coalesce((p_payload ->> 'current_period_end')::timestamptz, current_period_end),
             cancel_at_period_end = coalesce((p_payload ->> 'cancel_at_period_end')::boolean, cancel_at_period_end),
             last_event_at = greatest(coalesce(v_event_time, now()), coalesce(last_event_at, v_event_time, now()))
       where id = v_sub.id
      returning * into v_sub;
      if v_intent.id is not null and v_intent.status = 'open' then
        update public.subscription_checkout_intents set status = 'consumed', consumed_at = now() where id = v_intent.id;
      end if;
    end if;

    perform public.family_account_refresh_capacity(v_account);
    update public.billing_events set result = 'applied', family_account_id = v_account, subscription_id = v_sub.id
     where id = v_event;
    return 'applied';
  exception when others then
    update public.billing_events set result = 'rejected', error = left(sqlerrm, 500) where id = v_event;
    return 'rejected';
  end;
end;
$$;

-- A purchase verified by the store on behalf of a signed-in user (purchase
-- or restore from the app). The user must be a parent of the account the
-- purchase binds to; restoring someone else's subscription is refused.
create or replace function public.billing_apply_verified_purchase(
  p_user uuid,
  p_provider text,
  p_provider_event_id text,
  p_payload jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_intent_id text := coalesce(nullif(p_payload ->> 'bound_intent_id', ''), nullif(p_payload ->> 'checkout_intent_id', ''));
begin
  if p_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select s.family_account_id into v_account
    from public.subscriptions s
   where s.provider = p_provider
     and s.provider_subscription_id in (p_payload ->> 'provider_subscription_id',
                                        coalesce(p_payload ->> 'previous_provider_subscription_id', ''));
  if v_account is null and v_intent_id is not null then
    select i.family_account_id into v_account
      from public.subscription_checkout_intents i
     where i.id = v_intent_id::uuid and i.provider = p_provider;
  end if;
  if v_account is null or not public.family_account_is_parent(v_account, p_user) then
    raise exception 'purchase does not belong to your family account' using errcode = '42501', hint = 'purchase_not_yours';
  end if;
  return public.billing_apply_event(p_provider, p_provider_event_id, 'client.verified_purchase', p_payload);
end;
$$;

revoke all on function public.billing_apply_verified_purchase(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_apply_verified_purchase(uuid, text, text, jsonb) to service_role;

-- Access gate ------------------------------------------------------------------------------
-- Access needs a subscription in trialing / active / grace whose period has
-- not visibly ended (a day of slack for late store notifications).
-- past_due (billing retry after grace), canceled and expired do not grant access.
create or replace function public.subscription_grants_access(p_status text, p_period_end timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_status = 'grace'
      or (p_status in ('trialing', 'active')
          and (p_period_end is null or p_period_end > now() - interval '1 day'));
$$;

create or replace function public.subscription_enforcement_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select f.enabled from public.platform_flags f where f.key = 'subscription_enforcement'), false);
$$;

create or replace function public.baby_subscription_ok(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.subscription_enforcement_enabled()
      or exists (
        select 1
          from public.family_account_babies fab
          join public.subscriptions s on s.family_account_id = fab.family_account_id
         where fab.baby_id = p_baby_id
           and public.subscription_grants_access(s.status, s.current_period_end)
      );
$$;

revoke all on function public.subscription_grants_access(text, timestamptz),
  public.subscription_enforcement_enabled(),
  public.baby_subscription_ok(uuid)
  from public, anon, authenticated;
grant execute on function public.subscription_grants_access(text, timestamptz),
  public.subscription_enforcement_enabled(),
  public.baby_subscription_ok(uuid)
  to service_role;

-- Content permissions require an active family subscription; family
-- management (members, invitations) stays available so parents can fix
-- capacity or leave.
create or replace function public.has_baby_permission(p_baby_id uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_members fm
    where fm.baby_id = p_baby_id
      and fm.user_id = auth.uid()
      and (fm.is_admin or p_permission = any (fm.permissions))
  )
  and (p_permission in ('manage_members', 'invite_members') or public.baby_subscription_ok(p_baby_id));
$$;

-- Policy helper: member of the baby AND the family subscription grants
-- access (false for non-members, so it is no oracle about other families).
create or replace function public.baby_member_with_access(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_baby_member(p_baby_id) and public.baby_subscription_ok(p_baby_id);
$$;

revoke all on function public.baby_member_with_access(uuid) from public, anon;
grant execute on function public.baby_member_with_access(uuid) to authenticated, service_role;

-- Uploaders saw their own (e.g. pending) media rows without a permission.
drop policy "album viewers can read ready media, uploaders their own" on public.media;
create policy "album viewers can read ready media, uploaders their own"
  on public.media for select to authenticated
  using (
    (status = 'ready' and public.has_baby_permission(baby_id, 'view_album'))
    or (uploader_id = auth.uid() and public.baby_member_with_access(baby_id))
  );

-- Writes: the shared source guard also requires the subscription (covers
-- author-owned update/delete policies that do not use has_baby_permission).
create or replace function public.lifecycle_source_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_baby uuid;
  v_new_baby uuid;
begin
  if tg_op = 'DELETE' then
    v_baby := old.baby_id;
  elsif tg_op = 'UPDATE' then
    v_baby := old.baby_id;
    v_new_baby := new.baby_id;
  else
    v_baby := new.baby_id;
  end if;

  if public.lifecycle_enforced_context() then
    if v_baby is not null and public.is_baby_member(v_baby) then
      if not public.baby_subscription_ok(v_baby) then
        raise exception 'an active family subscription is required' using errcode = '42501', hint = 'subscription_inactive';
      end if;
      perform public.assert_baby_source_writable(v_baby);
    end if;
    if v_new_baby is distinct from v_baby and v_new_baby is not null
       and public.is_baby_member(v_new_baby) then
      perform public.assert_baby_source_writable(v_new_baby);
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Storage: signed URLs and uploads need the subscription too (profile images
-- stay readable so the payment page can show the baby).
create or replace function public.can_read_baby_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby uuid := public.path_uuid(p_name, 1);
  v_second text := public.path_segment(p_name, 2);
  v_capsule uuid;
begin
  if v_baby is null or not public.is_baby_member(v_baby) then
    return false;
  end if;
  if v_second = 'profile' then
    return array_length(string_to_array(p_name, '/'), 1) = 3;
  end if;
  if not public.baby_subscription_ok(v_baby) then
    return false;
  end if;
  if v_second = 'capsules' then
    v_capsule := public.path_uuid(p_name, 3);
    return public.has_baby_permission(v_baby, 'view_memories') and exists (
      select 1 from public.time_capsules c
      where c.id = v_capsule and c.baby_id = v_baby and c.open_on <= current_date);
  end if;
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and (m.storage_path = p_name or m.thumb_path = p_name)
      and ((m.status = 'ready' and public.has_baby_permission(v_baby, 'view_album'))
           or m.uploader_id = auth.uid())
  );
end;
$$;

create or replace function public.can_write_baby_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby uuid := public.path_uuid(p_name, 1);
  v_second text := public.path_segment(p_name, 2);
  v_capsule uuid;
begin
  if v_baby is null or not public.baby_source_writable(v_baby) or not public.baby_subscription_ok(v_baby) then
    return false;
  end if;
  if v_second = 'profile' then
    return array_length(string_to_array(p_name, '/'), 1) = 3
       and public.has_baby_permission(v_baby, 'manage_baby');
  end if;
  if v_second = 'capsules' then
    v_capsule := public.path_uuid(p_name, 3);
    return public.path_segment(p_name, 4) = 'photo.jpg'
       and array_length(string_to_array(p_name, '/'), 1) = 4
       and exists (
         select 1 from public.time_capsules c
         where c.id = v_capsule and c.baby_id = v_baby and c.author_id = auth.uid()
           and c.has_photo and c.open_on > current_date
           and c.created_at > now() - interval '1 day');
  end if;
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and m.uploader_id = auth.uid()
      and m.status = 'uploading'
      and (m.storage_path = p_name or m.thumb_path = p_name)
      and public.is_baby_member(v_baby)
  );
end;
$$;

create or replace function public.can_delete_baby_object(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby uuid := public.path_uuid(p_name, 1);
  v_second text := public.path_segment(p_name, 2);
begin
  if v_baby is null or not public.baby_source_writable(v_baby) or not public.baby_subscription_ok(v_baby) then
    return false;
  end if;
  if v_second = 'profile' then
    return public.has_baby_permission(v_baby, 'manage_baby');
  end if;
  if v_second = 'capsules' then
    return exists (
      select 1 from public.time_capsules c
      where c.id = public.path_uuid(p_name, 3) and c.baby_id = v_baby
        and (c.author_id = auth.uid() or public.is_baby_admin(v_baby)));
  end if;
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and (m.uploader_id = auth.uid() or public.has_baby_permission(v_baby, 'manage_content'))
  );
end;
$$;

-- What the app shows for a baby: open, or the payment page (and why).
create or replace function public.baby_access_state(p_baby_id uuid)
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

commit;
