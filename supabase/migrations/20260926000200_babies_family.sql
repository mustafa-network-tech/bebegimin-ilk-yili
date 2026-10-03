-- =====================================================================
-- 002 Babies, family circle, granular permissions, invitations
--
-- Design: every baby has its own "family circle" (family_members).
-- Relationship labels are relative to the baby (Defne is Ege's "abla"),
-- therefore membership is per baby, not per household. One user can be
-- a member of many babies (multiple children, nieces, grandchildren...).
-- =====================================================================

-- Permission catalog -----------------------------------------------------------
create table public.permissions (
  key         text primary key check (key ~ '^[a-z_]{3,40}$'),
  label       text not null,
  description text not null,
  sort_order  smallint not null
);

insert into public.permissions (key, label, description, sort_order) values
  ('view_memories',   'Anıları görüntüleyebilir',          'Zaman tünelini, anıları, ilkleri ve mektupları görebilir.', 10),
  ('view_album',      'Albümü görüntüleyebilir',           'Fotoğraf ve videoları görebilir, kitap PDF''lerini indirebilir.', 20),
  ('add_memory',      'Anı ekleyebilir',                    'Yeni anı oluşturabilir.', 30),
  ('edit_own_memory', 'Kendi anısını düzenleyebilir',        'Kendi eklediği anı, fotoğraf ve notları düzenleyip silebilir.', 40),
  ('add_photo',       'Fotoğraf ekleyebilir',               'Fotoğraf yükleyebilir.', 50),
  ('add_video',       'Video ekleyebilir',                  'Video yükleyebilir.', 60),
  ('comment',         'Yorum / aile notu yazabilir',        'Anılara ve ilklere yorum bırakabilir.', 70),
  ('add_milestone',   'Kilometre taşı ekleyebilir',         '"İlklerim" bölümüne kayıt ekleyebilir.', 80),
  ('write_letter',    'Bebeğe mektup yazabilir',            'Mektup ve zaman kapsülü bırakabilir.', 90),
  ('create_book',     'Kitap oluşturabilir',                '"İlk Yılım" kitabını düzenleyip PDF üretebilir.', 100),
  ('invite_members',  'Aile üyesi davet edebilir',          'Davet kodu / bağlantısı oluşturabilir.', 110),
  ('manage_members',  'Aile üyelerini yönetebilir',         'Üyelerin rolünü ve yetkilerini değiştirebilir, üye çıkarabilir.', 120),
  ('manage_content',  'Tüm içerikleri yönetebilir',         'Başkalarının eklediği içerikleri düzenleyip silebilir.', 130),
  ('manage_baby',     'Bebek profilini düzenleyebilir',     'Bebeğin doğum bilgilerini ve fotoğraflarını değiştirebilir.', 140);

alter table public.permissions enable row level security;
revoke all on table public.permissions from anon, authenticated;
grant select on table public.permissions to authenticated;
grant all on table public.permissions to service_role;
create policy "permissions are readable by signed-in users"
  on public.permissions for select to authenticated using (true);

-- Babies -----------------------------------------------------------------------
create table public.babies (
  id                 uuid primary key default gen_random_uuid(),
  first_name         text not null check (char_length(btrim(first_name)) between 1 and 60),
  last_name          text check (last_name is null or char_length(last_name) <= 60),
  birth_date         date not null check (birth_date > date '1900-01-01'),
  birth_time         time,
  birth_place        text check (birth_place is null or char_length(birth_place) <= 120),
  birth_weight_grams integer check (birth_weight_grams is null or birth_weight_grams between 200 and 8000),
  birth_length_cm    numeric(4, 1) check (birth_length_cm is null or birth_length_cm between 20 and 70),
  avatar_path        text check (avatar_path is null or char_length(avatar_path) <= 300),
  cover_path         text check (cover_path is null or char_length(cover_path) <= 300),
  story              text check (story is null or char_length(story) <= 4000),
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.babies is 'A child whose memories are archived. Never public.';

create trigger babies_set_updated_at
  before update on public.babies
  for each row execute function public.set_updated_at();

create or replace function public.babies_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.birth_date > current_date + 1 then
    raise exception 'birth_date cannot be in the future' using errcode = '22023';
  end if;
  -- (ON DELETE SET NULL from auth.users is allowed)
  if tg_op = 'UPDATE' and new.created_by is distinct from old.created_by and new.created_by is not null then
    raise exception 'created_by is immutable' using errcode = '42501';
  end if;
  -- profile / cover images must live in the baby's own storage folder
  if new.avatar_path is not null and new.avatar_path not like (new.id::text || '/profile/%') then
    raise exception 'invalid avatar_path' using errcode = '42501';
  end if;
  if new.cover_path is not null and new.cover_path not like (new.id::text || '/profile/%') then
    raise exception 'invalid cover_path' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger babies_guard
  before insert or update on public.babies
  for each row execute function public.babies_guard();

-- Family members ------------------------------------------------------------------
create table public.family_members (
  id             uuid primary key default gen_random_uuid(),
  baby_id        uuid not null references public.babies (id) on delete cascade,
  user_id        uuid not null references auth.users (id) on delete cascade,
  relation       text not null check (relation in (
                   'anne', 'baba', 'abla', 'abi', 'teyze', 'hala', 'dayi', 'amca',
                   'anneanne', 'babaanne', 'dede', 'diger')),
  relation_label text check (relation_label is null or char_length(relation_label) between 1 and 40),
  is_admin       boolean not null default false,
  permissions    text[] not null default '{}',
  invited_by     uuid references auth.users (id) on delete set null,
  joined_at      timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (baby_id, user_id)
);

create index family_members_user_idx on public.family_members (user_id);

-- Second FK to profiles so PostgREST can embed the member's public profile
-- (profiles rows always exist, created by the auth trigger).
alter table public.family_members
  add constraint family_members_profile_fk foreign key (user_id)
  references public.profiles (id) on delete cascade;

create trigger family_members_set_updated_at
  before update on public.family_members
  for each row execute function public.set_updated_at();

-- Permission helpers (SECURITY DEFINER => no RLS recursion). -------------------
create or replace function public.is_baby_member(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_members fm
    where fm.baby_id = p_baby_id and fm.user_id = auth.uid()
  );
$$;

create or replace function public.is_baby_admin(p_baby_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_members fm
    where fm.baby_id = p_baby_id and fm.user_id = auth.uid() and fm.is_admin
  );
$$;

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
  );
$$;

-- True when the current user and p_user share at least one baby.
create or replace function public.shares_baby_with(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.family_members me
    join public.family_members other on other.baby_id = me.baby_id
    where me.user_id = auth.uid() and other.user_id = p_user
  );
$$;

-- Members guard: permission catalog, privilege escalation, last admin. ---------
create or replace function public.family_members_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_is_admin boolean;
  v_remaining_admins integer;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    if exists (
      select 1 from unnest(new.permissions) p
      where p not in (select key from public.permissions)
    ) then
      raise exception 'unknown permission' using errcode = '22023';
    end if;
    -- normalise: sorted, unique
    new.permissions := array(select distinct p from unnest(new.permissions) p order by p);
    if new.relation <> 'diger' and new.relation_label is not null and btrim(new.relation_label) = '' then
      new.relation_label := null;
    end if;
  end if;

  if tg_op = 'UPDATE' then
    if new.baby_id <> old.baby_id or new.user_id <> old.user_id then
      raise exception 'membership identity is immutable' using errcode = '42501';
    end if;
  end if;

  -- Direct API calls (v_actor not null) are subject to escalation rules.
  -- Trusted SECURITY DEFINER RPCs and the service role run with the same
  -- checks performed explicitly inside them.
  if v_actor is not null and tg_op = 'UPDATE' then
    select coalesce(bool_or(fm.is_admin), false) into v_actor_is_admin
    from public.family_members fm
    where fm.baby_id = old.baby_id and fm.user_id = v_actor;

    if not v_actor_is_admin then
      if new.is_admin <> old.is_admin then
        raise exception 'only admins can change admin status' using errcode = '42501';
      end if;
      if old.is_admin then
        raise exception 'only admins can modify an admin' using errcode = '42501';
      end if;
      if old.user_id = v_actor and new.permissions <> old.permissions then
        raise exception 'you cannot change your own permissions' using errcode = '42501';
      end if;
      if ('manage_members' = any (new.permissions) and not 'manage_members' = any (old.permissions))
         or ('manage_content' = any (new.permissions) and not 'manage_content' = any (old.permissions))
         or ('manage_baby' = any (new.permissions) and not 'manage_baby' = any (old.permissions)) then
        raise exception 'only admins can grant management permissions' using errcode = '42501';
      end if;
    end if;
  end if;

  if v_actor is not null and tg_op = 'DELETE' and old.user_id <> v_actor then
    select coalesce(bool_or(fm.is_admin), false) into v_actor_is_admin
    from public.family_members fm
    where fm.baby_id = old.baby_id and fm.user_id = v_actor;
    if old.is_admin and not v_actor_is_admin then
      raise exception 'only admins can remove an admin' using errcode = '42501';
    end if;
  end if;

  -- Never leave a family without an admin (unless the baby itself is being deleted).
  if (tg_op = 'DELETE' and old.is_admin)
     or (tg_op = 'UPDATE' and old.is_admin and not new.is_admin) then
    if exists (select 1 from public.babies b where b.id = old.baby_id) then
      select count(*) into v_remaining_admins
      from public.family_members fm
      where fm.baby_id = old.baby_id and fm.is_admin and fm.id <> old.id;
      if v_remaining_admins = 0 then
        raise exception 'a family must keep at least one admin' using errcode = 'P0001',
          hint = 'last_admin';
      end if;
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger family_members_guard
  before insert or update or delete on public.family_members
  for each row execute function public.family_members_guard();

-- Invitations -----------------------------------------------------------------------
create or replace function public.generate_invite_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- 32 unambiguous characters (no 0/O, 1/I)
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea := uuid_send(gen_random_uuid());
  v_code text := '';
  v_pos integer;
  i integer;
begin
  -- byte 6 carries the UUID version nibble; skip it so every character uses
  -- 5 fully random bits (32^10 ~ 1.1e15 combinations).
  for i in 0..9 loop
    v_pos := case when i >= 6 then i + 1 else i end;
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, v_pos) % 32) + 1, 1);
  end loop;
  return v_code;
