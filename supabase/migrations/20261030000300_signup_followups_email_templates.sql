-- =====================================================================
-- "Yeni Kayıtlar": new sign-ups waiting for a manual welcome e-mail.
--
-- The system NEVER sends e-mail. The admin writes the message in his own mail
-- client and then marks it as sent here; this module only
--   * derives the pending list from auth.users (no copy, no trigger on auth.users),
--   * records the manual "sent" mark (idempotent, concurrency safe, audited),
--   * stores two editable, versioned templates (welcome, trial activated).
--
-- Safe start: only users created at or after `signup_queue_started` (set when this
-- migration runs) can appear. Earlier users are never listed as new and nothing is
-- deleted or changed. Deleting a user removes their marks with them.
-- Rollback: supabase/rollbacks/20261030000300_signup_followups_email_templates.down.sql
-- =====================================================================
begin;

insert into public.user_event_meta (key, value) values ('signup_queue_started', now());

-- Manual "e-mail sent" marks ------------------------------------------------------------------------
create table public.email_followups (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users (id) on delete cascade,
  template  text not null check (template in ('welcome', 'trial_activated')),
  trial_id  uuid references public.access_trials (id) on delete cascade,
  marked_by uuid references auth.users (id) on delete set null,
  marked_at timestamptz not null default now(),
  check ((template = 'welcome' and trial_id is null) or (template = 'trial_activated' and trial_id is not null))
);

-- One welcome mark per user, one trial mark per trial: this is the concurrency guard.
create unique index email_followups_welcome_idx on public.email_followups (user_id) where template = 'welcome';
create unique index email_followups_trial_idx on public.email_followups (trial_id) where template = 'trial_activated';

