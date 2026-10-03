-- =====================================================================
-- Small hardening after the 2026-10-02 review (CLAUDE-REPORT.MD D-3, D-4).
--
--   * legal_erasure_active(): the transaction-local switch that lets the
--     legal-erasure trigger delete immutable output rows now only counts in
--     trusted contexts. A client role (authenticated / anon) that sets the
--     custom setting itself gets false; the guards stay in force.
--   * run_daily_jobs(): the default day is the Europe/Istanbul business
--     date (was the session's current_date), like every lifecycle decision.
--     The cron schedule (06:00 UTC = 09:00 Istanbul) gave the same day; a
--     manual run near midnight no longer can differ.
-- =====================================================================
begin;

create or replace function public.legal_erasure_active()
returns boolean
language sql
stable
set search_path = ''
as $$
  -- The switch only counts in trusted contexts (definer RPCs, service role):
  -- a client session can never use it to skip the immutability guards.
  select coalesce(current_setting('bebegimin.legal_erasure', true), '') = 'on'
     and current_user not in ('authenticated', 'anon');
$$;

create or replace function public.run_daily_jobs(p_today date default public.business_date_istanbul())
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

    -- 2) the archive is complete (LOCKED) -> the digital products open.
    -- Before phase 13 this fired on day 365, while the archive was still
    -- ACTIVE and the book closed.
    if p_today = r.birth_date + 375 + coalesce((
         select er.requested_days::integer from public.baby_extension_requests er
          where er.baby_id = r.id and er.status = 'approved'), 0) then
      perform public.notify_family(r.id, null, 'book_ready',
        public.tr_suffix(r.first_name, 'genitive') || ' İlk Yıl arşivi tamamlandı 📖',
        'Dijital kitap, film ve çevrimdışı arşiv artık hazırlanabilir.',
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

commit;
