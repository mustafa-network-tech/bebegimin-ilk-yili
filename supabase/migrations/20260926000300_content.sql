-- =====================================================================
-- 003 Content: milestones, memories, letters, media, comments,
--     favorites, time capsules.
--
-- Composite foreign keys (child.parent_id, child.baby_id) ->
-- parent(id, baby_id) guarantee that a row can never be attached to
-- content of ANOTHER baby (IDOR protection at the schema level).
-- =====================================================================

-- Milestone types ("İlklerim") ---------------------------------------------------
create table public.milestone_types (
  id         uuid primary key default gen_random_uuid(),
  key        text unique check (key is null or key ~ '^[a-z_]{3,40}$'),
  baby_id    uuid references public.babies (id) on delete cascade,
  title      text not null check (char_length(btrim(title)) between 1 and 80),
  emoji      text check (emoji is null or char_length(emoji) <= 8),
  sort_order smallint not null default 1000,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- system types have a key and no baby, custom types belong to exactly one baby
  check ((key is null) = (baby_id is not null)),
  unique (id, baby_id)
);

create index milestone_types_baby_idx on public.milestone_types (baby_id) where baby_id is not null;

create trigger milestone_types_set_updated_at
  before update on public.milestone_types
  for each row execute function public.set_updated_at();

insert into public.milestone_types (key, title, emoji, sort_order) values
  ('first_smile',      'İlk gülümsemem',        '😊', 10),
  ('first_bath',       'İlk banyom',            '🛁', 20),
  ('first_laugh',      'İlk kahkaham',          '😄', 25),
  ('first_rollover',   'İlk kez döndüm',        '🔄', 30),
  ('first_tooth',      'İlk dişim',             '🦷', 40),
  ('first_solid_food', 'İlk ek gıdam',          '🥣', 45),
  ('first_sat_up',     'İlk kez oturdum',       '🪑', 50),
  ('first_crawl',      'İlk kez emekledim',     '🧸', 60),
  ('first_word',       'İlk kelimem',           '💬', 70),
  ('first_steps',      'İlk adımım',            '👣', 80),
  ('first_holiday',    'İlk bayramım',          '🎉', 90),
  ('first_trip',       'İlk yolculuğum',        '🚗', 100),
  ('first_sea',        'İlk denizim',           '🌊', 110),
  ('first_snow',       'İlk karım',             '❄️', 120),
  ('first_birthday',   'İlk doğum günüm',       '🎂', 130),
  ('first_haircut',    'İlk saç kesimim',       '✂️', 140),
  ('first_school_day', 'İlk okul günüm',        '🎒', 150);

-- Milestones ------------------------------------------------------------------------
create table public.milestones (
  id                uuid primary key default gen_random_uuid(),
  baby_id           uuid not null references public.babies (id) on delete cascade,
  milestone_type_id uuid not null references public.milestone_types (id) on delete restrict,
  achieved_on       date not null,
  achieved_time     time,
  description       text check (description is null or char_length(description) <= 4000),
  include_in_book   boolean not null default true,
  created_by        uuid references auth.users (id) on delete set null default auth.uid(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, baby_id),
  unique (baby_id, milestone_type_id)
);

create index milestones_baby_date_idx on public.milestones (baby_id, achieved_on desc);

create trigger milestones_set_updated_at
  before update on public.milestones
  for each row execute function public.set_updated_at();

-- Memories (timeline entries) ----------------------------------------------------------
create table public.memories (
  id              uuid primary key default gen_random_uuid(),
  baby_id         uuid not null references public.babies (id) on delete cascade,
  author_id       uuid references auth.users (id) on delete set null default auth.uid(),
  title           text not null check (char_length(btrim(title)) between 1 and 140),
  body            text check (body is null or char_length(body) <= 10000),
  memory_date     date not null,
  memory_time     time,
  category        text not null default 'moment' check (category in (
                    'moment', 'photo', 'video', 'special_day', 'family', 'travel',
                    'health', 'growth', 'first', 'other')),
  milestone_id    uuid,
  include_in_book boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, baby_id),
  foreign key (milestone_id, baby_id) references public.milestones (id, baby_id)
    on delete set null (milestone_id)
);