end;
$$;

create table public.family_invitations (
  id             uuid primary key default gen_random_uuid(),
  baby_id        uuid not null references public.babies (id) on delete cascade,
  code           text not null unique default public.generate_invite_code()
                   check (code ~ '^[A-HJ-NP-Z2-9]{10}$'),
  relation       text not null check (relation in (
                   'anne', 'baba', 'abla', 'abi', 'teyze', 'hala', 'dayi', 'amca',
                   'anneanne', 'babaanne', 'dede', 'diger')),
  relation_label text check (relation_label is null or char_length(relation_label) between 1 and 40),
  is_admin       boolean not null default false,
  permissions    text[] not null default '{view_memories,view_album,comment}',
  invited_email  text check (invited_email is null or invited_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status         text not null default 'pending'
                   check (status in ('pending', 'accepted', 'revoked', 'expired')),
  expires_at     timestamptz not null default now() + interval '7 days',
  created_by     uuid references auth.users (id) on delete set null default auth.uid(),
  accepted_by    uuid references auth.users (id) on delete set null,
  accepted_at    timestamptz,
  revoked_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (expires_at > created_at),
  check (expires_at <= created_at + interval '30 days')
);

create index family_invitations_baby_idx on public.family_invitations (baby_id, status);

create trigger family_invitations_set_updated_at
  before update on public.family_invitations
  for each row execute function public.set_updated_at();

create or replace function public.family_invitations_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from unnest(new.permissions) p
    where p not in (select key from public.permissions)
  ) then
    raise exception 'unknown permission' using errcode = '22023';
  end if;
  new.permissions := array(select distinct p from unnest(new.permissions) p order by p);
  if new.invited_email is not null then
    new.invited_email := lower(btrim(new.invited_email));
  end if;

  if tg_op = 'INSERT' and auth.uid() is not null then
    new.created_by := auth.uid();
    new.status := 'pending';
    new.accepted_by := null;
    new.accepted_at := null;
    new.revoked_at := null;
    -- Only admins may hand out admin / management rights.
    if not public.is_baby_admin(new.baby_id) and (
         new.is_admin
         or 'manage_members' = any (new.permissions)
         or 'manage_content' = any (new.permissions)
         or 'manage_baby' = any (new.permissions)
         or 'invite_members' = any (new.permissions)) then
      raise exception 'only admins can invite with management permissions' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger family_invitations_guard
  before insert on public.family_invitations
  for each row execute function public.family_invitations_guard();

