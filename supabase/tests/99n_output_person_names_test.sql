-- Decision P-11 (2026-10-02): people are named "Name + relation" in every
-- official output. The same vectors are tested in the app
-- (test/book/output_person_name_test.dart) and the output worker
-- (workers/output/tests/html_unit.test.ts).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

reset role;
select tests.logout();

select tests.eq(public.output_person_name('{"name": "Esra", "relation": "teyze"}'), 'Esra Teyzesi', 'Esra Teyzesi');
select tests.eq(public.output_person_name('{"name": "Ahmet", "relation": "amca"}'), 'Ahmet Amcası', 'Ahmet Amcası');
select tests.eq(public.output_person_name('{"name": "Elif", "relation": "anne"}'), 'Elif Annesi', 'parents too: Elif Annesi');
select tests.eq(public.output_person_name('{"name": "Deniz", "relation": "diger", "relation_label": "Vaftiz annesi"}'),
                'Deniz Vaftiz annesi', 'a custom relation label follows the name');
select tests.eq(public.output_person_name('{"name": "Deniz", "relation": "diger"}'), 'Deniz', 'no relation word: the name alone');
select tests.eq(public.output_person_name('{"name": "  ", "relation": "teyze"}'), 'Teyzesi', 'no name: the relation word alone');
select tests.eq(public.output_person_name('{}'), '', 'nothing known: empty');
select tests.eq(has_function_privilege('anon', 'public.output_person_name(jsonb)', 'execute'), false, 'not callable by anon');

-- The film uses it for letter subtitles.
select tests.eq((select payload ->> 'subtitle'
                   from public.film_candidates(
                     jsonb_build_object(
                       'baby', jsonb_build_object('birth_date', current_date - 400),
                       'letters', jsonb_build_array(jsonb_build_object(
                         'id', gen_random_uuid(), 'title', 'Mektup', 'body', 'Sevgiler', 'written_on', current_date - 300,
                         'include_in_book', true,
                         'author', jsonb_build_object('name', 'Esra', 'relation', 'teyze')))),
                     '{}'::jsonb)
                  where kind = 'letter'),
                'Esra Teyzesi', 'film letter subtitle: Esra Teyzesi');