create index memories_baby_date_idx on public.memories (baby_id, memory_date desc, created_at desc);
create index memories_author_idx on public.memories (author_id);
create index memories_title_trgm_idx on public.memories using gin (title extensions.gin_trgm_ops);
create index memories_body_trgm_idx on public.memories using gin (body extensions.gin_trgm_ops);

create trigger memories_set_updated_at
  before update on public.memories
  for each row execute function public.set_updated_at();

-- Letters ("Ailemden Bana") ---------------------------------------------------------------
create table public.letters (
  id              uuid primary key default gen_random_uuid(),
  baby_id         uuid not null references public.babies (id) on delete cascade,
  author_id       uuid references auth.users (id) on delete set null default auth.uid(),
  author_name     text not null default '' check (char_length(author_name) <= 80),
  author_relation text not null default 'diger',
  author_relation_label text,
  title           text check (title is null or char_length(title) <= 140),
  body            text not null check (char_length(btrim(body)) between 1 and 20000),
  written_on      date not null default current_date,
  include_in_book boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, baby_id)
);

create index letters_baby_idx on public.letters (baby_id, written_on desc);

create trigger letters_set_updated_at
  before update on public.letters
  for each row execute function public.set_updated_at();

-- Media (photos and videos) -------------------------------------------------------------
create table public.media (
  id              uuid primary key default gen_random_uuid(),
  baby_id         uuid not null references public.babies (id) on delete cascade,
  uploader_id     uuid references auth.users (id) on delete set null default auth.uid(),
  memory_id       uuid,
  milestone_id    uuid,
  letter_id       uuid,
  kind            text not null check (kind in ('photo', 'video')),
  storage_path    text not null unique check (char_length(storage_path) <= 300),
  thumb_path      text check (thumb_path is null or char_length(thumb_path) <= 300),
  mime_type       text not null check (mime_type ~ '^(image|video)/[a-z0-9.+-]+$'),
  width           integer check (width is null or width > 0),
  height          integer check (height is null or height > 0),
  duration_ms     integer check (duration_ms is null or duration_ms >= 0),
  size_bytes      bigint check (size_bytes is null or size_bytes >= 0),
  caption         text check (caption is null or char_length(caption) <= 2000),
  taken_on        date not null,
  tags            text[] not null default '{}',
  include_in_book boolean not null default true,
  status          text not null default 'uploading' check (status in ('uploading', 'ready', 'failed')),
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, baby_id),
  check (num_nonnulls(memory_id, milestone_id, letter_id) <= 1),
  check (cardinality(tags) <= 30),
  foreign key (memory_id, baby_id) references public.memories (id, baby_id) on delete cascade,
  foreign key (milestone_id, baby_id) references public.milestones (id, baby_id) on delete cascade,
  foreign key (letter_id, baby_id) references public.letters (id, baby_id) on delete cascade
);

create index media_baby_date_idx on public.media (baby_id, taken_on desc) where status = 'ready';
create index media_memory_idx on public.media (memory_id) where memory_id is not null;
create index media_milestone_idx on public.media (milestone_id) where milestone_id is not null;
create index media_letter_idx on public.media (letter_id) where letter_id is not null;
create index media_tags_idx on public.media using gin (tags);

create trigger media_set_updated_at
  before update on public.media
  for each row execute function public.set_updated_at();

-- Comments / family notes -------------------------------------------------------------------
create table public.comments (
  id           uuid primary key default gen_random_uuid(),
  baby_id      uuid not null references public.babies (id) on delete cascade,
  author_id    uuid references auth.users (id) on delete set null default auth.uid(),
  memory_id    uuid,
  milestone_id uuid,
  media_id     uuid,
  body         text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (num_nonnulls(memory_id, milestone_id, media_id) = 1),
  foreign key (memory_id, baby_id) references public.memories (id, baby_id) on delete cascade,
  foreign key (milestone_id, baby_id) references public.milestones (id, baby_id) on delete cascade,
  foreign key (media_id, baby_id) references public.media (id, baby_id) on delete cascade
);

create index comments_memory_idx on public.comments (memory_id, created_at) where memory_id is not null;
create index comments_milestone_idx on public.comments (milestone_id, created_at) where milestone_id is not null;
create index comments_media_idx on public.comments (media_id, created_at) where media_id is not null;

create trigger comments_set_updated_at
  before update on public.comments
  for each row execute function public.set_updated_at();

