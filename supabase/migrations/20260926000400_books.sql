-- =====================================================================
-- 004 "İlk Yılım" book projects, editable pages/items and PDF exports
-- =====================================================================

create table public.book_projects (
  id               uuid primary key default gen_random_uuid(),
  baby_id          uuid not null references public.babies (id) on delete cascade,
  kind             text not null default 'first_year' check (kind in ('first_year')),
  title            text not null default 'Bebeğimin İlk Yılı' check (char_length(btrim(title)) between 1 and 120),
  subtitle         text check (subtitle is null or char_length(subtitle) <= 200),
  format           text not null default 'square_21' check (format in ('a4_portrait', 'square_21', 'square_30')),
  theme            text not null default 'classic' check (theme in ('classic', 'soft', 'minimal')),
  cover_media_id   uuid,
  back_cover_text  text check (back_cover_text is null or char_length(back_cover_text) <= 1000),
  current_version  integer not null default 0 check (current_version >= 0),
  last_synced_at   timestamptz,
  created_by       uuid references auth.users (id) on delete set null default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (id, baby_id),
  unique (baby_id, kind),
  foreign key (cover_media_id, baby_id) references public.media (id, baby_id) on delete set null (cover_media_id)
);

create trigger book_projects_set_updated_at
  before update on public.book_projects
  for each row execute function public.set_updated_at();

create table public.book_pages (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null,
  baby_id     uuid not null,
  page_type   text not null check (page_type in (
                'cover', 'welcome', 'birth', 'month', 'milestones', 'letters',
                'one_year', 'back_cover', 'custom')),
  month_index smallint check (month_index is null or month_index between 1 and 12),
  title       text not null check (char_length(title) <= 120),
  body        text check (body is null or char_length(body) <= 4000),
  sort_order  integer not null,
  is_hidden   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, baby_id),
  check ((page_type = 'month') = (month_index is not null)),
  foreign key (project_id, baby_id) references public.book_projects (id, baby_id) on delete cascade
);

create index book_pages_project_idx on public.book_pages (project_id, sort_order);
create unique index book_pages_singleton_idx on public.book_pages (project_id, page_type, coalesce(month_index, 0))
  where page_type <> 'custom';

create trigger book_pages_set_updated_at
  before update on public.book_pages
  for each row execute function public.set_updated_at();

create table public.book_items (
  id           uuid primary key default gen_random_uuid(),
  page_id      uuid not null,
  baby_id      uuid not null,
  item_type    text not null check (item_type in ('media', 'memory', 'milestone', 'letter')),
  media_id     uuid,
  memory_id    uuid,
  milestone_id uuid,
  letter_id    uuid,
  sort_order   integer not null default 0,
  is_hidden    boolean not null default false,
  caption      text check (caption is null or char_length(caption) <= 500),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (num_nonnulls(media_id, memory_id, milestone_id, letter_id) = 1),
  check (
    (item_type = 'media' and media_id is not null) or
    (item_type = 'memory' and memory_id is not null) or
    (item_type = 'milestone' and milestone_id is not null) or
    (item_type = 'letter' and letter_id is not null)
  ),
  foreign key (page_id, baby_id) references public.book_pages (id, baby_id) on delete cascade,
  foreign key (media_id, baby_id) references public.media (id, baby_id) on delete cascade,
  foreign key (memory_id, baby_id) references public.memories (id, baby_id) on delete cascade,
  foreign key (milestone_id, baby_id) references public.milestones (id, baby_id) on delete cascade,
  foreign key (letter_id, baby_id) references public.letters (id, baby_id) on delete cascade
);

create index book_items_page_idx on public.book_items (page_id, sort_order);
create unique index book_items_unique_ref_idx on public.book_items
  (page_id, coalesce(media_id, memory_id, milestone_id, letter_id));

create trigger book_items_set_updated_at
  before update on public.book_items
  for each row execute function public.set_updated_at();

