-- =====================================================================
-- DEMO / DEVELOPMENT SEED — never run against production.
--
-- `supabase db reset` (local) runs this file automatically after the
-- migrations. `supabase db push` (remote) does NOT run it.
--
-- Demo accounts (password for all: Demo1234!)
--   anne@example.com   Elif  — Defne & Ege's mother (admin)
--   baba@example.com   Mert  — father (admin)
--   teyze@example.com  Zeynep — aunt (limited permissions, only Defne)
--   baska@example.com  Deniz — a DIFFERENT family (baby Can), for isolation
-- Photos only have metadata; the app shows a placeholder until files exist.
-- =====================================================================

do $$
declare
  v_has_gotrue boolean := exists (
    select 1 from information_schema.columns
    where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password');
  r record;
begin
  if current_setting('app.environment', true) = 'production' then
    raise exception 'refusing to seed demo data into production';
  end if;

  for r in select * from (values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'anne@example.com', 'Elif'),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'baba@example.com', 'Mert'),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'teyze@example.com', 'Zeynep'),
    ('44444444-4444-4444-8444-444444444444'::uuid, 'baska@example.com', 'Deniz')
  ) as t(id, email, name)
  loop
    if v_has_gotrue then
      execute $sql$
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
          email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
          confirmation_token, email_change, email_change_token_new, recovery_token)
        values ('00000000-0000-0000-0000-000000000000', $1, 'authenticated', 'authenticated', $2,
          extensions.crypt('Demo1234!', extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', jsonb_build_object('display_name', $3::text),
          now(), now(), '', '', '', '')
        on conflict (id) do nothing
      $sql$ using r.id, r.email, r.name;
      execute $sql$
        insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
        values (gen_random_uuid(), $1, $1::text, jsonb_build_object('sub', $1::text, 'email', $2::text), 'email', now(), now(), now())
        on conflict do nothing
      $sql$ using r.id, r.email;
    else
      insert into auth.users (id, email, raw_user_meta_data)
      values (r.id, r.email, jsonb_build_object('display_name', r.name))
      on conflict (id) do nothing;
    end if;
  end loop;
end;
$$;

update public.profiles set onboarding_completed = true
 where id in ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
              '33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444');

-- Babies (dates are relative so the demo always "looks alive") -----------------------
insert into public.babies (id, first_name, last_name, birth_date, birth_time, birth_place,
                           birth_weight_grams, birth_length_cm, story, created_by)
values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Defne', 'Yılmaz', current_date - 400, '04:35', 'İstanbul',
   3250, 50.5, 'Bir sonbahar sabahı, gün doğmadan geldin ve her şey değişti.', '11111111-1111-4111-8111-111111111111'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Ege', 'Yılmaz', current_date - 120, '15:10', 'İstanbul',
   3480, 51.0, 'Ablasının en sevdiği oyuncak.', '11111111-1111-4111-8111-111111111111'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'Can', 'Kaya', current_date - 200, null, 'İzmir',
   3100, 49.0, null, '44444444-4444-4444-8444-444444444444');

insert into public.family_members (baby_id, user_id, relation, is_admin, permissions) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111', 'anne', true, array(select key from public.permissions)),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222', 'baba', true, array(select key from public.permissions)),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '33333333-3333-4333-8333-333333333333', 'teyze', false,
     '{view_memories,view_album,add_memory,edit_own_memory,add_photo,comment,write_letter}'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '11111111-1111-4111-8111-111111111111', 'anne', true, array(select key from public.permissions)),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222', 'baba', true, array(select key from public.permissions)),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '44444444-4444-4444-8444-444444444444', 'anne', true, array(select key from public.permissions));

-- Milestones --------------------------------------------------------------------------------
insert into public.milestones (id, baby_id, milestone_type_id, achieved_on, description, created_by)
select m.id::uuid, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', t.id, current_date - 400 + m.day_offset, m.descr,
       m.author::uuid
