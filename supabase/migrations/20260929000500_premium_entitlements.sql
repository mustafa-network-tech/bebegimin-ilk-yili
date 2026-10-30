-- =====================================================================
-- Phase 7: premium one-time products, orders and baby-scoped entitlements.
--
--   * Catalog: first_year_book 34900 / first_year_html 44900 /
--     first_year_film 54900 TRY (kuruş), versioned and immutable; the only
--     source of premium prices. The physical book is not a catalog product.
--   * A purchase intent (order) needs: LOCKED baby, active parent of the
--     baby's family account, a subscription that grants access, the
--     storefront flag on, and no active entitlement yet.
--   * Entitlements belong to family_account + baby + product (never to the
--     purchaser); at most one active per triple. They are granted only by a
--     store-verified payment (App Store / Google Play / mock) and revoked by
--     verified refunds, all recorded append-only in premium_order_events.
--   * Lifecycle, subscription and entitlement stay independent: nothing
--     here changes the lifecycle, and a lapsed subscription never removes an
--     entitlement.
--   * Store products are consumables (a family may buy the same product for
--     each baby; see ADR 0003); the entitlement is the permanent record.
-- =====================================================================
begin;

insert into public.platform_flags (key, enabled, note)
values ('premium_storefront', false, 'Phase 7: premium purchase intents (turn on when store products are live).')
on conflict (key) do nothing;

-- Catalog ----------------------------------------------------------------------------------
create table public.premium_products (
  id              uuid primary key default gen_random_uuid(),
  code            text not null check (code in ('first_year_book', 'first_year_html', 'first_year_film')),
  version         integer not null default 1 check (version > 0),
  price_minor     integer not null check (price_minor > 0),
  currency        text not null default 'TRY' check (currency = 'TRY'),
  delivery_format text not null check (delivery_format in ('pdf', 'html_zip', 'mp4')),
  active_from     timestamptz not null default now(),
  active_until    timestamptz,
  created_at      timestamptz not null default now(),
  unique (code, version),
  check (active_until is null or active_until > active_from)
);

create or replace function public.premium_products_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.code, new.version, new.price_minor, new.currency, new.delivery_format)
     is distinct from (old.code, old.version, old.price_minor, old.currency, old.delivery_format) then
    raise exception 'catalog rows are immutable; add a new version' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger premium_products_guard
  before update on public.premium_products
  for each row execute function public.premium_products_guard();

insert into public.premium_products (code, price_minor, delivery_format) values
  ('first_year_book', 34900, 'pdf'),
  ('first_year_html', 44900, 'html_zip'),
  ('first_year_film', 54900, 'mp4');

create table public.premium_product_provider_products (
  provider            text not null check (provider ~ '^[a-z_]{2,30}$'),
  provider_product_id text not null check (char_length(provider_product_id) between 1 and 200),
  product_id          uuid not null references public.premium_products (id),
  primary key (provider, provider_product_id),
  unique (provider, product_id)
);

insert into public.premium_product_provider_products (provider, provider_product_id, product_id)
select v.provider, v.prefix || p.code, p.id
  from public.premium_products p
 cross join (values ('mock', 'mock.'), ('app_store', 'bebegimin.'), ('google_play', '')) as v(provider, prefix);

create or replace function public.current_premium_products()
returns setof public.premium_products
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (p.code) p.*
    from public.premium_products p
   where p.active_from <= now() and (p.active_until is null or p.active_until > now())
   order by p.code, p.version desc;
$$;