create table public.book_exports (
  id           uuid primary key default gen_random_uuid(),
  project_id   uuid not null,
  baby_id      uuid not null,
  version      integer not null check (version > 0),
  format       text not null check (format in ('a4_portrait', 'square_21', 'square_30')),
  quality      text not null default 'print' check (quality in ('print', 'screen')),
  storage_path text not null unique,
  page_count   integer not null check (page_count > 0),
  size_bytes   bigint check (size_bytes is null or size_bytes >= 0),
  created_by   uuid references auth.users (id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now(),
  unique (project_id, version),
  check (storage_path like baby_id::text || '/' || project_id::text || '/%'),
  foreign key (project_id, baby_id) references public.book_projects (id, baby_id) on delete cascade
);

create index book_exports_project_idx on public.book_exports (project_id, version desc);

-- Registering an export bumps the project's version atomically.
create or replace function public.register_book_export(
  p_project_id uuid,
  p_storage_path text,
  p_page_count integer,
  p_size_bytes bigint,
  p_quality text default 'print'
)
returns public.book_exports
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project public.book_projects;
  v_export public.book_exports;
begin
  select * into v_project from public.book_projects where id = p_project_id for update;
  if not found or not public.has_baby_permission(v_project.baby_id, 'create_book') then
    raise exception 'book project not found' using errcode = 'P0002';
  end if;

  perform set_config('bebegimin.book_version_bump', 'on', true);
  update public.book_projects
     set current_version = current_version + 1
   where id = p_project_id
  returning * into v_project;
  perform set_config('bebegimin.book_version_bump', '', true);

  insert into public.book_exports (project_id, baby_id, version, format, quality, storage_path,
                                   page_count, size_bytes, created_by)
  values (v_project.id, v_project.baby_id, v_project.current_version, v_project.format, p_quality,
          p_storage_path, p_page_count, p_size_bytes, auth.uid())
  returning * into v_export;

  return v_export;
end;
$$;

revoke all on function public.register_book_export(uuid, text, integer, bigint, text) from public, anon;
grant execute on function public.register_book_export(uuid, text, integer, bigint, text) to authenticated, service_role;

create or replace function public.book_owner_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.baby_id <> old.baby_id then
    raise exception 'baby_id is immutable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'book_projects' then
    -- only register_book_export() may bump the version
    if coalesce(current_setting('bebegimin.book_version_bump', true), '') <> 'on' then
      new.current_version := old.current_version;
    end if;
    new.created_by := old.created_by;
  end if;
  return new;
end;
$$;

create trigger book_projects_owner_guard before update on public.book_projects
  for each row execute function public.book_owner_guard();
create trigger book_pages_owner_guard before update on public.book_pages
  for each row execute function public.book_owner_guard();
create trigger book_items_owner_guard before update on public.book_items
  for each row execute function public.book_owner_guard();

create or replace function public.queue_book_file_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.storage_cleanup_queue (bucket_id, path)
  values ('books', old.storage_path)
  on conflict do nothing;
  return old;
end;
$$;

create trigger book_exports_queue_cleanup after delete on public.book_exports
  for each row execute function public.queue_book_file_cleanup();

-- RLS ------------------------------------------------------------------------------
alter table public.book_projects enable row level security;
alter table public.book_pages enable row level security;
alter table public.book_items enable row level security;
alter table public.book_exports enable row level security;

revoke all on table public.book_projects, public.book_pages, public.book_items, public.book_exports
  from anon, authenticated;
grant select, insert, update, delete on table public.book_projects, public.book_pages, public.book_items
  to authenticated;
grant select, delete on table public.book_exports to authenticated; -- insert via register_book_export()
grant all on table public.book_projects, public.book_pages, public.book_items, public.book_exports
  to service_role;

create policy "book creators and album viewers can read projects"
  on public.book_projects for select to authenticated
  using (public.has_baby_permission(baby_id, 'create_book') or public.has_baby_permission(baby_id, 'view_album'));
create policy "book creators can create projects"
  on public.book_projects for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can update projects"
  on public.book_projects for update to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'))
  with check (public.has_baby_permission(baby_id, 'create_book'));
create policy "admins can delete projects"
  on public.book_projects for delete to authenticated
  using (public.is_baby_admin(baby_id));

create policy "book creators can read pages"
  on public.book_pages for select to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can create pages"
  on public.book_pages for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can update pages"
  on public.book_pages for update to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'))
  with check (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can delete pages"
  on public.book_pages for delete to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'));

create policy "book creators can read items"
  on public.book_items for select to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can create items"
  on public.book_items for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can update items"
  on public.book_items for update to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'))
  with check (public.has_baby_permission(baby_id, 'create_book'));
create policy "book creators can delete items"
  on public.book_items for delete to authenticated
  using (public.has_baby_permission(baby_id, 'create_book'));

create policy "album viewers can list exports"
  on public.book_exports for select to authenticated
  using (public.has_baby_permission(baby_id, 'view_album') or public.has_baby_permission(baby_id, 'create_book'));
create policy "admins can delete exports"
  on public.book_exports for delete to authenticated
  using (public.is_baby_admin(baby_id));
