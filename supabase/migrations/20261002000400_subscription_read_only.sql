-- =====================================================================
-- Decision P-2 (2026-10-02, GELISTIRME.MD "Karar kaydı"): when the family
-- subscription is not active the archive is READ-ONLY for the whole family
-- (Family Members included). Phase 6 closed reads too and sent everybody to
-- the payment page.
--
--   * has_baby_permission(): the view permissions (view_memories,
--     view_album) no longer need the subscription; every write permission
--     still does (member management stays open as before).
--   * media: uploaders read their own rows as members (no subscription).
--   * Storage: signed URLs for archive media / opened capsule photos are
--     readable again; uploads and deletes still need the subscription.
--   * Unchanged: lifecycle_source_guard (no source write without the
--     subscription), Storage write / delete, premium purchase / render /
--     download (plan 2.7), lifecycle. baby_access_state().allowed keeps
--     meaning "the family may write"; the app shows a read-only archive.
-- =====================================================================
begin;

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
  and (p_permission in ('manage_members', 'invite_members', 'view_memories', 'view_album')
       or public.baby_subscription_ok(p_baby_id));
$$;

drop policy "album viewers can read ready media, uploaders their own" on public.media;
create policy "album viewers can read ready media, uploaders their own"
  on public.media for select to authenticated
  using (
    (status = 'ready' and public.has_baby_permission(baby_id, 'view_album'))
    or (uploader_id = auth.uid() and public.is_baby_member(baby_id))
  );

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

commit;
