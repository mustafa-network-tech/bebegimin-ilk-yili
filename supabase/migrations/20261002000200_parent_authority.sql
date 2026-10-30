-- =====================================================================
-- Parent authority (product decisions of 2026-10-02, GELISTIRME.MD
-- "Karar kaydı"):
--   P-3  only a parent may delete a baby; either parent alone.
--   P-5  admins are exactly Anne / Baba, with equal rights. No other
--        member can become an admin (invitation, sibling add, edit,
--        succession).
--   P-8  when a parent deletes the account the other parent stays the
--        admin; a parent seat is only filled through a parent.
--   P-9  no parent can remove or demote the other parent. A parent's
--        membership ends only by their own will (leave / delete account)
--        or through an audited trusted (service / support) path.
--   P-10 a parent who would leave a baby without a parent admin (or the
--        only member of a baby) cannot delete the account; the babies
--        must be deleted first. Babies are never deleted implicitly.
--
-- Legacy data: non-parent admins are turned into regular members with an
-- audit row, except where no parent admin exists (the baby would be left
-- without an admin); those are reported by admin_parent_authority_report().
-- Permissions arrays are left unchanged.
-- =====================================================================
begin;

-- 1) Legacy non-parent admins -> regular members (audited) ---------------------------------
-- Idempotent; trusted operations can re-run it after resolving reported cases.
create or replace function public.revoke_non_parent_admins()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with demoted as (
    update public.family_members fm
       set is_admin = false
     where fm.is_admin
       and fm.relation not in ('anne', 'baba')
       and exists (select 1 from public.family_members p
                    where p.baby_id = fm.baby_id and p.is_admin and p.relation in ('anne', 'baba'))
    returning fm.id, fm.baby_id, fm.user_id, fm.relation
  ), logged as (
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    select d.baby_id, null, 'member_admin_revoked', 'family_member', d.id,
           jsonb_build_object('user_id', d.user_id, 'relation', d.relation,
                              'reason', 'P-5: only Anne or Baba can be an admin')
      from demoted d
    returning 1
  )
  select count(*) into v_count from logged;
  return v_count;
end;
$$;

revoke all on function public.revoke_non_parent_admins() from public, anon, authenticated;
grant execute on function public.revoke_non_parent_admins() to service_role;

select public.revoke_non_parent_admins();

-- 2) Membership guard -------------------------------------------------------------------------
-- Runs after family_members_guard (trigger names sort alphabetically), so
-- the existing escalation messages keep precedence.
create or replace function public.family_members_parent_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_old_parent boolean := false;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_old_parent := old.is_admin and old.relation in ('anne', 'baba');
  end if;

  if v_actor is not null then
    -- P-9: a parent leaves only by their own will.
    if tg_op = 'DELETE' and v_old_parent and old.user_id <> v_actor then
      raise exception 'a parent can only leave the family themselves' using errcode = '42501',
        hint = 'parent_protected';
    end if;
    -- P-9 / P-5: a parent's role cannot be changed through the API.
    if tg_op = 'UPDATE' and v_old_parent
       and (new.is_admin is distinct from old.is_admin or new.relation is distinct from old.relation) then
      raise exception 'a parent''s role cannot be changed' using errcode = '42501', hint = 'parent_protected';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  -- P-5 for every context: nobody new becomes a non-parent admin.
  if new.is_admin and new.relation not in ('anne', 'baba')
     and (tg_op = 'INSERT' or not old.is_admin or old.relation is distinct from new.relation) then
    raise exception 'only Anne or Baba can be an admin' using errcode = '42501', hint = 'admin_requires_parent';
  end if;

  -- Trusted contexts (service role, support, legal erasure, migrations).
  if v_actor is null then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    -- P-8: becoming a parent or an admin needs a parent.
    if ((new.relation in ('anne', 'baba') and old.relation not in ('anne', 'baba'))
        or (new.is_admin and not old.is_admin))
       and not public.is_baby_parent(new.baby_id) then
      raise exception 'only Anne or Baba can add a parent' using errcode = '42501', hint = 'not_parent';
    end if;
  end if;
  -- INSERTs only happen inside RPCs (create_baby, accept_invitation,
  -- add_member_from_sibling) which check the inviter / caller themselves.
  return new;
end;
$$;

revoke all on function public.family_members_parent_guard() from public, anon, authenticated;
grant execute on function public.family_members_parent_guard() to service_role;