from (values
  ('d0000000-0000-4000-8000-000000000001', 'first_bath',     2,  'İlk banyonda hiç ağlamadın, sadece şaşkın şaşkın baktın.', '11111111-1111-4111-8111-111111111111'),
  ('d0000000-0000-4000-8000-000000000002', 'first_smile',    38, 'Babana bakıp kocaman gülümsedin. Hepimiz eridik.', '22222222-2222-4222-8222-222222222222'),
  ('d0000000-0000-4000-8000-000000000003', 'first_laugh',    104, 'Teyzen yüzünü saklayınca kahkahalarla güldün.', '11111111-1111-4111-8111-111111111111'),
  ('d0000000-0000-4000-8000-000000000004', 'first_tooth',    190, 'Alt ön dişin çıktı, geceler biraz zor geçti.', '11111111-1111-4111-8111-111111111111'),
  ('d0000000-0000-4000-8000-000000000005', 'first_sat_up',   205, 'Desteksiz oturdun ve çok gururlandın.', '22222222-2222-4222-8222-222222222222'),
  ('d0000000-0000-4000-8000-000000000006', 'first_crawl',    250, 'Salonun bir ucundan öbür ucuna kedinin peşinden.', '11111111-1111-4111-8111-111111111111'),
  ('d0000000-0000-4000-8000-000000000007', 'first_word',     300, '"Baba" dedin. Annen biraz kıskandı :)', '22222222-2222-4222-8222-222222222222'),
  ('d0000000-0000-4000-8000-000000000008', 'first_steps',    335, 'Üç adım! Sonra poposunun üstüne oturdun ve güldün.', '11111111-1111-4111-8111-111111111111'),
  ('d0000000-0000-4000-8000-000000000009', 'first_birthday', 365, 'Bir yaşındasın! Pastanın yarısı yüzündeydi.', '11111111-1111-4111-8111-111111111111')
) as m(id, type_key, day_offset, descr, author)
join public.milestone_types t on t.key = m.type_key;