-- RLS ---------------------------------------------------------------------------------
alter table public.babies enable row level security;
alter table public.family_members enable row level security;
alter table public.family_invitations enable row level security;

revoke all on table public.babies, public.family_members, public.family_invitations from anon, authenticated;
grant select, update on table public.babies to authenticated;              -- insert via create_baby(), delete via Edge Function
grant select, update, delete on table public.family_members to authenticated; -- insert via RPCs only
grant select, insert on table public.family_invitations to authenticated;  -- accept/revoke via RPCs
grant all on table public.babies, public.family_members, public.family_invitations to service_role;

create policy "members can read their babies"
  on public.babies for select to authenticated
  using (public.is_baby_member(id));

create policy "baby managers can update the baby"
  on public.babies for update to authenticated
  using (public.has_baby_permission(id, 'manage_baby'))
  with check (public.has_baby_permission(id, 'manage_baby'));

create policy "members can read their family"
  on public.family_members for select to authenticated
  using (public.is_baby_member(baby_id));

create policy "member managers can update members"
  on public.family_members for update to authenticated
  using (public.has_baby_permission(baby_id, 'manage_members'))
  with check (public.has_baby_permission(baby_id, 'manage_members'));

create policy "member managers can remove members, anyone can leave"
  on public.family_members for delete to authenticated
  using (user_id = auth.uid() or public.has_baby_permission(baby_id, 'manage_members'));

