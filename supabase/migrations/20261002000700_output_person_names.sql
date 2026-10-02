-- =====================================================================
-- Decision P-11 (2026-10-02, GELISTIRME.MD "Karar kaydı"): every person
-- named in the Book, Film and offline HTML is written "Name + relation":
-- "Esra Teyzesi", "Ahmet Amcası", "Elif Annesi". The same rule lives in the
-- app (book engine, outputPersonName) and in the output worker (HTML,
-- personLabel); the three share the test vectors.
--
--   * output_person_name(person jsonb): the rule for snapshot person JSON
--     ({name, relation, relation_label}).
--       relation word = the custom label if set, else the possessive of a
--       known relation (relation_display), else none ("diger").
--       Result = name + ' ' + relation word; the name alone; the relation
--       word alone; or '' when both are missing.
--   * film_candidates(): letter subtitles use it (before: the name only).
-- New film manifests use the new names; sealed manifests are unchanged.
-- =====================================================================
begin;

create or replace function public.output_person_name(p_person jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  with x as (
    select nullif(btrim(coalesce(p_person ->> 'name', '')), '') as name,
           coalesce(nullif(btrim(coalesce(p_person ->> 'relation_label', '')), ''),
                    case when p_person ->> 'relation' in ('anne', 'baba', 'abla', 'abi', 'teyze', 'hala', 'dayi', 'amca',
                                                          'anneanne', 'babaanne', 'dede')
                         then public.relation_display(p_person ->> 'relation', null) end) as rel
  )
  select case
           when x.name is null then coalesce(x.rel, '')
           when x.rel is null then x.name
           else x.name || ' ' || x.rel
         end
    from x;
$$;

revoke all on function public.output_person_name(jsonb) from public, anon;
grant execute on function public.output_person_name(jsonb) to authenticated, service_role;

create or replace function public.film_candidates(p_content jsonb, p_settings jsonb)
returns table (chapter integer, sort_date date, kind_order integer, kind text, item_id uuid, base_ms integer,
               min_ms integer, payload jsonb, rank_in_kind integer)
language sql
stable
set search_path = ''
as $$
  with s as (
    select public.film_settings_normalized(p_settings) as v
  ), ex as (
    select array(select jsonb_array_elements_text(s.v -> 'excluded_ids')) as ids from s
  ), b as (
    select (p_content -> 'baby' ->> 'birth_date')::date as birth
  ), items as (
    select public.film_chapter(b.birth, (m ->> 'memory_date')::date) as chapter, (m ->> 'memory_date')::date as sort_date,
           1 as kind_order, 'memory'::text as kind, (m ->> 'id')::uuid as item_id, 3500 as base_ms, 2500 as min_ms,
           jsonb_build_object('title', m ->> 'title', 'text', left(coalesce(m ->> 'body', ''), 240),
                              'subtitle', public.film_date_tr((m ->> 'memory_date')::date)) as payload,
           0 as prio
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'memories', '[]'::jsonb)) m
     where (s.v ->> 'include_memory_texts')::boolean and coalesce((m ->> 'include_in_book')::boolean, true)
       and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select public.film_chapter(b.birth, (m ->> 'achieved_on')::date), (m ->> 'achieved_on')::date, 2, 'milestone',
           (m ->> 'id')::uuid, 3500, 2500,
           jsonb_build_object('title', coalesce(m ->> 'title', 'İlk'), 'text', left(coalesce(m ->> 'description', ''), 200),
                              'subtitle', public.film_date_tr((m ->> 'achieved_on')::date)),
           0
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'milestones', '[]'::jsonb)) m
     where (s.v ->> 'include_milestones')::boolean and coalesce((m ->> 'include_in_book')::boolean, true)
       and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select public.film_chapter(b.birth, (m ->> 'taken_on')::date), (m ->> 'taken_on')::date, 3, 'photo',
           (m ->> 'id')::uuid, 3500, 2000,
           jsonb_build_object('media_id', m ->> 'id', 'storage_path', m ->> 'storage_path',
                              'caption', nullif(btrim(coalesce(m ->> 'caption', '')), ''),
                              'subtitle', public.film_date_tr((m ->> 'taken_on')::date)),
           (case when m ->> 'memory_id' is not null or m ->> 'milestone_id' is not null then 2 else 0 end)
           + (case when nullif(btrim(coalesce(m ->> 'caption', '')), '') is not null then 1 else 0 end)
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'media', '[]'::jsonb)) m
     where m ->> 'kind' = 'photo' and coalesce((m ->> 'include_in_book')::boolean, true)
       and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select public.film_chapter(b.birth, (m ->> 'taken_on')::date), (m ->> 'taken_on')::date, 4, 'video',
           (m ->> 'id')::uuid,
           greatest(least(coalesce((m ->> 'duration_ms')::integer, 5000), 8000), 1000),
           greatest(least(coalesce((m ->> 'duration_ms')::integer, 5000), 3000), 1000),
           jsonb_build_object('media_id', m ->> 'id', 'storage_path', m ->> 'storage_path', 'clip_start_ms', 0,
                              'source_duration_ms', (m ->> 'duration_ms')::integer,
                              'caption', nullif(btrim(coalesce(m ->> 'caption', '')), ''),
                              'subtitle', public.film_date_tr((m ->> 'taken_on')::date)),
           (case when m ->> 'memory_id' is not null or m ->> 'milestone_id' is not null then 2 else 0 end)
           + (case when nullif(btrim(coalesce(m ->> 'caption', '')), '') is not null then 1 else 0 end)
      from b, s, ex, jsonb_array_elements(coalesce(p_content -> 'media', '[]'::jsonb)) m
     where m ->> 'kind' = 'video' and (s.v ->> 'include_videos')::boolean
       and coalesce((m ->> 'include_in_book')::boolean, true) and not (lower(m ->> 'id') = any (ex.ids))
    union all
    select 15, (l ->> 'written_on')::date, 5, 'letter', (l ->> 'id')::uuid, 6000, 4000,
           jsonb_build_object('title', coalesce(nullif(btrim(coalesce(l ->> 'title', '')), ''), 'Sana bir mektup'),
                              'text', left(coalesce(l ->> 'body', ''), 320),
                              'subtitle', public.output_person_name(l -> 'author')),
           0
      from s, ex, jsonb_array_elements(coalesce(p_content -> 'letters', '[]'::jsonb)) l
     where (s.v ->> 'include_letters')::boolean and coalesce((l ->> 'include_in_book')::boolean, true)
       and not (lower(l ->> 'id') = any (ex.ids))
  )
  select i.chapter, i.sort_date, i.kind_order, i.kind, i.item_id, i.base_ms, i.min_ms, i.payload,
         row_number() over (partition by i.chapter, i.kind order by i.prio desc, i.sort_date, i.item_id)::integer
    from items i;
$$;

commit;
