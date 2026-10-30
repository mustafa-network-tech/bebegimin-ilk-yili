-- =====================================================================
-- Google Play billing: verified purchases are reported by their real outcome.
--   1. A rejected delivery no longer turns every later delivery of the same
--      event id into 'duplicate'. billing_events / premium_order_events stay
--      append-only: each retry is its own row (`<id>#retry:<n>`, at most 5
--      attempts); applied or in-flight events are still never applied twice.
--   2. The verified-purchase RPCs re-read the stored subscription / order and
--      only report applied | duplicate | stale | duplicate_payment when access
--      or the entitlement really exists; otherwise 'inactive' (verified, but
--      expired / refunded) or 'rejected'.
--   3. Google Play: a checkout intent that expired AFTER the purchase began
--      (start time read from the Play Developer API) is still honoured, so a
--      delayed verification or restore after the 1-day intent window works.
-- Rollback: supabase/rollbacks/20261028000100_billing_event_retry.down.sql
-- No data is changed or deleted; only function bodies are replaced.
-- =====================================================================
begin;

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
  v_eid text := p_provider_event_id;
  v_tries integer;
  v_prev text;
  v_start timestamptz;
begin
  if p_provider is null or p_provider_event_id is null or p_event_type is null or p_payload is null then
    raise exception 'incomplete event' using errcode = '22023';
  end if;
  -- A rejected delivery may be re-verified (the store state or our catalog can
  -- change); the append-only history keeps every attempt as its own row. An
  -- applied (or in-flight) event is never applied twice.
  select count(*), (array_agg(e.result order by e.id desc))[1] into v_tries, v_prev
    from public.billing_events e
   where e.provider = p_provider
     and (e.provider_event_id = p_provider_event_id
          or starts_with(e.provider_event_id, p_provider_event_id || '#retry:'));
  if v_tries > 0 then
    if v_prev is distinct from 'rejected' then
      return 'duplicate';
    end if;
    if v_tries >= 5 then
      return 'rejected';
    end if;
    v_eid := p_provider_event_id || '#retry:' || v_tries;
  end if;
  insert into public.billing_events (provider, provider_event_id, event_type, payload)
  values (p_provider, v_eid, p_event_type, p_payload)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_event;
  if v_event is null then
    return 'duplicate';
  end if;

  begin
    v_start := nullif(p_payload ->> 'current_period_start', '')::timestamptz;
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
      -- An intent that expired after the purchase began is still honoured for
      -- Google Play: the start time comes from the Play Developer API and the
      -- obfuscated account id read back from Google names this very intent
      -- (restore / delayed verification). A consumed intent never reopens.
      if not (
        (v_intent.status = 'open' and v_intent.expires_at > now())
        or (p_provider = 'google_play' and v_intent.status in ('open', 'expired') and v_intent.consumed_at is null
            and v_start is not null and v_start <= v_intent.expires_at)
      ) then
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
  v_result text;
  v_sub public.subscriptions;
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
  v_result := public.billing_apply_event(p_provider, p_provider_event_id, 'client.verified_purchase', p_payload);
  if v_result not in ('applied', 'duplicate', 'stale') then
    return v_result; -- rejected: nothing was granted
  end if;
  -- Never report success from the event outcome alone: read the real state.
  select * into v_sub from public.subscriptions s
   where s.family_account_id = v_account and s.provider = p_provider
     and s.provider_subscription_id in (p_payload ->> 'provider_subscription_id',
                                        coalesce(p_payload ->> 'previous_provider_subscription_id', ''))
   limit 1;
  if v_sub.id is null then
    -- A stale / replaced token: the account's live subscription decides.
    select * into v_sub from public.subscriptions s
     where s.family_account_id = v_account and s.provider = p_provider
       and public.subscription_grants_access(s.status, s.current_period_end)
     order by s.last_event_at desc nulls last
     limit 1;
    if v_sub.id is null then
      return 'rejected';
    end if;
  end if;
  if not public.subscription_grants_access(v_sub.status, v_sub.current_period_end) then
    return 'inactive'; -- verified with the store, but no access to grant
  end if;
  return v_result;