-- Editable templates ----------------------------------------------------------------------------------
create table public.email_templates (
  kind       text primary key check (kind in ('welcome', 'trial_activated')),
  subject    text not null default '' check (char_length(subject) <= 200),
  body       text not null default '' check (char_length(body) <= 10000),
  version    integer not null default 0 check (version >= 0),
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.email_template_versions (
  id       bigint generated always as identity primary key,
  kind     text not null references public.email_templates (kind),
  version  integer not null,
  subject  text not null,
  body     text not null,
  saved_by uuid references auth.users (id) on delete set null,
  saved_at timestamptz not null default now(),
  unique (kind, version)
);

create or replace function public.email_template_versions_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'template versions are append-only' using errcode = '42501';
end;
$$;

create trigger email_template_versions_immutable
  before update or delete on public.email_template_versions
  for each row execute function public.email_template_versions_immutable();

-- Empty drafts: the owner writes the real text in the admin panel.
insert into public.email_templates (kind) values ('welcome'), ('trial_activated');

alter table public.email_followups enable row level security;
alter table public.email_templates enable row level security;
alter table public.email_template_versions enable row level security;
revoke all on table public.email_followups, public.email_templates, public.email_template_versions
  from public, anon, authenticated;
grant all on table public.email_followups, public.email_templates, public.email_template_versions to service_role;

-- Admin read / write models -------------------------------------------------------------------------------
create or replace function public.admin_new_signups(
  p_status text default 'pending',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  email text,
  display_name text,
  signed_up_at timestamptz,
  email_verified_at timestamptz,
  welcome_marked_at timestamptz,
  welcome_marked_by_name text,
  trial_status text,
  trial_ends_at timestamptz,
  trial_id uuid,
  trial_email_marked_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_start timestamptz := (select m.value from public.user_event_meta m where m.key = 'signup_queue_started');
begin
  perform public.assert_admin_console('read', 120);
  if p_status is null or p_status not in ('pending', 'sent', 'all') then
    raise exception 'invalid status filter' using errcode = '22023';
  end if;

  return query
  with base as (
    select u.id, u.email::text as email, p.display_name, u.created_at, u.email_confirmed_at,
           w.marked_at as w_at, coalesce(nullif(wp.display_name, ''), wu.email::text) as w_by
      from auth.users u
      left join public.profiles p on p.id = u.id
      left join public.email_followups w on w.user_id = u.id and w.template = 'welcome'
      left join auth.users wu on wu.id = w.marked_by
      left join public.profiles wp on wp.id = w.marked_by
     where u.created_at >= v_start
       and not exists (select 1 from public.platform_user_roles r
                        where r.user_id = u.id and r.role = 'super_admin' and r.revoked_at is null)
       and (p_status = 'all'
            or (p_status = 'pending' and w.id is null)
            or (p_status = 'sent' and w.id is not null))
  )
  select b.id, b.email, b.display_name, b.created_at, b.email_confirmed_at, b.w_at, b.w_by,
         case when t.id is null then 'none'
              when t.revoked_at is not null then 'revoked'
              when t.ends_at <= now() then 'expired'
              else 'live' end,
         t.ends_at, t.id, tf.marked_at,
         count(*) over ()
    from base b
    left join lateral (
      select x.id, x.ends_at, x.revoked_at from public.access_trials x
       where x.user_id = b.id order by x.starts_at desc limit 1) t on true
    left join public.email_followups tf on tf.trial_id = t.id and tf.template = 'trial_activated'
   order by b.created_at desc, b.id
   limit v_limit offset v_offset;
end;
$$;

-- Menu badge: own rate-limit bucket so page loads never eat the read budget.
create or replace function public.admin_pending_signup_count()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start timestamptz := (select m.value from public.user_event_meta m where m.key = 'signup_queue_started');
begin
  perform public.assert_admin_console('badge', 240);
  return (
    select count(*) from auth.users u
     where u.created_at >= v_start
       and not exists (select 1 from public.email_followups w where w.user_id = u.id and w.template = 'welcome')
       and not exists (select 1 from public.platform_user_roles r
                        where r.user_id = u.id and r.role = 'super_admin' and r.revoked_at is null));
end;
$$;

-- Idempotent: the unique indexes make a double click or two admins mark once.
create or replace function public.admin_mark_email_sent(
  p_user_id uuid,
  p_template text,
  p_trial_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted bigint;
begin
  perform public.assert_admin_console('write', 60);
  if p_template is null or p_template not in ('welcome', 'trial_activated') then
    raise exception 'invalid template' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'user not found' using errcode = 'P0002';
  end if;
  if p_template = 'trial_activated'
     and (p_trial_id is null
          or not exists (select 1 from public.access_trials t where t.id = p_trial_id and t.user_id = p_user_id)) then
    raise exception 'trial does not belong to the user' using errcode = '22023';
  end if;
  if p_template = 'welcome' then
    p_trial_id := null;
  end if;

  insert into public.email_followups (user_id, template, trial_id, marked_by)
  values (p_user_id, p_template, p_trial_id, auth.uid())
  on conflict do nothing
  returning id into v_inserted;
  return case when v_inserted is null then 'already_marked' else 'marked' end;
end;
$$;

create or replace function public.admin_email_templates()
returns table (
  kind text,
  subject text,
  body text,
  version integer,
  updated_at timestamptz,
  updated_by_name text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_admin_console('read', 120);
  return query
  select t.kind, t.subject, t.body, t.version, t.updated_at,
         coalesce(nullif(p.display_name, ''), u.email::text)
    from public.email_templates t
    left join auth.users u on u.id = t.updated_by
    left join public.profiles p on p.id = t.updated_by
   order by t.kind;
end;
$$;

-- Plain text only; the only placeholders are {{ad}} and {{deneme_bitis}}.
create or replace function public.admin_save_email_template(p_kind text, p_subject text, p_body text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject text := coalesce(p_subject, '');
  v_body text := coalesce(p_body, '');
  v_version integer;
begin
  perform public.assert_admin_console('write', 30);
  if p_kind is null or p_kind not in ('welcome', 'trial_activated') then
    raise exception 'invalid template' using errcode = '22023';
  end if;
  if char_length(v_subject) > 200 or char_length(v_body) > 10000 then
    raise exception 'template is too long' using errcode = '22023';
  end if;
  if exists (
    select 1 from regexp_matches(v_subject || ' ' || v_body, '\{\{\s*([A-Za-z0-9_]*)\s*\}\}', 'g') as m
     where m[1] not in ('ad', 'deneme_bitis')
  ) then
    raise exception 'unknown placeholder (allowed: ad, deneme_bitis)' using errcode = '22023';
  end if;

  perform 1 from public.email_templates t where t.kind = p_kind for update;
  update public.email_templates
     set subject = v_subject, body = v_body, version = version + 1, updated_by = auth.uid(), updated_at = now()
   where kind = p_kind
  returning version into v_version;
  insert into public.email_template_versions (kind, version, subject, body, saved_by)
  values (p_kind, v_version, v_subject, v_body, auth.uid());
  return v_version;
end;
$$;

revoke all on function public.email_template_versions_immutable() from public, anon, authenticated;
revoke all on function public.admin_new_signups(text, integer, integer),
  public.admin_pending_signup_count(),
  public.admin_mark_email_sent(uuid, text, uuid),
  public.admin_email_templates(),
  public.admin_save_email_template(text, text, text)
  from public, anon;
grant execute on function public.admin_new_signups(text, integer, integer),
  public.admin_pending_signup_count(),
  public.admin_mark_email_sent(uuid, text, uuid),
  public.admin_email_templates(),
  public.admin_save_email_template(text, text, text)
  to authenticated, service_role;

commit;