create policy "inviters can read invitations"
  on public.family_invitations for select to authenticated
  using (public.has_baby_permission(baby_id, 'invite_members'));

create policy "inviters can create invitations"
  on public.family_invitations for insert to authenticated
  with check (
    public.has_baby_permission(baby_id, 'invite_members')
    and status = 'pending'
  );

-- Profiles can now reference family membership.
create policy "users can read own profile and family profiles"
  on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_baby_with(id));

create policy "users can update own profile"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- RPCs ------------------------------------------------------------------------------------

-- Create a baby and make the caller its first admin in one transaction.
create or replace function public.create_baby(
  p_first_name text,
  p_birth_date date,
  p_relation text,
  p_relation_label text default null,
  p_last_name text default null,
  p_birth_time time default null,
  p_birth_place text default null,
  p_birth_weight_grams integer default null,
  p_birth_length_cm numeric default null,
  p_story text default null
)
returns public.babies
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_baby public.babies;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  -- basic abuse guard
  select count(*) into v_count from public.babies where created_by = v_uid and created_at > now() - interval '1 hour';
  if v_count >= 10 then
    raise exception 'too many babies created, try later' using errcode = 'P0001';
  end if;

  insert into public.babies (first_name, last_name, birth_date, birth_time, birth_place,
                             birth_weight_grams, birth_length_cm, story, created_by)
  values (btrim(p_first_name), nullif(btrim(p_last_name), ''), p_birth_date, p_birth_time,
          nullif(btrim(p_birth_place), ''), p_birth_weight_grams, p_birth_length_cm,
          nullif(btrim(p_story), ''), v_uid)
  returning * into v_baby;

  insert into public.family_members (baby_id, user_id, relation, relation_label, is_admin, permissions, invited_by)
  values (v_baby.id, v_uid, p_relation, nullif(btrim(p_relation_label), ''), true,
          array(select key from public.permissions), null);

  return v_baby;