-- Favorites (per user) ---------------------------------------------------------------------------
create table public.favorites (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade default auth.uid(),
  baby_id      uuid not null references public.babies (id) on delete cascade,
  memory_id    uuid,
  media_id     uuid,
  milestone_id uuid,
  letter_id    uuid,
  created_at   timestamptz not null default now(),
  check (num_nonnulls(memory_id, media_id, milestone_id, letter_id) = 1),
  foreign key (memory_id, baby_id) references public.memories (id, baby_id) on delete cascade,
  foreign key (media_id, baby_id) references public.media (id, baby_id) on delete cascade,
  foreign key (milestone_id, baby_id) references public.milestones (id, baby_id) on delete cascade,
  foreign key (letter_id, baby_id) references public.letters (id, baby_id) on delete cascade
);

create unique index favorites_unique_idx on public.favorites
  (user_id, coalesce(memory_id, media_id, milestone_id, letter_id));
create index favorites_user_baby_idx on public.favorites (user_id, baby_id);

-- Time capsules ------------------------------------------------------------------------------------
-- Metadata is visible to the family, the sealed content lives in a separate
-- table whose SELECT policy only opens on/after `open_on`.
create table public.time_capsules (
  id              uuid primary key default gen_random_uuid(),
  baby_id         uuid not null references public.babies (id) on delete cascade,
  author_id       uuid references auth.users (id) on delete set null,
  author_name     text not null default '',
  author_relation text not null default 'diger',
  author_relation_label text,
  title           text not null check (char_length(btrim(title)) between 1 and 140),
  occasion        text not null default 'custom' check (occasion in ('age_5', 'age_10', 'age_18', 'custom')),
  open_on         date not null,
  has_photo       boolean not null default false,
  created_at      timestamptz not null default now(),
  unique (id, baby_id)
);

create index time_capsules_baby_idx on public.time_capsules (baby_id, open_on);

create table public.time_capsule_contents (
  capsule_id uuid primary key,
  baby_id    uuid not null,
  body       text not null check (char_length(btrim(body)) between 1 and 20000),
  foreign key (capsule_id, baby_id) references public.time_capsules (id, baby_id) on delete cascade
);

-- Validation triggers --------------------------------------------------------------------------------

create or replace function public.content_date_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_birth date;
  v_date date;
begin
  select birth_date into v_birth from public.babies where id = new.baby_id;
  if tg_table_name = 'memories' then
    v_date := new.memory_date;
  elsif tg_table_name = 'milestones' then
    v_date := new.achieved_on;
  else
    v_date := new.written_on;
  end if;
  -- Pregnancy memories are allowed (up to ~10 months before birth);
  -- future dates are not (except timezone slack of one day).
  if v_date < v_birth - 310 then
    raise exception 'date is too far before the birth date' using errcode = '22023', hint = 'date_before_birth';
  end if;
  if v_date > current_date + 1 then
    raise exception 'date cannot be in the future' using errcode = '22023', hint = 'date_in_future';
  end if;
  return new;
end;
$$;

create trigger memories_date_guard before insert or update of memory_date on public.memories
  for each row execute function public.content_date_guard();
create trigger milestones_date_guard before insert or update of achieved_on on public.milestones
  for each row execute function public.content_date_guard();
create trigger letters_date_guard before insert or update of written_on on public.letters
  for each row execute function public.content_date_guard();

-- Authorship / ownership columns can never be forged or changed.
create or replace function public.content_owner_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return new; -- service role / trusted RPC
  end if;
  if tg_op = 'INSERT' then
    case tg_table_name
      when 'memories' then new.author_id := v_uid;
      when 'milestones' then new.created_by := v_uid;
      when 'media' then new.uploader_id := v_uid;
      when 'comments' then new.author_id := v_uid;
      when 'favorites' then new.user_id := v_uid;
      when 'milestone_types' then new.created_by := v_uid;
      else null;
    end case;
  else
    if new.baby_id <> old.baby_id then
      raise exception 'baby_id is immutable' using errcode = '42501';
    end if;
    case tg_table_name
      when 'memories' then new.author_id := old.author_id;
      when 'milestones' then new.created_by := old.created_by;
      when 'media' then
        new.uploader_id := old.uploader_id;
        new.storage_path := old.storage_path;
        new.kind := old.kind;
        new.mime_type := old.mime_type;
      when 'comments' then new.author_id := old.author_id;
      when 'milestone_types' then new.created_by := old.created_by;
      else null;
    end case;
  end if;
  return new;
