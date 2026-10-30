-- =====================================================================
-- Product decision P-6 (2026-10-02, GELISTIRME.MD "Karar kaydı"): only the
-- parents (Anne / Baba admins) may request the one-time lifecycle
-- extension. Before this, any baby member could consume the single,
-- irreversible request (UNIQUE (baby_id)) and lock the parents out of it.
--
--   * is_baby_parent(): internal helper, not callable by API roles.
--   * request_baby_extension(): non-parents are refused before the insert,
--     so a refused attempt never uses up the right.
--   * baby_lifecycle_summary(): can_request_extension is false for anyone
--     who is not a parent of the baby.
-- =====================================================================
begin;

-- P-5: the admins of a baby are exactly its Anne / Baba.
create or replace function public.is_baby_parent(p_baby_id uuid)
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
       and fm.is_admin
       and fm.relation in ('anne', 'baba')
  );
$$;

revoke all on function public.is_baby_parent(uuid) from public, anon, authenticated;
grant execute on function public.is_baby_parent(uuid) to service_role;

create or replace function public.request_baby_extension(p_baby_id uuid, p_days integer)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_birth_date date;
  v_request_id uuid;
  v_baby_name text;
begin
  if v_user is null or not public.is_baby_member(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if not public.is_baby_parent(p_baby_id) then
    raise exception 'only parents can request an extension' using errcode = '42501', hint = 'not_parent';
  end if;
  if p_days is null or p_days < 1 or p_days > 30 then
    raise exception 'requested_days must be between 1 and 30' using errcode = '22023';
  end if;

  select b.birth_date, b.first_name
    into v_birth_date, v_baby_name
    from public.babies b
   where b.id = p_baby_id
   for update;
  if v_birth_date is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  if public.business_date_istanbul() >= v_birth_date + 375 then
    raise exception 'extension can only be requested before base close' using errcode = '55000';
  end if;

  begin
    insert into public.baby_extension_requests (baby_id, requested_by, requested_days)
      values (p_baby_id, v_user, p_days)
      returning id into v_request_id;
  exception when unique_violation then
    raise exception 'extension already requested' using errcode = '23505';
  end;

  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (
      p_baby_id, v_user, 'extension_requested', 'baby_extension_request', v_request_id,
      jsonb_build_object('requested_days', p_days)
    );
  perform public.notify_family(
    p_baby_id, v_user, 'extension_requested',
    v_baby_name || ' için uzatma talebi oluşturuldu',
    p_days || ' günlük talep Super Admin değerlendirmesini bekliyor.',
    jsonb_build_object('request_id', v_request_id, 'requested_days', p_days),
    null,
    'extension_requested:' || v_request_id::text
  );
  return v_request_id;
end;
$$;

create or replace function public.baby_lifecycle_summary(p_baby_id uuid)
returns table (
  baby_id uuid,
  status text,
  business_date date,
  base_close_date date,
  effective_close_date date,
  remaining_days integer,
  extension_status text,
  approved_extension_days smallint,
  can_request_extension boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.business_date_istanbul();
  v_base date;
  v_extension_days smallint;
  v_effective date;
  v_extension_status text;
begin
  if not public.can_read_baby_lifecycle(p_baby_id) then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;

  v_base := public.baby_base_close_date(p_baby_id);
  v_extension_days := public.baby_approved_extension_days(p_baby_id);
  v_effective := v_base + v_extension_days::integer;
  select case
           when r.status = 'pending' and v_today >= v_base then 'expired'
           else r.status
         end
    into v_extension_status
    from public.baby_extension_requests r
   where r.baby_id = p_baby_id;

  return query
  select p_baby_id,
         case when v_today < v_effective then 'ACTIVE' else 'LOCKED' end,
         v_today,
         v_base,
         v_effective,
         greatest(v_effective - v_today, 0),
         v_extension_status,
         v_extension_days,
         v_today < v_base
           and public.is_baby_parent(p_baby_id)
           and not exists (
             select 1 from public.baby_extension_requests r where r.baby_id = p_baby_id
           );
end;
$$;

commit;
