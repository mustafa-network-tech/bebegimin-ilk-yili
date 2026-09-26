-- Storage object policies and the book export pipeline
set role authenticated;

select tests.login(tests.id('teyze'));
select tests.eq(public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original.jpg'), true, 'member signs family photo');
select tests.eq(public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/other.jpg'), false, 'only the registered file of a media row is readable');
select tests.eq(public.can_read_baby_object('cccccccc-cccc-4ccc-8ccc-cccccccccccc/f0000000-0000-4000-8000-000000000005/original.jpg'), false, 'wrong baby prefix');
select tests.eq(public.can_read_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000005/original.jpg'), false, 'media id of another baby under own baby prefix');
-- upload flow: row first (uploading), then object
select tests.eq(public.can_write_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f2000000-0000-4000-8000-000000000002/p.jpg'), true, 'uploader may write the file of own pending row');
insert into storage.objects (bucket_id, name) values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f2000000-0000-4000-8000-000000000002/p.jpg');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/f0000000-0000-4000-8000-000000000001/original2.jpg')$q$, 'row-level security');
select tests.expect_error($q$insert into storage.objects (bucket_id, name) values ('baby-media', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/x.jpg')$q$, 'row-level security');
-- pending media of someone else is invisible to the family
select tests.login(tests.id('baba'));
select tests.eq(tests.count($q$select 1 from media where id = 'f2000000-0000-4000-8000-000000000002'$q$), 0::bigint, 'uploading media hidden from others');
select tests.login(tests.id('teyze'));
update media set status = 'ready' where id = 'f2000000-0000-4000-8000-000000000002';
select tests.login(tests.id('baba'));
select tests.eq(tests.count($q$select 1 from media where id = 'f2000000-0000-4000-8000-000000000002'$q$), 1::bigint, 'ready media visible to family');
-- storage_path is immutable after insert
update media set storage_path = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc/x/y.jpg' where id = 'f0000000-0000-4000-8000-000000000002';
select tests.eq((select storage_path like 'aaaaaaaa%' from media where id = 'f0000000-0000-4000-8000-000000000002'), true, 'storage_path immutable');
-- admin profile photo upload
select tests.eq(public.can_write_baby_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/profile/avatar-1.jpg'), true, 'admin may upload baby avatar');
select tests.expect_error($q$update babies set avatar_path = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc/profile/a.jpg' where id = tests.id('defne')$q$, 'invalid avatar_path');
-- own avatar bucket
insert into storage.objects (bucket_id, name) values ('avatars', '22222222-2222-4222-8222-222222222222/me.jpg');
select tests.login(tests.id('teyze'));
select tests.eq(public.can_read_avatar_object('22222222-2222-4222-8222-222222222222/me.jpg'), true, 'family can see each other''s avatar');
select tests.login(tests.id('baska'));
select tests.eq(public.can_read_avatar_object('44444444-4444-4444-8444-444444444444/me.jpg'), true, 'own avatar');

-- books
select tests.login(tests.id('anne'));
insert into book_projects (id, baby_id, title) values ('a3000000-0000-4000-8000-000000000001', tests.id('defne'), 'Defne''nin İlk Yılı');
insert into book_pages (id, project_id, baby_id, page_type, month_index, title, sort_order)
  values ('a3100000-0000-4000-8000-000000000001', 'a3000000-0000-4000-8000-000000000001', tests.id('defne'), 'cover', null, 'Kapak', 0),
         ('a3100000-0000-4000-8000-000000000002', 'a3000000-0000-4000-8000-000000000001', tests.id('defne'), 'month', 1, '1. Ayım', 1);
select tests.expect_error($q$insert into book_pages (project_id, baby_id, page_type, month_index, title, sort_order)
  values ('a3000000-0000-4000-8000-000000000001', tests.id('defne'), 'month', 1, 'Tekrar', 2)$q$, 'duplicate key');
select tests.expect_error($q$insert into book_pages (project_id, baby_id, page_type, title, sort_order)
  values ('a3000000-0000-4000-8000-000000000001', tests.id('can'), 'custom', 'IDOR', 3)$q$, 'row-level security');
insert into book_items (page_id, baby_id, item_type, media_id)
  values ('a3100000-0000-4000-8000-000000000002', tests.id('defne'), 'media', 'f0000000-0000-4000-8000-000000000001');
select tests.expect_error($q$insert into book_items (page_id, baby_id, item_type, media_id)
  values ('a3100000-0000-4000-8000-000000000002', tests.id('defne'), 'media', 'f0000000-0000-4000-8000-000000000005')$q$, 'foreign key');
select tests.eq(public.can_write_book_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/v1.pdf'), true, 'book creator may upload pdf');
select tests.eq((select version from public.register_book_export('a3000000-0000-4000-8000-000000000001',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/v1.pdf', 40, 1000000)), 1, 'first export is version 1');
select tests.eq((select version from public.register_book_export('a3000000-0000-4000-8000-000000000001',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/v2.pdf', 42, 1100000)), 2, '"Kitabı güncelle" creates version 2');
update book_projects set current_version = 99 where id = 'a3000000-0000-4000-8000-000000000001';
select tests.eq((select current_version from book_projects where id = 'a3000000-0000-4000-8000-000000000001'), 2, 'version cannot be forged');
select tests.expect_error($q$insert into book_exports (project_id, baby_id, version, format, storage_path, page_count)
  values ('a3000000-0000-4000-8000-000000000001', tests.id('defne'), 7, 'a4_portrait', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/x.pdf', 1)$q$, 'permission denied');

select tests.login(tests.id('teyze'));   -- view_album but not create_book
select tests.eq(tests.count('select 1 from book_exports'), 2::bigint, 'family can list generated books');
select tests.eq(tests.count('select 1 from book_pages'), 0::bigint, 'editor pages hidden without create_book');
select tests.eq(public.can_read_book_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/v2.pdf'), true, 'family can download the book');
select tests.eq(public.can_write_book_object('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/v3.pdf'), false, 'no create_book => no upload');
select tests.expect_error($q$select public.register_book_export('a3000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a3000000-0000-4000-8000-000000000001/v3.pdf', 1, 1)$q$, 'not found');

select tests.login(tests.id('anne'));
select tests.eq(tests.count($q$select 1 from notifications where type = 'book_generated'$q$) >= 1, false, 'book creator herself is not notified');
select tests.login(tests.id('baba'));
select tests.eq(tests.count($q$select 1 from notifications where type = 'book_generated'$q$), 2::bigint, 'family is notified for each book version');
reset role;