end;
$$;

create trigger memories_owner_guard before insert or update on public.memories
  for each row execute function public.content_owner_guard();
create trigger milestones_owner_guard before insert or update on public.milestones
  for each row execute function public.content_owner_guard();
create trigger media_owner_guard before insert or update on public.media
  for each row execute function public.content_owner_guard();
create trigger comments_owner_guard before insert or update on public.comments
  for each row execute function public.content_owner_guard();
create trigger favorites_owner_guard before insert on public.favorites
  for each row execute function public.content_owner_guard();

create or replace function public.milestone_types_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null then
    if tg_op = 'INSERT' then
      new.created_by := auth.uid();
      new.key := null; -- clients can only create custom (baby-bound) types
    elsif new.baby_id is distinct from old.baby_id or new.key is distinct from old.key then
      raise exception 'milestone type ownership is immutable' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger milestone_types_guard before insert or update on public.milestone_types
  for each row execute function public.milestone_types_guard();

create or replace function public.milestones_type_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.milestone_types t
    where t.id = new.milestone_type_id
      and (t.baby_id is null or t.baby_id = new.baby_id)
  ) then
    raise exception 'milestone type does not belong to this baby' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger milestones_type_guard before insert or update of milestone_type_id on public.milestones
  for each row execute function public.milestones_type_guard();

-- Media storage paths are bound to the baby and the media id:
--   <baby_id>/<media_id>/<file>
create or replace function public.media_path_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.storage_path not like (new.baby_id::text || '/' || new.id::text || '/%') then
    raise exception 'storage_path must be <baby_id>/<media_id>/<file>' using errcode = '42501';
  end if;
  if new.thumb_path is not null
     and new.thumb_path not like (new.baby_id::text || '/' || new.id::text || '/%') then
    raise exception 'thumb_path must be <baby_id>/<media_id>/<file>' using errcode = '42501';
  end if;
  if (new.kind = 'photo' and new.mime_type not like 'image/%')
     or (new.kind = 'video' and new.mime_type not like 'video/%') then
    raise exception 'mime type does not match media kind' using errcode = '22023';
  end if;
  new.tags := array(select distinct lower(btrim(t)) from unnest(new.tags) t where btrim(t) <> '' order by 1);
  return new;
end;
$$;

create trigger media_path_guard before insert or update on public.media
  for each row execute function public.media_path_guard();

-- Snapshot the author's name / relation on letters (kept even if they leave).
create or replace function public.letters_author_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.author_id := v_uid;
    select coalesce(nullif(p.display_name, ''), 'Aile üyesi'), fm.relation, fm.relation_label
      into new.author_name, new.author_relation, new.author_relation_label
    from public.family_members fm
    left join public.profiles p on p.id = fm.user_id
    where fm.baby_id = new.baby_id and fm.user_id = v_uid;
  else
    new.author_id := old.author_id;
    new.author_name := old.author_name;
    new.author_relation := old.author_relation;
    new.author_relation_label := old.author_relation_label;
    if new.baby_id <> old.baby_id then
      raise exception 'baby_id is immutable' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger letters_author_snapshot before insert or update on public.letters
  for each row execute function public.letters_author_snapshot();

-- Media rows removed by cascades leave files behind: queue them for the
-- `storage-cleanup` Edge Function (direct deletes on storage.objects are
-- not allowed by Supabase).
create table public.storage_cleanup_queue (
  id         bigint generated always as identity primary key,
  bucket_id  text not null,
  path       text not null,
  created_at timestamptz not null default now(),
  unique (bucket_id, path)
);

alter table public.storage_cleanup_queue enable row level security;
revoke all on table public.storage_cleanup_queue from anon, authenticated;
grant all on table public.storage_cleanup_queue to service_role;

create or replace function public.queue_media_file_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.storage_cleanup_queue (bucket_id, path)
  values ('baby-media', old.storage_path)
  on conflict do nothing;
  if old.thumb_path is not null then
    insert into public.storage_cleanup_queue (bucket_id, path)
    values ('baby-media', old.thumb_path)
    on conflict do nothing;
  end if;
  return old;