-- Memories (spread over the first year and after it) ----------------------------------------------
insert into public.memories (id, baby_id, author_id, title, body, memory_date, memory_time, category, milestone_id)
values
  ('e0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'Hoş geldin Defne', 'Saat 04:35''te dünyaya geldin. Minik parmaklarınla parmağımı tuttun.', current_date - 400, '04:35', 'special_day', null),
  ('e0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'Eve ilk gelişimiz', 'Kapıda seni bekleyen balonlar ve heyecanlı bir kedi vardı.', current_date - 397, '14:00', 'family', null),
  ('e0000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '33333333-3333-4333-8333-333333333333',
   'Teyzenle ilk tanışma', 'Seni kucağıma aldığımda dünya durdu sanki.', current_date - 395, null, 'family', null),
  ('e0000000-0000-4000-8000-000000000004', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'İlk gülümseme', 'Bu anı hiç unutmayacağız.', current_date - 362, '09:15', 'first', 'd0000000-0000-4000-8000-000000000002'),
  ('e0000000-0000-4000-8000-000000000005', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'Parkta ilk sonbahar yürüyüşü', 'Puset içinde yapraklara bakıp durdun.', current_date - 340, null, 'moment', null),
  ('e0000000-0000-4000-8000-000000000006', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'İlk bayramın', 'Dedenin elini öptün (biz öptürdük).', current_date - 280, null, 'special_day', null),
  ('e0000000-0000-4000-8000-000000000007', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'İlk ek gıda: havuç püresi', 'Yüzünü buruşturdun ama sonra hepsini yedin.', current_date - 220, '12:30', 'growth', null),
  ('e0000000-0000-4000-8000-000000000008', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'İlk deniz', 'Ayaklarını suya değdirince çığlık attın, sonra bir daha istedin.', current_date - 160, '11:00', 'travel', null),
  ('e0000000-0000-4000-8000-000000000009', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '33333333-3333-4333-8333-333333333333',
   'Teyzeyle pazar kahvaltısı', 'Simidin yarısını yedin, yarısını kediye verdin.', current_date - 120, null, 'family', null),
  ('e0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'İlk doğum günü partisi', 'Tüm aile toplandı, pastanın mumunu baban üfledi.', current_date - 35, '16:00', 'special_day', null),
  -- added AFTER the first year but dated inside it (forgotten memory):
  ('e0000000-0000-4000-8000-00000000000b', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'Unutulmuş bir an: ilk kar', 'Pencereden karı izlerken elini cama dayamıştın.', current_date - 300, null, 'first', null),
  -- life goes on after the first birthday:
  ('e0000000-0000-4000-8000-00000000000c', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'İlk salıncak keyfi', 'Parkta salıncaktan inmek istemedin.', current_date - 10, null, 'moment', null),
  ('e0000000-0000-4000-8000-00000000000d', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '11111111-1111-4111-8111-111111111111',
   'Ege aramıza katıldı', 'Defne abla seni ilk gördüğünde "bebe" dedi.', current_date - 120, '15:10', 'special_day', null),
  ('e0000000-0000-4000-8000-00000000000e', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', '44444444-4444-4444-8444-444444444444',
   'Can''ın gizli anısı', 'Bu anı yalnızca Can''ın ailesine aittir.', current_date - 150, null, 'moment', null);

-- Photo metadata ---------------------------------------------------------------------------------------
insert into public.media (id, baby_id, uploader_id, memory_id, milestone_id, kind, storage_path, thumb_path,
                          mime_type, width, height, size_bytes, caption, taken_on, tags, status)
values
  ('f0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'e0000000-0000-4000-8000-000000000001', null, 'photo',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/thumb.jpg',
   'image/jpeg', 3024, 4032, 2400000, 'Doğum günün, ilk fotoğrafın', current_date - 400, '{hastane,ilk gün}', 'ready'),
  ('f0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'e0000000-0000-4000-8000-000000000002', null, 'photo',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000002/original.jpg',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000002/thumb.jpg',
   'image/jpeg', 4032, 3024, 2800000, 'Evdeki ilk günün', current_date - 397, '{ev}', 'ready'),
  ('f0000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   null, 'd0000000-0000-4000-8000-000000000008', 'photo',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000003/original.jpg',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000003/thumb.jpg',
   'image/jpeg', 3024, 4032, 2600000, 'İlk adımlar', current_date - 65, '{ilkler}', 'ready'),
  ('f0000000-0000-4000-8000-000000000004', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'e0000000-0000-4000-8000-000000000008', null, 'video',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000004/original.mp4',
   null, 'video/mp4', 1920, 1080, 18000000, 'Denizle tanışma', current_date - 160, '{deniz,tatil}', 'ready'),
  ('f0000000-0000-4000-8000-000000000005', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', '44444444-4444-4444-8444-444444444444',
   'e0000000-0000-4000-8000-00000000000e', null, 'photo',
   'cccccccc-cccc-4ccc-8ccc-cccccccccccc/f0000000-0000-4000-8000-000000000005/original.jpg',
   null, 'image/jpeg', 3024, 4032, 2000000, 'Başka ailenin fotoğrafı', current_date - 150, '{}', 'ready');

-- Letters ------------------------------------------------------------------------------------------------------
insert into public.letters (id, baby_id, author_id, author_name, author_relation, title, body, written_on)
values
  ('c0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'Elif', 'anne', 'Sevgili kızım',
   'Bugün seni ilk kez kucağıma aldım. O an bütün korkularım bir anda kayboldu. Hep yanında olacağım.', current_date - 400),
  ('c0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '33333333-3333-4333-8333-333333333333',
   'Zeynep', 'teyze', 'Teyzesinin bir tanesi',
   'Büyüdüğünde birlikte çok gezeceğiz. Sana dünyanın en güzel yerlerini göstereceğim.', current_date - 390),
  ('c0000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'Mert', 'baba', 'Bir yaşına girerken',
   'Bir yıl önce hayatımıza girdin ve her günü bir bayrama çevirdin. İyi ki doğdun.', current_date - 35);

-- Time capsules: one sealed until 18, one already opened (for demo) ---------------------------------------------------
insert into public.time_capsules (id, baby_id, author_id, author_name, author_relation, title, occasion, open_on, created_at)
values
  ('b0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111',
   'Elif', 'anne', '18. yaş gününde aç', 'age_18', (current_date - 400) + interval '18 years', now() - interval '300 days'),
  ('b0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222',
   'Mert', 'baba', 'İlk doğum gününde aç', 'custom', current_date - 35, now() - interval '380 days');

insert into public.time_capsule_contents (capsule_id, baby_id, body) values
  ('b0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'Bu mektubu 18 yaşında okuyorsun. Seninle ne kadar gurur duyduğumu bil.'),
  ('b0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'Bir yaşındasın! Bu kapsülü doğduğun hafta yazdım.');

-- Comments ---------------------------------------------------------------------------------------------------------------
insert into public.comments (baby_id, author_id, memory_id, body) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '33333333-3333-4333-8333-333333333333', 'e0000000-0000-4000-8000-000000000001', 'Hayatımıza hoş geldin minik kuş 🤍');
insert into public.comments (baby_id, author_id, milestone_id, body) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000008', 'Aile notu: o gün herkes ağladı :)');

-- A pending invitation (code shown in the app's family screen)
insert into public.family_invitations (baby_id, code, relation, permissions, created_by)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'DEDE2DAVET', 'dede',
        '{view_memories,view_album,comment,write_letter}', '11111111-1111-4111-8111-111111111111');

-- The inserts above generated "new content" notifications; start the demo
-- with a clean, realistic inbox instead.
delete from public.notifications;
insert into public.notifications (user_id, baby_id, type, title, body, data) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'family_activity',
   'Teyzesi Zeynep yeni bir anı ekledi.', 'Teyzeyle pazar kahvaltısı',
   '{"target_type":"memories","target_id":"e0000000-0000-4000-8000-000000000009"}'),
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'book_ready',
   'Defne''nin İlk Yılım kitabı oluşturulmaya hazır 📖', 'İlk 365 günün tüm anıları bir kitapta buluşsun.', '{}');