-- Orders, events, entitlements ---------------------------------------------------------------
create table public.premium_orders (
  id                 uuid primary key default gen_random_uuid(),
  family_account_id  uuid not null references public.family_accounts (id) on delete restrict,
  baby_id            uuid not null references public.babies (id) on delete restrict,
  product_id         uuid not null references public.premium_products (id),
  product_code       text not null,
  requested_by       uuid references auth.users (id) on delete set null,
  price_minor        integer not null,
  currency           text not null,
  provider           text not null,
  provider_order_ref text,
  status             text not null default 'pending'
                       check (status in ('pending', 'paid', 'canceled', 'refunded', 'revoked')),
  expires_at         timestamptz not null default now() + interval '1 day',
  paid_at            timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create unique index premium_orders_provider_ref_idx on public.premium_orders (provider, provider_order_ref)
  where provider_order_ref is not null;
create index premium_orders_baby_idx on public.premium_orders (baby_id, product_code, created_at desc);

create trigger premium_orders_set_updated_at
  before update on public.premium_orders
  for each row execute function public.set_updated_at();

create table public.premium_order_events (
  id                bigint generated always as identity primary key,
  provider          text not null,
  provider_event_id text not null,
  event_type        text not null,
  order_id          uuid,
  payload           jsonb not null,
  result            text check (result in ('applied', 'rejected')),
  error             text,
  received_at       timestamptz not null default now(),
  unique (provider, provider_event_id)
);

create trigger premium_order_events_append_only
  before update or delete on public.premium_order_events
  for each row execute function public.billing_events_append_only();

create table public.product_entitlements (
  id                uuid primary key default gen_random_uuid(),
  family_account_id uuid not null references public.family_accounts (id) on delete restrict,
  baby_id           uuid not null references public.babies (id) on delete restrict,
  product_code      text not null check (product_code in ('first_year_book', 'first_year_html', 'first_year_film')),
  source_order_id   uuid not null references public.premium_orders (id),
  status            text not null default 'active' check (status in ('active', 'revoked')),
  granted_at        timestamptz not null default now(),
  revoked_at        timestamptz,
  revoke_reason     text,
  check ((status = 'active') = (revoked_at is null))
);

create unique index product_entitlements_one_active_idx
  on public.product_entitlements (family_account_id, baby_id, product_code) where status = 'active';

-- Entitlements are never deleted; only a verified refund/revocation ends them.
create or replace function public.product_entitlements_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'entitlements are permanent records' using errcode = '42501';
  end if;
  if (new.family_account_id, new.baby_id, new.product_code, new.source_order_id, new.granted_at)
     is distinct from (old.family_account_id, old.baby_id, old.product_code, old.source_order_id, old.granted_at)
     or old.status = 'revoked' then
    raise exception 'entitlements are immutable except for revocation' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger product_entitlements_guard
  before update or delete on public.product_entitlements
  for each row execute function public.product_entitlements_guard();

-- RLS: service-only tables; clients read through RPCs.
alter table public.premium_products enable row level security;
alter table public.premium_product_provider_products enable row level security;
alter table public.premium_orders enable row level security;
alter table public.premium_order_events enable row level security;
alter table public.product_entitlements enable row level security;
revoke all on table public.premium_products, public.premium_product_provider_products, public.premium_orders,
  public.premium_order_events, public.product_entitlements from public, anon, authenticated;
grant all on table public.premium_products, public.premium_product_provider_products, public.premium_orders,
  public.premium_order_events, public.product_entitlements to service_role;

-- Purchase eligibility (plan 3.1.1): LOCKED + active parent + live subscription.
-- Returns null when allowed, otherwise the refusal hint.
create or replace function public.premium_purchase_block(p_baby_id uuid, p_user uuid default auth.uid())
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
begin
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null or not public.family_account_is_parent(v_account, p_user) then
    return 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    return 'premium_requires_locked';
  end if;
  if not exists (
    select 1 from public.subscriptions s
     where s.family_account_id = v_account
       and public.subscription_grants_access(s.status, s.current_period_end)
  ) then
    return 'subscription_required';
  end if;
  if not coalesce((select f.enabled from public.platform_flags f where f.key = 'premium_storefront'), false) then
    return 'storefront_closed';
  end if;
  return null;
end;
$$;

-- Storefront (parents of a LOCKED baby): products, prices, ownership.
create or replace function public.premium_storefront(p_baby_id uuid)
returns table (
  product_code text,
  price_minor integer,
  currency text,
  delivery_format text,
  owned boolean,
  purchase_block text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account uuid;
  v_block text;
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  if v_account is null or not public.family_account_is_parent(v_account) then
    raise exception 'only parents see the premium storefront' using errcode = '42501', hint = 'not_parent';
  end if;
  if coalesce(public.baby_lifecycle_active_internal(p_baby_id), true) then
    raise exception 'premium products open after the first year archive is locked'
      using errcode = '55000', hint = 'premium_requires_locked';
  end if;
  v_block := public.premium_purchase_block(p_baby_id);

  return query
  select p.code, p.price_minor, p.currency, p.delivery_format,
         exists (select 1 from public.product_entitlements e
                  where e.family_account_id = v_account and e.baby_id = p_baby_id
                    and e.product_code = p.code and e.status = 'active'),
         case when exists (select 1 from public.product_entitlements e
                            where e.family_account_id = v_account and e.baby_id = p_baby_id
                              and e.product_code = p.code and e.status = 'active')
              then 'already_owned' else v_block end
    from public.current_premium_products() p
   order by p.price_minor;
end;
$$;

-- Owned products of a baby, visible to every member of the family (Anne's
-- purchase shows up for Baba; download rights come in phase 12).
create or replace function public.baby_entitlements(p_baby_id uuid)
returns table (product_code text, status text, granted_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  return query
  select e.product_code, e.status, e.granted_at
    from public.product_entitlements e
    join public.family_account_babies fab on fab.baby_id = e.baby_id and fab.family_account_id = e.family_account_id
   where e.baby_id = p_baby_id and e.status = 'active'
   order by e.granted_at;
end;
$$;

-- Purchase intent: the order id travels to the store as appAccountToken /
-- obfuscatedAccountId and comes back in the verified receipt.
create or replace function public.request_premium_purchase(
  p_baby_id uuid,
  p_product_code text,
  p_provider text
)
returns table (
  order_id uuid,
  provider text,
  provider_product_id text,
  product_code text,
  price_minor integer,
  currency text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_block text;
  v_account uuid;
  v_product public.premium_products;
  v_store_id text;
  v_order uuid;
begin
  if auth.uid() is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if p_provider not in ('mock', 'app_store', 'google_play') then
    raise exception 'unknown provider' using errcode = '22023';
  end if;
  v_block := public.premium_purchase_block(p_baby_id);
  if v_block = 'not_parent' then
    raise exception 'only parents can buy premium products' using errcode = '42501', hint = v_block;
  elsif v_block is not null then
    raise exception 'premium purchase is not available' using errcode = '55000', hint = v_block;
  end if;

  select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = p_baby_id;
  perform 1 from public.family_accounts a where a.id = v_account for update;
  select * into v_product from public.current_premium_products() p where p.code = p_product_code;
  if not found then
    raise exception 'unknown product' using errcode = '22023';
  end if;
  if exists (select 1 from public.product_entitlements e
              where e.family_account_id = v_account and e.baby_id = p_baby_id
                and e.product_code = p_product_code and e.status = 'active') then
    raise exception 'already owned' using errcode = 'P0001', hint = 'already_owned';
  end if;
  select pp.provider_product_id into v_store_id
    from public.premium_product_provider_products pp
   where pp.provider = p_provider and pp.product_id = v_product.id;
  if v_store_id is null then
    raise exception 'product is not sold by this provider' using errcode = '55000';
  end if;

  insert into public.premium_orders (family_account_id, baby_id, product_id, product_code, requested_by,
                                     price_minor, currency, provider)
  values (v_account, p_baby_id, v_product.id, v_product.code, auth.uid(), v_product.price_minor, v_product.currency,
          p_provider)
  returning id into v_order;

  return query select v_order, p_provider, v_store_id, v_product.code, v_product.price_minor, v_product.currency;
end;
$$;

-- Verified store event -> order + entitlement projection (service role).
-- Payload (normalised by the provider adapter):
--   provider_order_ref (store transaction / order id), provider_product_id,
--   status: paid | pending | canceled | refunded | revoked,
--   [bound_order_id] (read back from the store), [order_id] (client claim),
--   [price_minor, currency] (checked against the order snapshot), [event_time]
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
begin
  if p_provider is null or p_provider_event_id is null or p_event_type is null or p_payload is null then
    raise exception 'incomplete event' using errcode = '22023';
  end if;
  insert into public.premium_order_events (provider, provider_event_id, event_type, payload)
  values (p_provider, p_provider_event_id, p_event_type, p_payload)
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

-- A store purchase verified on behalf of a signed-in user: only a parent of
-- the order's family account may bind it.
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
  return public.premium_apply_event(p_provider, p_provider_event_id, 'client.verified_purchase', p_payload);
end;
$$;

-- Which kind of store product is this? (routes receipts and notifications)
create or replace function public.store_product_kind(p_provider text, p_provider_product_id text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.premium_product_provider_products pp
                  where pp.provider = p_provider and pp.provider_product_id = p_provider_product_id) then 'premium'
    when exists (select 1 from public.subscription_plan_provider_products sp
                  where sp.provider = p_provider and sp.provider_product_id = p_provider_product_id) then 'subscription'
  end;
$$;

-- Store ids of the premium catalog (store-localized prices in the app).
create or replace function public.premium_store_products(p_provider text)
returns table (product_code text, provider_product_id text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.code, pp.provider_product_id
    from public.current_premium_products() p
    join public.premium_product_provider_products pp on pp.product_id = p.id and pp.provider = p_provider
   order by p.price_minor;
$$;

revoke all on function public.premium_products_guard(),
  public.product_entitlements_guard(),
  public.current_premium_products(),
  public.premium_purchase_block(uuid, uuid),
  public.premium_apply_event(text, text, text, jsonb),
  public.premium_apply_verified_purchase(uuid, text, text, jsonb),
  public.store_product_kind(text, text)
  from public, anon, authenticated;
grant execute on function public.current_premium_products(),
  public.premium_apply_event(text, text, text, jsonb),
  public.premium_apply_verified_purchase(uuid, text, text, jsonb),
  public.store_product_kind(text, text)
  to service_role;

revoke all on function public.premium_storefront(uuid),
  public.baby_entitlements(uuid),
  public.request_premium_purchase(uuid, text, text),
  public.premium_store_products(text)
  from public, anon;
grant execute on function public.premium_storefront(uuid),
  public.baby_entitlements(uuid),
  public.request_premium_purchase(uuid, text, text),
  public.premium_store_products(text)
  to authenticated, service_role;

commit;
