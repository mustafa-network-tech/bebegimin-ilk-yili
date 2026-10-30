-- =====================================================================
-- Decision P-1 (2026-10-02, GELISTIRME.MD "Karar kaydı"): the official
-- outputs (Book, Film, HTML) hold the content dated before the baby's own
-- effective close date: birth + 375 + approved extension days (half-open,
-- at most birth + 405). Phase 13 cut every baby at a flat birth + 405, so a
-- legacy baby without an extension sealed days 375-405 too.
--
--   * build_archive_snapshot_content(): exclusive effective close cutoff;
--     a Super Admin grandfather decision still includes everything.
--   * admin_legacy_rollout_report(): post_cutoff_content counts content on
--     or after each baby's effective close date.
-- Sealed snapshots are immutable and keep their content; new snapshots use
-- the new cutoff.
-- =====================================================================
begin;

create or replace function public.build_archive_snapshot_content(p_baby_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_baby public.babies;
  v_extension integer;
  v_cutoff date;
begin
  select * into v_baby from public.babies b where b.id = p_baby_id;
  if v_baby.id is null then
    raise exception 'resource not found' using errcode = 'P0002';
  end if;
  select coalesce(max(er.requested_days) filter (where er.status = 'approved'), 0)::integer into v_extension
    from public.baby_extension_requests er where er.baby_id = p_baby_id;
  -- Decision P-1: official outputs hold the content dated before the baby's
  -- own effective close date (birth + 375 + approved extension, at most
  -- 405; half-open). Later content is legacy: kept, not sealed, unless a
  -- Super Admin grandfathered it. v_cutoff is the exclusive end.
  v_cutoff := case when public.legacy_content_included(p_baby_id) then 'infinity'::date
                   else v_baby.birth_date + 375 + v_extension end;

  return jsonb_build_object(
    'schema_version', 1,
    'baby', jsonb_build_object(
      'id', v_baby.id, 'first_name', v_baby.first_name, 'last_name', v_baby.last_name,
      'birth_date', v_baby.birth_date, 'birth_time', v_baby.birth_time, 'birth_place', v_baby.birth_place,
      'birth_weight_grams', v_baby.birth_weight_grams, 'birth_length_cm', v_baby.birth_length_cm,
      'avatar_path', v_baby.avatar_path, 'cover_path', v_baby.cover_path, 'story', v_baby.story),
    'lifecycle', jsonb_build_object(
      'base_close_date', v_baby.birth_date + 375,
      'extension_days', v_extension,
      'effective_close_date', v_baby.birth_date + 375 + v_extension),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', fm.user_id,
               'name', coalesce(nullif(btrim(p.display_name), ''), ''),
               'relation', fm.relation,
               'relation_label', fm.relation_label)
             order by fm.joined_at, fm.user_id)
        from public.family_members fm
        left join public.profiles p on p.id = fm.user_id
       where fm.baby_id = p_baby_id), '[]'::jsonb),
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'type_key', t.key, 'title', t.title, 'emoji', t.emoji,
               'achieved_on', m.achieved_on, 'achieved_time', m.achieved_time, 'description', m.description,
               'include_in_book', m.include_in_book,
               'author', public.archive_snapshot_person(p_baby_id, m.created_by))
             order by m.achieved_on, t.sort_order, m.id)
        from public.milestones m
        join public.milestone_types t on t.id = m.milestone_type_id
       where m.baby_id = p_baby_id and m.achieved_on < v_cutoff), '[]'::jsonb),
    'memories', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'title', m.title, 'body', m.body, 'memory_date', m.memory_date,
               'memory_time', m.memory_time, 'category', m.category, 'milestone_id', m.milestone_id,
               'include_in_book', m.include_in_book,
               'author', public.archive_snapshot_person(p_baby_id, m.author_id))
             order by m.memory_date, m.memory_time nulls first, m.created_at, m.id)
        from public.memories m
       where m.baby_id = p_baby_id and m.memory_date < v_cutoff), '[]'::jsonb),
    'letters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'title', l.title, 'body', l.body, 'written_on', l.written_on,
               'include_in_book', l.include_in_book,
               'author', coalesce(public.archive_snapshot_person(p_baby_id, l.author_id), '{}'::jsonb)
                         || jsonb_strip_nulls(jsonb_build_object(
                              'name', nullif(btrim(l.author_name), ''),
                              'relation', l.author_relation,
                              'relation_label', l.author_relation_label)))
             order by l.written_on, l.created_at, l.id)
        from public.letters l
       where l.baby_id = p_baby_id and l.written_on < v_cutoff), '[]'::jsonb),
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'kind', m.kind, 'storage_path', m.storage_path, 'thumb_path', m.thumb_path,
               'mime_type', m.mime_type, 'width', m.width, 'height', m.height, 'duration_ms', m.duration_ms,
               'size_bytes', m.size_bytes, 'caption', m.caption, 'taken_on', m.taken_on, 'tags', to_jsonb(m.tags),
               'include_in_book', m.include_in_book, 'sort_order', m.sort_order,
               'memory_id', m.memory_id, 'milestone_id', m.milestone_id, 'letter_id', m.letter_id,
               'uploader', public.archive_snapshot_person(p_baby_id, m.uploader_id))
             order by m.taken_on, m.sort_order, m.created_at, m.id)
        from public.media m
       where m.baby_id = p_baby_id and m.status = 'ready' and m.taken_on < v_cutoff), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'memory_id', c.memory_id, 'milestone_id', c.milestone_id, 'media_id', c.media_id,
               'body', c.body, 'created_at', public.snapshot_ts(c.created_at),
               'author', public.archive_snapshot_person(p_baby_id, c.author_id))
             order by c.created_at, c.id)
        from public.comments c
       where c.baby_id = p_baby_id
         and (c.memory_id is null or exists (select 1 from public.memories x where x.id = c.memory_id and x.memory_date < v_cutoff))
         and (c.milestone_id is null or exists (select 1 from public.milestones x where x.id = c.milestone_id and x.achieved_on < v_cutoff))
         and (c.media_id is null or exists (select 1 from public.media x where x.id = c.media_id and x.taken_on < v_cutoff))),
      '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_legacy_rollout_report()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform public.assert_admin_console('read', 30);
  with b as (
    select b.id, b.birth_date, coalesce(public.baby_lifecycle_active_internal(b.id), true) as active,
           b.birth_date + 375 + coalesce((select er.requested_days::integer from public.baby_extension_requests er
                                           where er.baby_id = b.id and er.status = 'approved'), 0) as close_date
      from public.babies b
  ), post as (
    select b.id as baby_id,
           (select count(*) from public.memories m where m.baby_id = b.id and m.memory_date >= b.close_date)
         + (select count(*) from public.milestones m where m.baby_id = b.id and m.achieved_on >= b.close_date)
         + (select count(*) from public.letters l where l.baby_id = b.id and l.written_on >= b.close_date)
         + (select count(*) from public.media m where m.baby_id = b.id and m.taken_on >= b.close_date) as items
      from b
  ), referenced as (
    select m.storage_path as path from public.media m
    union select m.thumb_path from public.media m where m.thumb_path is not null
    union select x.avatar_path from public.babies x where x.avatar_path is not null
    union select x.cover_path from public.babies x where x.cover_path is not null
    union select c.baby_id::text || '/capsules/' || c.id::text || '/photo.jpg' from public.time_capsules c where c.has_photo
  ), orphans as (
    select o.name from storage.objects o
     where o.bucket_id = 'baby-media' and not exists (select 1 from referenced r where r.path = o.name)
  )
  select jsonb_build_object(
    'babies_total', (select count(*) from b),
    'babies_locked', (select count(*) from b where not b.active),
    'babies_locked_ids', coalesce((select jsonb_agg(b.id order by b.id) from b where not b.active), '[]'::jsonb),
    'post_cutoff_content', coalesce((select jsonb_agg(jsonb_build_object('baby_id', p.baby_id, 'items', p.items,
                                                                         'grandfathered', public.legacy_content_included(p.baby_id))
                                                      order by p.baby_id)
                                       from post p where p.items > 0), '[]'::jsonb),
    'legacy_book_projects', (select count(*) from public.book_projects where legacy_status is not null),
    'legacy_book_exports', (select count(*) from public.book_exports where legacy_status is not null),
    'orphan_media_objects', (select count(*) from orphans),
    'orphan_media_sample', coalesce((select jsonb_agg(o.name) from (select name from orphans order by name limit 50) o), '[]'::jsonb),
    'unmapped_babies', coalesce((select jsonb_agg(x.id order by x.id) from public.babies x
                                  where not exists (select 1 from public.family_account_babies f where f.baby_id = x.id)),
                                '[]'::jsonb),
    'users_parent_in_several_accounts', coalesce((
      select jsonb_agg(u.user_id order by u.user_id) from (
        select m.user_id from public.family_account_members m
         where m.role = 'parent' and m.status = 'active'
         group by m.user_id having count(*) > 1) u), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

commit;