end;
$$;

create trigger media_queue_cleanup after delete on public.media
  for each row execute function public.queue_media_file_cleanup();

-- RLS ----------------------------------------------------------------------------------------------------
alter table public.milestone_types enable row level security;
alter table public.milestones enable row level security;
alter table public.memories enable row level security;
alter table public.letters enable row level security;
alter table public.media enable row level security;
alter table public.comments enable row level security;
alter table public.favorites enable row level security;
alter table public.time_capsules enable row level security;
alter table public.time_capsule_contents enable row level security;

revoke all on table public.milestone_types, public.milestones, public.memories, public.letters,
  public.media, public.comments, public.favorites, public.time_capsules,
  public.time_capsule_contents
  from anon, authenticated;

grant select, insert, update, delete on table public.milestone_types, public.milestones,
  public.memories, public.letters, public.media, public.comments to authenticated;
grant select, insert, delete on table public.favorites to authenticated;
grant select, delete on table public.time_capsules to authenticated;   -- insert via create_time_capsule()
grant select on table public.time_capsule_contents to authenticated;   -- sealed: no insert/update/delete
grant all on table public.milestone_types, public.milestones, public.memories, public.letters,
  public.media, public.comments, public.favorites, public.time_capsules,
  public.time_capsule_contents to service_role;

-- milestone_types
create policy "system and own custom milestone types are readable"
  on public.milestone_types for select to authenticated
  using (baby_id is null or public.is_baby_member(baby_id));
create policy "milestone adders can create custom types"
  on public.milestone_types for insert to authenticated
  with check (baby_id is not null and public.has_baby_permission(baby_id, 'add_milestone'));
create policy "custom type owners or content managers can update"
  on public.milestone_types for update to authenticated
  using (baby_id is not null and (
    (created_by = auth.uid() and public.has_baby_permission(baby_id, 'add_milestone'))
    or public.has_baby_permission(baby_id, 'manage_content')))
  with check (baby_id is not null);
create policy "custom type owners or content managers can delete"
  on public.milestone_types for delete to authenticated
  using (baby_id is not null and (
    (created_by = auth.uid() and public.has_baby_permission(baby_id, 'add_milestone'))
    or public.has_baby_permission(baby_id, 'manage_content')));

-- milestones
create policy "viewers can read milestones"
  on public.milestones for select to authenticated
  using (public.has_baby_permission(baby_id, 'view_memories'));
create policy "milestone adders can create"
  on public.milestones for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'add_milestone'));
create policy "owners or content managers can update milestones"
  on public.milestones for update to authenticated
  using ((created_by = auth.uid() and public.has_baby_permission(baby_id, 'edit_own_memory'))
         or public.has_baby_permission(baby_id, 'manage_content'))
  with check (public.is_baby_member(baby_id));
create policy "owners or content managers can delete milestones"
  on public.milestones for delete to authenticated
  using ((created_by = auth.uid() and public.has_baby_permission(baby_id, 'edit_own_memory'))
         or public.has_baby_permission(baby_id, 'manage_content'));

-- memories
create policy "viewers can read memories"
  on public.memories for select to authenticated
  using (public.has_baby_permission(baby_id, 'view_memories'));
create policy "memory adders can create"
  on public.memories for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'add_memory'));
create policy "owners or content managers can update memories"
  on public.memories for update to authenticated
  using ((author_id = auth.uid() and public.has_baby_permission(baby_id, 'edit_own_memory'))
         or public.has_baby_permission(baby_id, 'manage_content'))
  with check (public.is_baby_member(baby_id));
create policy "owners or content managers can delete memories"
  on public.memories for delete to authenticated
  using ((author_id = auth.uid() and public.has_baby_permission(baby_id, 'edit_own_memory'))
         or public.has_baby_permission(baby_id, 'manage_content'));

-- letters
create policy "viewers can read letters"
  on public.letters for select to authenticated
  using (public.has_baby_permission(baby_id, 'view_memories'));
create policy "letter writers can create"
  on public.letters for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'write_letter'));
create policy "authors can update letters"
  on public.letters for update to authenticated
  using (author_id = auth.uid() and public.is_baby_member(baby_id))
  with check (public.is_baby_member(baby_id));
