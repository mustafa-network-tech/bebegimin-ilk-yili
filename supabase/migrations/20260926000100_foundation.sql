-- =====================================================================
-- Bebeğimin İlk Yılı — 001 Foundation
-- Extensions, shared helper functions and the user profile table.
--
-- Conventions used in every migration:
--   * Every table has RLS enabled. `anon` never gets table privileges.
--   * `authenticated` only receives the privileges its policies need.
--   * SECURITY DEFINER functions always pin `search_path = ''` and use
--     fully-qualified names.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

-- Generic updated_at trigger ------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Profiles -------------------------------------------------------------------
create table public.profiles (
  id                   uuid primary key references auth.users (id) on delete cascade,
  display_name         text not null default ''
                        check (char_length(display_name) <= 80),
  avatar_path          text check (avatar_path is null or char_length(avatar_path) <= 300),
  locale               text not null default 'tr' check (locale in ('tr', 'en')),
  onboarding_completed boolean not null default false,
  notification_prefs   jsonb not null default
    '{"family_activity": true, "anniversaries": true, "memories_of_the_day": true, "book": true, "time_capsules": true}'::jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.profiles is
  'Public-to-family profile of an auth user. E-mail is deliberately NOT copied here.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- A user may only change harmless columns of their own profile.
create or replace function public.profiles_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id then
    raise exception 'profile id is immutable' using errcode = '42501';
  end if;
  if new.avatar_path is not null
     and new.avatar_path not like (new.id::text || '/%') then
    raise exception 'avatar must live in the owner folder' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.profiles_guard();

-- Create a profile row automatically for every new auth user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), ''), 80)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

revoke all on function public.handle_new_user() from public, anon, authenticated;

alter table public.profiles enable row level security;
revoke all on table public.profiles from anon, authenticated;
grant select, update on table public.profiles to authenticated;
grant all on table public.profiles to service_role;
