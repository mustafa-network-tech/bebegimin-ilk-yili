-- =====================================================================
-- 005 In-app notifications, push device tokens, activity log,
--     content triggers and the daily job (anniversaries, "one year ago",
--     book reminders, time capsule openings).
-- =====================================================================

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  baby_id    uuid references public.babies (id) on delete cascade,
  type       text not null check (type in (
               'family_activity', 'member_joined', 'anniversary', 'birthday',
               'memories_of_the_day', 'book_ready', 'book_generated', 'time_capsule_opened')),
  title      text not null check (char_length(title) <= 200),
  body       text check (body is null or char_length(body) <= 1000),
  data       jsonb not null default '{}'::jsonb,
  dedupe_key text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_user_idx on public.notifications (user_id, created_at desc);
create unique index notifications_dedupe_idx on public.notifications (user_id, dedupe_key)
  where dedupe_key is not null;

create table public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade default auth.uid(),
  token      text not null unique check (char_length(token) between 10 and 4096),
  platform   text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens (user_id);

create trigger device_tokens_set_updated_at
  before update on public.device_tokens
  for each row execute function public.set_updated_at();

create table public.activity_logs (
  id          bigint generated always as identity primary key,
  baby_id     uuid not null references public.babies (id) on delete cascade,
  actor_id    uuid references auth.users (id) on delete set null,
  action      text not null,
  target_type text,
  target_id   uuid,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

create index activity_logs_baby_idx on public.activity_logs (baby_id, created_at desc);

-- RLS -------------------------------------------------------------------------------
alter table public.notifications enable row level security;
alter table public.device_tokens enable row level security;
alter table public.activity_logs enable row level security;

revoke all on table public.notifications, public.device_tokens, public.activity_logs from anon, authenticated;
grant select, delete on table public.notifications to authenticated;
grant update (read_at) on table public.notifications to authenticated;
grant select, insert, update, delete on table public.device_tokens to authenticated;
grant select on table public.activity_logs to authenticated;
grant all on table public.notifications, public.device_tokens, public.activity_logs to service_role;

create policy "users read own notifications"
  on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "users mark own notifications read"
  on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "users delete own notifications"
  on public.notifications for delete to authenticated using (user_id = auth.uid());

create policy "users manage own device tokens (select)"
  on public.device_tokens for select to authenticated using (user_id = auth.uid());
create policy "users manage own device tokens (insert)"
  on public.device_tokens for insert to authenticated with check (user_id = auth.uid());
create policy "users manage own device tokens (update)"
  on public.device_tokens for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "users manage own device tokens (delete)"
  on public.device_tokens for delete to authenticated using (user_id = auth.uid());

create policy "admins read the activity log"
  on public.activity_logs for select to authenticated
  using (public.is_baby_admin(baby_id));

-- Helpers ---------------------------------------------------------------------------------
create or replace function public.relation_display(p_relation text, p_label text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(nullif(btrim(p_label), ''), case p_relation
    when 'anne' then 'Annesi'
    when 'baba' then 'Babası'
    when 'abla' then 'Ablası'
    when 'abi' then 'Abisi'
    when 'teyze' then 'Teyzesi'
    when 'hala' then 'Halası'
    when 'dayi' then 'Dayısı'
    when 'amca' then 'Amcası'
    when 'anneanne' then 'Anneannesi'
    when 'babaanne' then 'Babaannesi'
    when 'dede' then 'Dedesi'
    else 'Bir yakını'
  end);
$$;

-- Turkish suffixes with vowel harmony: Defne'nin / Can'ın / Defne'ye / Can'a
create or replace function public.tr_suffix(p_name text, p_case text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_lower text := lower(translate(btrim(p_name), 'IİÖÜÇŞĞ', 'ıiöüçşğ'));
  v_last_vowel text;
  v_ends_with_vowel boolean;
  i integer;
begin
  if v_lower = '' then
    return p_name;
  end if;
  for i in reverse char_length(v_lower)..1 loop
    if position(substr(v_lower, i, 1) in 'aıoueiöü') > 0 then
      v_last_vowel := substr(v_lower, i, 1);
      exit;
    end if;
  end loop;
  v_last_vowel := coalesce(v_last_vowel, 'e');
  v_ends_with_vowel := position(right(v_lower, 1) in 'aıoueiöü') > 0;
  if p_case = 'genitive' then
    return btrim(p_name) || '''' || case when v_ends_with_vowel then 'n' else '' end
      || case when v_last_vowel in ('a', 'ı') then 'ı'
              when v_last_vowel in ('e', 'i') then 'i'
              when v_last_vowel in ('o', 'u') then 'u'
              else 'ü' end || 'n';
  else -- dative
    return btrim(p_name) || '''' || case when v_ends_with_vowel then 'y' else '' end
      || case when v_last_vowel in ('a', 'ı', 'o', 'u') then 'a' else 'e' end;
  end if;
end;
$$;

-- Notify every member of a baby (except the actor) who wants this type and can see it.
create or replace function public.notify_family(
  p_baby_id uuid,
  p_actor uuid,
  p_type text,
  p_title text,
  p_body text,
  p_data jsonb,
  p_required_permission text default 'view_memories',
  p_dedupe_key text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pref_key text := case
    when p_type in ('family_activity', 'member_joined') then 'family_activity'
    when p_type in ('anniversary', 'birthday') then 'anniversaries'
    when p_type = 'memories_of_the_day' then 'memories_of_the_day'
    when p_type in ('book_ready', 'book_generated') then 'book'
    when p_type = 'time_capsule_opened' then 'time_capsules'
    else p_type end;
begin
  insert into public.notifications (user_id, baby_id, type, title, body, data, dedupe_key)
  select fm.user_id, p_baby_id, p_type, left(p_title, 200), left(p_body, 1000),
         coalesce(p_data, '{}'::jsonb) || jsonb_build_object('baby_id', p_baby_id),
         p_dedupe_key
  from public.family_members fm
  left join public.profiles pr on pr.id = fm.user_id
  where fm.baby_id = p_baby_id
    and fm.user_id is distinct from p_actor
    and (p_required_permission is null or fm.is_admin or p_required_permission = any (fm.permissions))
    and coalesce((pr.notification_prefs ->> v_pref_key)::boolean, true)
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
end;
$$;

revoke all on function public.notify_family(uuid, uuid, text, text, text, jsonb, text, text) from public, anon, authenticated;

create or replace function public.actor_display(p_baby_id uuid, p_actor uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select public.relation_display(fm.relation, fm.relation_label)
            || coalesce(' ' || nullif(p.display_name, ''), '')
     from public.family_members fm
     left join public.profiles p on p.id = fm.user_id
     where fm.baby_id = p_baby_id and fm.user_id = p_actor),
    'Bir aile üyesi');
$$;

revoke all on function public.actor_display(uuid, uuid) from public, anon, authenticated;

-- Content triggers ------------------------------------------------------------------------------
create or replace function public.on_content_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_baby_name text;
  v_title text;
  v_action text;
  v_text text;
begin
  select first_name into v_baby_name from public.babies where id = new.baby_id;

  if tg_table_name = 'memories' then
    v_actor := new.author_id;
    v_title := new.title;
    v_action := 'memory_created';
    v_text := public.actor_display(new.baby_id, v_actor) || ' yeni bir anı ekledi.';
  elsif tg_table_name = 'milestones' then
    v_actor := new.created_by;
    select t.title into v_title from public.milestone_types t where t.id = new.milestone_type_id;
    v_action := 'milestone_created';
    v_text := v_baby_name || ' için yeni bir ilk kaydedildi: ' || v_title || ' ✨';
  elsif tg_table_name = 'letters' then
    v_actor := new.author_id;
    v_title := coalesce(new.title, 'Yeni mektup');
    v_action := 'letter_created';
    v_text := public.actor_display(new.baby_id, v_actor) || ' ' || public.tr_suffix(v_baby_name, 'dative') || ' bir mektup yazdı. 💌';
  else
    return new;
  end if;

  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
  values (new.baby_id, v_actor, v_action, tg_table_name, new.id, jsonb_build_object('title', v_title));

  perform public.notify_family(
    new.baby_id, v_actor, 'family_activity', v_text, v_title,
    jsonb_build_object('target_type', tg_table_name, 'target_id', new.id),
    'view_memories', null);

  return new;
end;
$$;

create trigger memories_on_created after insert on public.memories
  for each row execute function public.on_content_created();
create trigger milestones_on_created after insert on public.milestones
  for each row execute function public.on_content_created();
create trigger letters_on_created after insert on public.letters
  for each row execute function public.on_content_created();

create or replace function public.on_member_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (new.baby_id, new.user_id, 'member_joined', 'family_members', new.id,
            jsonb_build_object('relation', new.relation, 'is_admin', new.is_admin));
    if new.invited_by is not null then
      perform public.notify_family(
        new.baby_id, new.user_id, 'member_joined',
        public.actor_display(new.baby_id, new.user_id) || ' aileye katıldı. 🤍', null,
        jsonb_build_object('member_id', new.id), 'view_memories', null);
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    if new.is_admin <> old.is_admin or new.permissions <> old.permissions
       or new.relation <> old.relation or new.relation_label is distinct from old.relation_label then
      insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
      values (new.baby_id, auth.uid(), 'member_updated', 'family_members', new.id,
              jsonb_build_object('user_id', new.user_id,
                                 'old', jsonb_build_object('is_admin', old.is_admin, 'permissions', old.permissions, 'relation', old.relation),
                                 'new', jsonb_build_object('is_admin', new.is_admin, 'permissions', new.permissions, 'relation', new.relation)));
    end if;
    return new;
  else
    if exists (select 1 from public.babies where id = old.baby_id) then
      insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
      values (old.baby_id, auth.uid(),
              case when old.user_id = auth.uid() then 'member_left' else 'member_removed' end,
              'family_members', old.id, jsonb_build_object('user_id', old.user_id, 'relation', old.relation));
    end if;
    return old;
  end if;
end;
$$;

create trigger family_members_on_changed after insert or update or delete on public.family_members
  for each row execute function public.on_member_changed();

create or replace function public.on_invitation_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (new.baby_id, new.created_by, 'invitation_created', 'family_invitations', new.id,
            jsonb_build_object('relation', new.relation, 'is_admin', new.is_admin));
  elsif new.status <> old.status then
    insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
    values (new.baby_id, auth.uid(), 'invitation_' || new.status, 'family_invitations', new.id, '{}'::jsonb);
  end if;
  return new;
end;
$$;

create trigger family_invitations_on_changed after insert or update on public.family_invitations
  for each row execute function public.on_invitation_changed();

create or replace function public.on_book_exported()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  select first_name into v_name from public.babies where id = new.baby_id;
  insert into public.activity_logs (baby_id, actor_id, action, target_type, target_id, details)
  values (new.baby_id, new.created_by, 'book_generated', 'book_exports', new.id,
          jsonb_build_object('version', new.version, 'pages', new.page_count));
  perform public.notify_family(
    new.baby_id, new.created_by, 'book_generated',
    public.tr_suffix(v_name, 'genitive') || ' İlk Yılım kitabı hazır! 📖',
    'Sürüm ' || new.version || ' · ' || new.page_count || ' sayfa',
    jsonb_build_object('project_id', new.project_id, 'export_id', new.id),
    'view_album', 'book_export:' || new.id::text);
  return new;
end;
$$;

create trigger book_exports_on_created after insert on public.book_exports
  for each row execute function public.on_book_exported();

-- Daily job ------------------------------------------------------------------------------------------
create or replace function public.run_daily_jobs(p_today date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_months integer;
  v_years integer;
  v_count integer := 0;
  v_capsules integer := 0;
begin
  -- 1) month-iversaries (first 24 months) and birthdays
  for r in select b.id, b.first_name, b.birth_date from public.babies b where b.birth_date < p_today loop
    v_months := (extract(year from age(p_today, r.birth_date)) * 12
                 + extract(month from age(p_today, r.birth_date)))::integer;
    if v_months >= 1 and (r.birth_date + make_interval(months => v_months))::date = p_today then
      v_years := v_months / 12;
      if v_months % 12 = 0 then
        perform public.notify_family(r.id, null, 'birthday',
          'Bugün ' || r.first_name || ' ' || v_years || ' yaşında! 🎂',
          'Bu özel günü bir anıyla ölümsüzleştirin.',
          jsonb_build_object('years', v_years), null,
          'birthday:' || r.id::text || ':' || v_years);
      elsif v_months < 24 then
        perform public.notify_family(r.id, null, 'anniversary',
          'Bugün ' || r.first_name || ' ' || v_months || ' aylık oldu ❤️',
          'Bu ayın en güzel anını eklemeye ne dersiniz?',
          jsonb_build_object('months', v_months), null,
          'months:' || r.id::text || ':' || v_months);
      end if;
      v_count := v_count + 1;
    end if;

    -- 2) the first year is complete -> the book can be created
    if p_today = r.birth_date + 365 then
      perform public.notify_family(r.id, null, 'book_ready',
        public.tr_suffix(r.first_name, 'genitive') || ' İlk Yılım kitabı oluşturulmaya hazır 📖',
        'İlk 365 günün tüm anıları bir kitapta buluşsun.',
        '{}'::jsonb, 'create_book', 'book_ready:' || r.id::text);
    end if;
  end loop;

  -- 3) "Bir yıl önce bugün..."
  for r in
    select m.baby_id, min(m.title) as title, count(*) as cnt
    from public.memories m
    where m.memory_date = (p_today - interval '1 year')::date
    group by m.baby_id
  loop
    perform public.notify_family(r.baby_id, null, 'memories_of_the_day',
      'Bir yıl önce bugün... ✨',
      r.title || case when r.cnt > 1 then ' ve ' || (r.cnt - 1) || ' anı daha' else '' end,
      jsonb_build_object('date', (p_today - interval '1 year')::date), 'view_memories',
      'otd:' || r.baby_id::text || ':' || p_today::text);
  end loop;

  -- 4) time capsules that open today
  for r in select c.id, c.baby_id, c.title, b.first_name
           from public.time_capsules c join public.babies b on b.id = c.baby_id
           where c.open_on = p_today loop
    perform public.notify_family(r.baby_id, null, 'time_capsule_opened',
      'Bir zaman kapsülü açıldı! 💫', r.title,
      jsonb_build_object('capsule_id', r.id), 'view_memories', 'capsule:' || r.id::text);
    v_capsules := v_capsules + 1;
  end loop;

  -- 5) housekeeping
  update public.family_invitations set status = 'expired'
   where status = 'pending' and expires_at <= now();
  delete from public.notifications where created_at < now() - interval '180 days';
  -- abandoned uploads (app killed mid-upload and never resumed)
  delete from public.media where status in ('uploading', 'failed') and created_at < now() - interval '3 days';

  return jsonb_build_object('anniversaries', v_count, 'capsules', v_capsules);
end;
$$;

revoke all on function public.run_daily_jobs(date) from public, anon, authenticated;
grant execute on function public.run_daily_jobs(date) to service_role;

-- Schedule with pg_cron when available (enable it under Database > Extensions).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension if not exists pg_cron;
      perform cron.schedule('bebegimin-daily-jobs', '0 6 * * *', 'select public.run_daily_jobs()');
    exception when others then
      raise notice 'pg_cron scheduling skipped: %', sqlerrm;
    end;
  else
    raise notice 'pg_cron is not available; schedule public.run_daily_jobs() manually.';
  end if;
end;
$$;

-- Realtime for the notification badge (Supabase only).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;