create policy "authors or content managers can delete letters"
  on public.letters for delete to authenticated
  using (author_id = auth.uid() or public.has_baby_permission(baby_id, 'manage_content'));

-- media
create policy "album viewers can read ready media, uploaders their own"
  on public.media for select to authenticated
  using (
    (status = 'ready' and public.has_baby_permission(baby_id, 'view_album'))
    or (uploader_id = auth.uid() and public.is_baby_member(baby_id))
  );
create policy "uploaders can create media"
  on public.media for insert to authenticated
  with check (
    public.has_baby_permission(baby_id, case kind when 'video' then 'add_video' else 'add_photo' end)
    and (letter_id is null or exists (select 1 from public.letters l where l.id = letter_id and l.author_id = auth.uid()))
  );
create policy "uploaders or content managers can update media"
  on public.media for update to authenticated
  using (uploader_id = auth.uid() or public.has_baby_permission(baby_id, 'manage_content'))
  with check (public.is_baby_member(baby_id));
create policy "uploaders or content managers can delete media"
  on public.media for delete to authenticated
  using (uploader_id = auth.uid() or public.has_baby_permission(baby_id, 'manage_content'));

-- comments
create policy "viewers can read comments"
  on public.comments for select to authenticated
  using (public.has_baby_permission(baby_id, 'view_memories'));
create policy "commenters can create"
  on public.comments for insert to authenticated
  with check (public.has_baby_permission(baby_id, 'comment'));
create policy "authors can update comments"
  on public.comments for update to authenticated
  using (author_id = auth.uid() and public.is_baby_member(baby_id))
  with check (public.is_baby_member(baby_id));
create policy "authors or content managers can delete comments"
  on public.comments for delete to authenticated
  using (author_id = auth.uid() or public.has_baby_permission(baby_id, 'manage_content'));

-- favorites
create policy "users manage their own favorites"
  on public.favorites for select to authenticated
  using (user_id = auth.uid() and public.is_baby_member(baby_id));
create policy "users add their own favorites"
  on public.favorites for insert to authenticated
  with check (user_id = auth.uid() and public.is_baby_member(baby_id));
create policy "users delete their own favorites"
  on public.favorites for delete to authenticated
  using (user_id = auth.uid());

-- time capsules
create policy "family can see sealed capsule envelopes"
  on public.time_capsules for select to authenticated
  using (public.has_baby_permission(baby_id, 'view_memories'));
create policy "authors or admins can delete capsules"
  on public.time_capsules for delete to authenticated
  using (author_id = auth.uid() or public.is_baby_admin(baby_id));

create policy "capsule content opens on its date"
  on public.time_capsule_contents for select to authenticated
  using (
    public.has_baby_permission(baby_id, 'view_memories')
    and exists (
      select 1 from public.time_capsules c
      where c.id = capsule_id and c.open_on <= current_date
    )
  );

create or replace function public.create_time_capsule(
  p_baby_id uuid,
  p_title text,
  p_body text,
  p_open_on date,
  p_occasion text default 'custom',
  p_has_photo boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if not public.has_baby_permission(p_baby_id, 'write_letter') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_open_on <= current_date then
    raise exception 'open date must be in the future' using errcode = '22023', hint = 'open_date_not_future';
  end if;
  if p_open_on > current_date + interval '100 years' then
    raise exception 'open date is too far' using errcode = '22023';
  end if;

  insert into public.time_capsules (baby_id, author_id, author_name, author_relation, author_relation_label,
                                    title, occasion, open_on, has_photo)
  select p_baby_id, v_uid, coalesce(nullif(p.display_name, ''), 'Aile üyesi'), fm.relation, fm.relation_label,
         btrim(p_title), p_occasion, p_open_on, coalesce(p_has_photo, false)
  from public.family_members fm
  left join public.profiles p on p.id = fm.user_id
  where fm.baby_id = p_baby_id and fm.user_id = v_uid
  returning id into v_id;

  insert into public.time_capsule_contents (capsule_id, baby_id, body)
  values (v_id, p_baby_id, p_body);

  return v_id;
end;
$$;

revoke all on function public.create_time_capsule(uuid, text, text, date, text, boolean) from public, anon;
grant execute on function public.create_time_capsule(uuid, text, text, date, text, boolean) to authenticated, service_role;