create trigger family_members_parent_guard
  before insert or update or delete on public.family_members
  for each row execute function public.family_members_parent_guard();

-- 3) Invitation guard -------------------------------------------------------------------------
create or replace function public.family_invitations_parent_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.is_admin and new.relation not in ('anne', 'baba') then
    raise exception 'only Anne or Baba can be an admin' using errcode = '42501', hint = 'admin_requires_parent';
  end if;
  -- P-8: a parent seat is filled only through a parent (e.g. a parent who
  -- deleted the account returns with the remaining parent's approval).
  if new.relation in ('anne', 'baba') and auth.uid() is not null and not public.is_baby_parent(new.baby_id) then
    raise exception 'only Anne or Baba can invite a parent' using errcode = '42501', hint = 'not_parent';
  end if;
  return new;
end;
$$;

revoke all on function public.family_invitations_parent_guard() from public, anon, authenticated;
grant execute on function public.family_invitations_parent_guard() to service_role;

create trigger family_invitations_parent_guard
  before insert on public.family_invitations
  for each row execute function public.family_invitations_parent_guard();

-- 4) Sibling add: a parent relation needs a parent of the target baby ---------------------------
create or replace function public.add_member_from_sibling(
  p_target_baby_id uuid,
  p_user_id uuid,
  p_relation text,
  p_relation_label text default null,
  p_permissions text[] default '{view_memories,view_album,comment}',
  p_is_admin boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not public.is_baby_admin(p_target_baby_id) then
    raise exception 'only admins can add members directly' using errcode = '42501';
  end if;
  if (p_relation in ('anne', 'baba') or coalesce(p_is_admin, false)) and not public.is_baby_parent(p_target_baby_id) then
    raise exception 'only Anne or Baba can add a parent' using errcode = '42501', hint = 'not_parent';
  end if;
  -- the person must already share another baby that the caller administers
  if not exists (
    select 1
    from public.family_members mine
    join public.family_members theirs on theirs.baby_id = mine.baby_id
    where mine.user_id = auth.uid() and mine.is_admin
      and theirs.user_id = p_user_id
      and mine.baby_id <> p_target_baby_id
  ) then
    raise exception 'user is not in any of your other families' using errcode = '42501';
  end if;

  insert into public.family_members (baby_id, user_id, relation, relation_label, is_admin, permissions, invited_by)
  values (p_target_baby_id, p_user_id, p_relation, nullif(btrim(p_relation_label), ''), p_is_admin,
          coalesce(p_permissions, '{}'), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- 5) Baby deletion: parents only (P-3) ------------------------------------------------------------
create or replace function public.delete_baby_for_user(p_user uuid, p_baby_id uuid)
returns table (bucket_id text, path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.family_members
    where baby_id = p_baby_id and user_id = p_user and is_admin and relation in ('anne', 'baba')
  ) then
    raise exception 'only parents can delete a baby' using errcode = '42501', hint = 'not_parent';
  end if;
  -- storage paths are collected before the cascade removes the rows
  return query select * from public.baby_storage_objects(p_baby_id);
  delete from public.babies where id = p_baby_id;
end;
$$;

-- 6) Account deletion (P-8 / P-10) -----------------------------------------------------------------
--  * refused while the user is the only member of a baby, or its last
--    admin without another Anne / Baba: the babies must be deleted first;
--  * the other parent becomes the admin if (legacy) they are not yet;
--    a non-parent is never promoted;
--  * optionally all content authored by the user is deleted;
--  * returns every storage object that must be removed.
create or replace function public.prepare_account_deletion(p_user uuid, p_delete_content boolean default false)
returns table (bucket_id text, path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_successor public.family_members;
  v_account uuid;
begin
  if exists (
    select 1 from public.family_members fm
     where fm.user_id = p_user
       and (not exists (select 1 from public.family_members o
                         where o.baby_id = fm.baby_id and o.user_id <> p_user)
            or (fm.is_admin
                and not exists (select 1 from public.family_members o
                                 where o.baby_id = fm.baby_id and o.user_id <> p_user
                                   and (o.is_admin or o.relation in ('anne', 'baba')))))
  ) then
    raise exception 'delete the babies before deleting the account' using errcode = '55000',
      hint = 'delete_babies_first';
  end if;

  -- The other parent stays (or becomes) the admin.
  for r in
    select fm.baby_id
    from public.family_members fm
    where fm.user_id = p_user and fm.is_admin
      and not exists (select 1 from public.family_members o
                      where o.baby_id = fm.baby_id and o.is_admin and o.user_id <> p_user)
  loop
    update public.family_members o
       set is_admin = true,
           permissions = array(select key from public.permissions)
     where o.id = (select x.id from public.family_members x
                    where x.baby_id = r.baby_id and x.user_id <> p_user and x.relation in ('anne', 'baba')
                    order by x.joined_at asc, x.id
                    limit 1)
    returning o.* into v_successor;
    select fab.family_account_id into v_account from public.family_account_babies fab where fab.baby_id = r.baby_id;
    if v_account is not null then
      perform public.family_account_activate_member(
        v_account, v_successor.user_id, true,
        coalesce(v_successor.relation_label, v_successor.relation), v_successor.invited_by);
    end if;
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (r.baby_id, null, 'member_admin_granted', 'family_member', v_successor.id,
            jsonb_build_object('user_id', v_successor.user_id, 'reason', 'P-8: the other parent stays the admin'));
  end loop;

  -- Optionally remove the user's own contributions from shared families.
  if p_delete_content then
    return query
      select 'baby-media'::text, m.storage_path from public.media m where m.uploader_id = p_user
      union all
      select 'baby-media'::text, m.thumb_path from public.media m where m.uploader_id = p_user and m.thumb_path is not null;
    delete from public.media where uploader_id = p_user;
    delete from public.memories where author_id = p_user;
    delete from public.letters where author_id = p_user;
    delete from public.comments where author_id = p_user;
    delete from public.milestones where created_by = p_user;
    delete from public.time_capsules where author_id = p_user;
  end if;

  -- Profile avatar.
  return query select 'avatars'::text, p.avatar_path from public.profiles p
               where p.id = p_user and p.avatar_path is not null;
end;
$$;

-- Babies that block the caller's account deletion (for the settings screen).
create or replace function public.account_deletion_blockers()
returns table (baby_id uuid, first_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select b.id, b.first_name
    from public.family_members fm
    join public.babies b on b.id = fm.baby_id
   where fm.user_id = auth.uid()
     and (not exists (select 1 from public.family_members o
                       where o.baby_id = fm.baby_id and o.user_id <> fm.user_id)
          or (fm.is_admin
              and not exists (select 1 from public.family_members o
                               where o.baby_id = fm.baby_id and o.user_id <> fm.user_id
                                 and (o.is_admin or o.relation in ('anne', 'baba')))))
   order by b.first_name, b.id;
$$;

revoke all on function public.account_deletion_blockers() from public, anon;
grant execute on function public.account_deletion_blockers() to authenticated, service_role;

-- 7) Report for the remaining legacy cases (Super Admin) ------------------------------------------
create or replace function public.admin_parent_authority_report()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform public.assert_admin_console('read', 30);
  select jsonb_build_object(
    -- Kept because the baby has no parent admin; needs a support decision.
    'non_parent_admins', coalesce((
      select jsonb_agg(jsonb_build_object('baby_id', fm.baby_id, 'member_id', fm.id, 'relation', fm.relation)
                       order by fm.baby_id, fm.id)
        from public.family_members fm
       where fm.is_admin and fm.relation not in ('anne', 'baba')), '[]'::jsonb),
    -- Anne / Baba members without admin rights (not counted as parents).
    'parents_without_admin', coalesce((
      select jsonb_agg(jsonb_build_object('baby_id', fm.baby_id, 'member_id', fm.id, 'relation', fm.relation)
                       order by fm.baby_id, fm.id)
        from public.family_members fm
       where not fm.is_admin and fm.relation in ('anne', 'baba')), '[]'::jsonb),
    'babies_without_parent_admin', coalesce((
      select jsonb_agg(b.id order by b.id)
        from public.babies b
       where not exists (select 1 from public.family_members fm
                          where fm.baby_id = b.id and fm.is_admin and fm.relation in ('anne', 'baba'))), '[]'::jsonb),
    'admins_revoked', (select count(*) from public.activity_logs a where a.action = 'member_admin_revoked')
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_parent_authority_report() from public, anon;
grant execute on function public.admin_parent_authority_report() to authenticated, service_role;

commit;