end;
$$;

-- Minimal, non-sensitive information about an invitation (shown before joining).
create or replace function public.preview_invitation(p_code text)
returns table (
  baby_first_name text,
  relation text,
  relation_label text,
  inviter_name text,
  expires_at timestamptz,
  already_member boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  return query
    select b.first_name, i.relation, i.relation_label,
           coalesce(nullif(p.display_name, ''), 'Aile yöneticisi'),
           i.expires_at,
           exists (select 1 from public.family_members fm where fm.baby_id = i.baby_id and fm.user_id = auth.uid())
    from public.family_invitations i
    join public.babies b on b.id = i.baby_id
    left join public.profiles p on p.id = i.created_by
    where i.code = upper(btrim(p_code))
      and i.status = 'pending'
      and i.expires_at > now();
end;
$$;

create or replace function public.accept_invitation(p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_inv public.family_invitations;
  v_email text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_inv
  from public.family_invitations
  where code = upper(btrim(p_code))
  for update;

  if not found then
    raise exception 'invitation not found' using errcode = 'P0002', hint = 'invitation_not_found';
  end if;
  if v_inv.status = 'pending' and v_inv.expires_at <= now() then
    update public.family_invitations set status = 'expired' where id = v_inv.id;
    raise exception 'invitation expired' using errcode = 'P0001', hint = 'invitation_expired';
  end if;
  if v_inv.status <> 'pending' then
    raise exception 'invitation is %', v_inv.status using errcode = 'P0001', hint = 'invitation_' || v_inv.status;
  end if;

  if v_inv.invited_email is not null then
    select lower(email) into v_email from auth.users where id = v_uid;
    if v_email is distinct from v_inv.invited_email then
      raise exception 'invitation belongs to another e-mail' using errcode = '42501', hint = 'invitation_email_mismatch';
    end if;
  end if;

  if exists (select 1 from public.family_members where baby_id = v_inv.baby_id and user_id = v_uid) then
    raise exception 'already a member' using errcode = 'P0001', hint = 'already_member';
  end if;

  insert into public.family_members (baby_id, user_id, relation, relation_label, is_admin, permissions, invited_by)
  values (v_inv.baby_id, v_uid, v_inv.relation, v_inv.relation_label, v_inv.is_admin, v_inv.permissions, v_inv.created_by);

  update public.family_invitations
     set status = 'accepted', accepted_by = v_uid, accepted_at = now()
   where id = v_inv.id;

  return v_inv.baby_id;
end;
$$;

create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inv public.family_invitations;
begin
  select * into v_inv from public.family_invitations where id = p_invitation_id for update;
  if not found or not public.has_baby_permission(v_inv.baby_id, 'invite_members') then
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;
  if v_inv.status <> 'pending' then
    raise exception 'only pending invitations can be revoked' using errcode = 'P0001';
  end if;
  update public.family_invitations
     set status = 'revoked', revoked_at = now()
   where id = p_invitation_id;
end;
$$;

-- Add somebody who is already in the family of a sibling (multi-child families).
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

revoke all on function public.is_baby_member(uuid), public.is_baby_admin(uuid),
  public.has_baby_permission(uuid, text), public.shares_baby_with(uuid),
  public.create_baby(text, date, text, text, text, time, text, integer, numeric, text),
  public.preview_invitation(text), public.accept_invitation(text),
  public.revoke_invitation(uuid),
  public.add_member_from_sibling(uuid, uuid, text, text, text[], boolean),
  public.generate_invite_code()
  from public, anon;

grant execute on function public.is_baby_member(uuid), public.is_baby_admin(uuid),
  public.has_baby_permission(uuid, text), public.shares_baby_with(uuid),
  public.create_baby(text, date, text, text, text, time, text, integer, numeric, text),
  public.preview_invitation(text), public.accept_invitation(text),
  public.revoke_invitation(uuid),
  public.add_member_from_sibling(uuid, uuid, text, text, text[], boolean),
  public.generate_invite_code()
  to authenticated, service_role;