end;
$$;

create or replace function public.premium_apply_event(
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
  v_order public.premium_orders;
  v_ref text := nullif(p_payload ->> 'provider_order_ref', '');
  v_bound text := nullif(p_payload ->> 'bound_order_id', '');
  v_claim text := nullif(p_payload ->> 'order_id', '');
  v_status text := p_payload ->> 'status';
  v_product_id uuid;
  v_inserted uuid;
  v_eid text := p_provider_event_id;
  v_tries integer;
  v_prev text;
begin
  if p_provider is null or p_provider_event_id is null or p_event_type is null or p_payload is null then
    raise exception 'incomplete event' using errcode = '22023';
  end if;
  -- A rejected delivery may be re-verified (the store state or our catalog can
  -- change); the append-only history keeps every attempt as its own row. An
  -- applied (or in-flight) event is never applied twice.
  select count(*), (array_agg(e.result order by e.id desc))[1] into v_tries, v_prev
    from public.premium_order_events e
   where e.provider = p_provider
     and (e.provider_event_id = p_provider_event_id
          or starts_with(e.provider_event_id, p_provider_event_id || '#retry:'));
  if v_tries > 0 then
    if v_prev is distinct from 'rejected' then
      return 'duplicate';
    end if;
    if v_tries >= 5 then
      return 'rejected';
    end if;
    v_eid := p_provider_event_id || '#retry:' || v_tries;
  end if;
  insert into public.premium_order_events (provider, provider_event_id, event_type, payload)
  values (p_provider, v_eid, p_event_type, p_payload)
  on conflict (provider, provider_event_id) do nothing
  returning id into v_event;
  if v_event is null then
    return 'duplicate';
  end if;

  begin
    if v_ref is null then
      raise exception 'provider_order_ref is required';
    end if;
    if v_status is null or v_status not in ('paid', 'pending', 'canceled', 'refunded', 'revoked') then
      raise exception 'unknown order status %', v_status;
    end if;
    if v_bound is not null and v_claim is not null and v_bound <> v_claim then
      raise exception 'store-bound order does not match the claimed order';
    end if;

    select * into v_order from public.premium_orders o
     where o.provider = p_provider and o.provider_order_ref = v_ref
     for update;
    if v_order.id is null then
      if coalesce(v_bound, v_claim) is null then
        raise exception 'unknown order';
      end if;
      select * into v_order from public.premium_orders o
       where o.id = coalesce(v_bound, v_claim)::uuid and o.provider = p_provider
       for update;
      if v_order.id is null then
        raise exception 'unknown order';
      end if;
      if v_order.provider_order_ref is not null and v_order.provider_order_ref <> v_ref then
        raise exception 'order already bound to another store transaction';
      end if;
    elsif coalesce(v_bound, v_claim) is not null and coalesce(v_bound, v_claim)::uuid <> v_order.id then
      raise exception 'store transaction belongs to another order';
    end if;

    -- Refund notifications (e.g. Google voided purchases) may not name the
    -- product; everything that grants must.
    if v_status = 'paid' or p_payload ? 'provider_product_id' then
      select pp.product_id into v_product_id
        from public.premium_product_provider_products pp
       where pp.provider = p_provider and pp.provider_product_id = p_payload ->> 'provider_product_id';
      if v_product_id is null or v_product_id <> v_order.product_id then
        raise exception 'product does not match the order';
      end if;
    end if;
    if (p_payload ? 'price_minor' and (p_payload ->> 'price_minor')::integer <> v_order.price_minor)
       or (p_payload ? 'currency' and p_payload ->> 'currency' <> v_order.currency) then
      raise exception 'price or currency does not match the order';
    end if;

    if v_status = 'paid' then
      if v_order.status in ('refunded', 'revoked') then
        raise exception 'order was already refunded';
      end if;
      update public.premium_orders
         set status = 'paid', provider_order_ref = v_ref, paid_at = coalesce(paid_at, now())
       where id = v_order.id;
      insert into public.product_entitlements (family_account_id, baby_id, product_code, source_order_id)
      values (v_order.family_account_id, v_order.baby_id, v_order.product_code, v_order.id)
      on conflict (family_account_id, baby_id, product_code) where status = 'active' do nothing
      returning id into v_inserted;
      if v_inserted is null and not exists (
        select 1 from public.product_entitlements e where e.source_order_id = v_order.id and e.status = 'active'
      ) then
        -- A second payment for something already owned: never a second
        -- entitlement; flagged for a refund by operations.
        update public.premium_order_events
           set result = 'applied', order_id = v_order.id, error = 'duplicate payment: entitlement already active'
         where id = v_event;
        return 'duplicate_payment';
      end if;
    elsif v_status = 'pending' then
      update public.premium_orders set provider_order_ref = v_ref
       where id = v_order.id and provider_order_ref is null;
    elsif v_status = 'canceled' then
      update public.premium_orders set status = 'canceled', provider_order_ref = coalesce(provider_order_ref, v_ref)
       where id = v_order.id and status = 'pending';
    else
      update public.premium_orders set status = v_status, provider_order_ref = coalesce(provider_order_ref, v_ref)
       where id = v_order.id;
      update public.product_entitlements
         set status = 'revoked', revoked_at = now(), revoke_reason = v_status
       where source_order_id = v_order.id and status = 'active';
    end if;

    update public.premium_order_events set result = 'applied', order_id = v_order.id where id = v_event;
    return 'applied';
  exception when others then
    update public.premium_order_events set result = 'rejected', error = left(sqlerrm, 500) where id = v_event;
    return 'rejected';
  end;
end;
$$;

create or replace function public.premium_apply_verified_purchase(
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
  v_order public.premium_orders;
  v_result text;
begin
  select o.family_account_id into v_account from public.premium_orders o
   where o.provider = p_provider and o.provider_order_ref = p_payload ->> 'provider_order_ref';
  if v_account is null and coalesce(nullif(p_payload ->> 'bound_order_id', ''), nullif(p_payload ->> 'order_id', '')) is not null then
    select o.family_account_id into v_account from public.premium_orders o
     where o.id = coalesce(nullif(p_payload ->> 'bound_order_id', ''), p_payload ->> 'order_id')::uuid
       and o.provider = p_provider;
  end if;
  if v_account is null or not public.family_account_is_parent(v_account, p_user) then
    raise exception 'purchase does not belong to your family account' using errcode = '42501', hint = 'purchase_not_yours';
  end if;
  v_result := public.premium_apply_event(p_provider, p_provider_event_id, 'client.verified_purchase', p_payload);
  if v_result not in ('applied', 'duplicate', 'duplicate_payment') then
    return v_result; -- rejected: nothing was granted
  end if;
  if v_result = 'duplicate_payment' then
    return v_result; -- the baby already owns the product (flagged for a refund)
  end if;
  -- Never report success from the event outcome alone: read the real state.
  select * into v_order from public.premium_orders o
   where o.provider = p_provider and o.provider_order_ref = p_payload ->> 'provider_order_ref';
  if v_order.id is null
     and coalesce(nullif(p_payload ->> 'bound_order_id', ''), nullif(p_payload ->> 'order_id', '')) is not null then
    select * into v_order from public.premium_orders o
     where o.id = coalesce(nullif(p_payload ->> 'bound_order_id', ''), p_payload ->> 'order_id')::uuid
       and o.provider = p_provider;
  end if;
  if v_order.id is null or v_order.family_account_id <> v_account then
    return 'rejected';
  end if;
  if v_order.status = 'paid' and exists (
    select 1 from public.product_entitlements e where e.source_order_id = v_order.id and e.status = 'active'
  ) then
    return v_result;
  end if;
  return case when v_order.status in ('canceled', 'refunded', 'revoked') then 'inactive' else 'rejected' end;
end;
$$;

commit;
