-- =====================================================================
-- 007 Private Storage buckets and object-level policies
--
-- Buckets are PRIVATE: files are only reachable through short-lived
-- signed URLs, and signing requires the SELECT policy below.
--
-- Path layout
--   baby-media : <baby_id>/<media_id>/<file>             photos & videos
--                <baby_id>/profile/<file>                 baby avatar / cover
--                <baby_id>/capsules/<capsule_id>/photo.jpg sealed capsule photo
--   books      : <baby_id>/<book_project_id>/<file>.pdf  generated books
--   avatars    : <user_id>/<file>                         user profile photos
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('baby-media', 'baby-media', false, 524288000,
   array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
         'video/mp4', 'video/quicktime', 'video/3gpp', 'video/webm', 'video/x-m4v']),
  ('books', 'books', false, 524288000, array['application/pdf']),
  ('avatars', 'avatars', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Safe path parsing ------------------------------------------------------------------
create or replace function public.path_uuid(p_name text, p_index integer)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case
    when (string_to_array(p_name, '/'))[p_index] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then ((string_to_array(p_name, '/'))[p_index])::uuid
  end;
$$;

create or replace function public.path_segment(p_name text, p_index integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select (string_to_array(p_name, '/'))[p_index];
$$;

-- baby-media ------------------------------------------------------------------------------
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
  if v_baby is null then
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
  -- media: the DB row (created first, status 'uploading') authorises the upload
  return exists (
    select 1 from public.media m
    where m.id = public.path_uuid(p_name, 2)
      and m.baby_id = v_baby
      and m.uploader_id = auth.uid()
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
  if v_baby is null then
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

-- books ---------------------------------------------------------------------------------------
create or replace function public.can_read_book_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.book_projects p
    where p.id = public.path_uuid(p_name, 2)
      and p.baby_id = public.path_uuid(p_name, 1)
      and (public.has_baby_permission(p.baby_id, 'view_album')
           or public.has_baby_permission(p.baby_id, 'create_book'))
  );
$$;

create or replace function public.can_write_book_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select array_length(string_to_array(p_name, '/'), 1) = 3
     and p_name like '%.pdf'
     and exists (
       select 1 from public.book_projects p
       where p.id = public.path_uuid(p_name, 2)
         and p.baby_id = public.path_uuid(p_name, 1)
         and public.has_baby_permission(p.baby_id, 'create_book')
     );
$$;

-- avatars ---------------------------------------------------------------------------------------
create or replace function public.can_read_avatar_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.path_uuid(p_name, 1) = auth.uid()
      or public.shares_baby_with(public.path_uuid(p_name, 1));
$$;

revoke all on function public.can_read_baby_object(text), public.can_write_baby_object(text),
  public.can_delete_baby_object(text), public.can_read_book_object(text),
  public.can_write_book_object(text), public.can_read_avatar_object(text)
  from public, anon;
grant execute on function public.can_read_baby_object(text), public.can_write_baby_object(text),
  public.can_delete_baby_object(text), public.can_read_book_object(text),
  public.can_write_book_object(text), public.can_read_avatar_object(text),
  public.path_uuid(text, integer), public.path_segment(text, integer)
  to authenticated, service_role;

-- Policies on storage.objects (RLS is always enabled on this table in Supabase) --------------------
drop policy if exists "bebegimin baby-media read" on storage.objects;
drop policy if exists "bebegimin baby-media insert" on storage.objects;
drop policy if exists "bebegimin baby-media update" on storage.objects;
drop policy if exists "bebegimin baby-media delete" on storage.objects;
drop policy if exists "bebegimin books read" on storage.objects;
drop policy if exists "bebegimin books insert" on storage.objects;
drop policy if exists "bebegimin books delete" on storage.objects;
drop policy if exists "bebegimin avatars read" on storage.objects;
drop policy if exists "bebegimin avatars insert" on storage.objects;
drop policy if exists "bebegimin avatars update" on storage.objects;
drop policy if exists "bebegimin avatars delete" on storage.objects;

create policy "bebegimin baby-media read" on storage.objects for select to authenticated
  using (bucket_id = 'baby-media' and public.can_read_baby_object(name));
create policy "bebegimin baby-media insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'baby-media' and public.can_write_baby_object(name));
create policy "bebegimin baby-media update" on storage.objects for update to authenticated
  using (bucket_id = 'baby-media' and public.can_write_baby_object(name))
  with check (bucket_id = 'baby-media' and public.can_write_baby_object(name));
create policy "bebegimin baby-media delete" on storage.objects for delete to authenticated
  using (bucket_id = 'baby-media' and public.can_delete_baby_object(name));

create policy "bebegimin books read" on storage.objects for select to authenticated
  using (bucket_id = 'books' and public.can_read_book_object(name));
create policy "bebegimin books insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'books' and public.can_write_book_object(name));
create policy "bebegimin books delete" on storage.objects for delete to authenticated
  using (bucket_id = 'books' and public.is_baby_admin(public.path_uuid(name, 1)));

create policy "bebegimin avatars read" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and public.can_read_avatar_object(name));
create policy "bebegimin avatars insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and public.path_uuid(name, 1) = auth.uid());
create policy "bebegimin avatars update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and public.path_uuid(name, 1) = auth.uid())
  with check (bucket_id = 'avatars' and public.path_uuid(name, 1) = auth.uid());
create policy "bebegimin avatars delete" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and public.path_uuid(name, 1) = auth.uid());
