-- =====================================================================
-- 006 Read models (timeline view) and privacy RPCs used by Edge Functions
-- =====================================================================

-- Unified, chronologically sortable timeline. security_invoker => the
-- caller's RLS policies on the underlying tables apply.
create or replace view public.timeline_entries
with (security_invoker = true)
as
  select 'memory'::text           as entry_type,
         m.id,
         m.baby_id,
         m.memory_date             as entry_date,
         m.memory_time             as entry_time,
         m.title,
         m.body,
         m.author_id,
         m.category,
         m.milestone_id,
         null::uuid                as milestone_type_id,
         m.include_in_book,
         m.created_at
  from public.memories m
  union all
  select 'milestone',
         ms.id,
         ms.baby_id,
         ms.achieved_on,
         ms.achieved_time,
         mt.title,
         ms.description,
         ms.created_by,
         'first',
         ms.id,
         ms.milestone_type_id,
         ms.include_in_book,
         ms.created_at
  from public.milestones ms
  join public.milestone_types mt on mt.id = ms.milestone_type_id
  union all
  select 'letter',
         l.id,
         l.baby_id,
         l.written_on,
         null::time,
         coalesce(nullif(l.title, ''), 'Mektup'),
         l.body,
         l.author_id,
         'letter',
         null::uuid,
         null::uuid,
         l.include_in_book,
         l.created_at
  from public.letters l;

revoke all on table public.timeline_entries from anon, authenticated;
grant select on table public.timeline_entries to authenticated, service_role;

-- Counts for the home screen / archive periods in one round trip.
create or replace function public.baby_stats(p_baby_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'memories',   (select count(*) from public.memories where baby_id = p_baby_id),
    'milestones', (select count(*) from public.milestones where baby_id = p_baby_id),
    'letters',    (select count(*) from public.letters where baby_id = p_baby_id),
    'photos',     (select count(*) from public.media where baby_id = p_baby_id and kind = 'photo' and status = 'ready'),
    'videos',     (select count(*) from public.media where baby_id = p_baby_id and kind = 'video' and status = 'ready'),
    'capsules',   (select count(*) from public.time_capsules where baby_id = p_baby_id)
  );
$$;

revoke all on function public.baby_stats(uuid) from public, anon;
grant execute on function public.baby_stats(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------
-- Privacy operations. Only the service role (Edge Function `privacy-actions`)
-- may call these; they return the storage objects that must be removed
-- through the Storage API.
-- ---------------------------------------------------------------------------------------

create or replace function public.baby_storage_objects(p_baby_id uuid)
returns table (bucket_id text, path text)
language sql
stable
security definer
set search_path = ''
as $$
  select 'baby-media', m.storage_path from public.media m where m.baby_id = p_baby_id
  union all
  select 'baby-media', m.thumb_path from public.media m where m.baby_id = p_baby_id and m.thumb_path is not null
  union all
  select 'baby-media', b.avatar_path from public.babies b where b.id = p_baby_id and b.avatar_path is not null
  union all
  select 'baby-media', b.cover_path from public.babies b where b.id = p_baby_id and b.cover_path is not null
  union all
  select 'baby-media', p_baby_id::text || '/capsules/' || c.id::text || '/photo.jpg'
    from public.time_capsules c where c.baby_id = p_baby_id and c.has_photo
  union all
  select 'books', e.storage_path from public.book_exports e where e.baby_id = p_baby_id;
$$;

create or replace function public.delete_baby_for_user(p_user uuid, p_baby_id uuid)
returns table (bucket_id text, path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.family_members
    where baby_id = p_baby_id and user_id = p_user and is_admin
  ) then
    raise exception 'only admins can delete a baby' using errcode = '42501';
  end if;
  -- storage paths are collected before the cascade removes the rows
  return query select * from public.baby_storage_objects(p_baby_id);
  delete from public.babies where id = p_baby_id;
end;
$$;

-- Prepares account deletion:
--  * babies where the user is the ONLY member are deleted completely,
--  * where the user is the last admin, the longest-standing member is promoted,
--  * optionally all content authored by the user is deleted,
--  * returns every storage object that must be removed.
create or replace function public.prepare_account_deletion(p_user uuid, p_delete_content boolean default false)
returns table (bucket_id text, path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  -- 1) promote a successor where the user is the last admin
  for r in
    select fm.baby_id
    from public.family_members fm
    where fm.user_id = p_user and fm.is_admin
      and not exists (select 1 from public.family_members o
                      where o.baby_id = fm.baby_id and o.is_admin and o.user_id <> p_user)
      and exists (select 1 from public.family_members o
                  where o.baby_id = fm.baby_id and o.user_id <> p_user)
  loop
    update public.family_members
       set is_admin = true,
           permissions = array(select key from public.permissions)
     where id = (select o.id from public.family_members o
                 where o.baby_id = r.baby_id and o.user_id <> p_user
                 order by (o.relation in ('anne', 'baba')) desc, o.joined_at asc
                 limit 1);
  end loop;

  -- 2) babies where the user is alone are deleted completely
  for r in
    select fm.baby_id
    from public.family_members fm
    where fm.user_id = p_user
      and not exists (select 1 from public.family_members o
                      where o.baby_id = fm.baby_id and o.user_id <> p_user)
  loop
    return query select * from public.baby_storage_objects(r.baby_id);
    delete from public.babies where id = r.baby_id;
  end loop;

  -- 3) optionally remove the user's own contributions from shared families
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

  -- 4) profile avatar
  return query select 'avatars'::text, p.avatar_path from public.profiles p
               where p.id = p_user and p.avatar_path is not null;
end;
$$;

revoke all on function public.baby_storage_objects(uuid),
  public.delete_baby_for_user(uuid, uuid),
  public.prepare_account_deletion(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.baby_storage_objects(uuid),
  public.delete_baby_for_user(uuid, uuid),
  public.prepare_account_deletion(uuid, boolean)
  to service_role;
