-- Notifications and privacy RPCs (account / baby deletion)
set role authenticated;

-- a new memory notifies the rest of the family, not the author, not other families
select tests.login(tests.id('anne'));
delete from notifications;
select tests.login(tests.id('teyze'));
insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Bildirim testi', current_date);
select tests.eq(tests.count($q$select 1 from notifications where body = 'Bildirim testi'$q$), 0::bigint, 'author is not notified');
select tests.login(tests.id('anne'));
select tests.eq((select title from notifications where body = 'Bildirim testi'), 'Teyzesi Zeynep yeni bir anı ekledi.', 'mother is notified with relation label');
update notifications set read_at = now() where body = 'Bildirim testi';
select tests.eq((select read_at is not null from notifications where body = 'Bildirim testi'), true, 'mark as read');
reset role;
select tests.eq((select title from notifications where body = 'Bildirim testi' and user_id = tests.id('anne')), 'Teyzesi Zeynep yeni bir anı ekledi.', 'only read_at is updatable');
set role authenticated;
select tests.expect_error($q$update notifications set title = 'hack'$q$, 'permission denied');
select tests.expect_error($q$insert into notifications (user_id, type, title) values (tests.id('baba'), 'family_activity', 'spam')$q$, 'permission denied');
-- notification preferences are respected
update profiles set notification_prefs = notification_prefs || '{"family_activity": false}' where id = tests.id('anne');
select tests.login(tests.id('teyze'));
insert into memories (baby_id, title, memory_date) values (tests.id('defne'), 'Sessiz test', current_date);
select tests.login(tests.id('anne'));
select tests.eq(tests.count($q$select 1 from notifications where body = 'Sessiz test'$q$), 0::bigint, 'muted notification type');
select tests.eq(public.has_baby_permission(tests.id('defne'), 'create_book'), true, 'admin implicitly has every permission');
reset role;

-- daily job is idempotent. Phase 13: the "archive complete" reminder fires
-- on the day the archive locks (375 days + approved extension), not on day 365.
select public.run_daily_jobs((select birth_date + 365 from babies where id = tests.id('defne')));
select tests.eq((select count(*) from notifications where type = 'book_ready' and baby_id = tests.id('defne')), 0::bigint,
                'no book reminder while the archive is still ACTIVE (day 365)');
select public.run_daily_jobs((select b.birth_date + 375 + coalesce((select e.requested_days::integer from baby_extension_requests e
                                                                     where e.baby_id = b.id and e.status = 'approved'), 0)
                                from babies b where b.id = tests.id('defne')));
select public.run_daily_jobs((select b.birth_date + 375 + coalesce((select e.requested_days::integer from baby_extension_requests e
                                                                     where e.baby_id = b.id and e.status = 'approved'), 0)
                                from babies b where b.id = tests.id('defne')));
select tests.eq((select count(*) from notifications where type = 'book_ready' and user_id = tests.id('baba')), 1::bigint, 'daily job dedupes');
select tests.eq((select count(*) from notifications where type = 'book_ready' and user_id = tests.id('teyze')), 0::bigint, 'book reminder only for book creators');
select tests.eq(public.tr_suffix('Defne', 'genitive'), 'Defne''nin', 'genitive Defne');
select tests.eq(public.tr_suffix('Can', 'genitive'), 'Can''ın', 'genitive Can');
select tests.eq(public.tr_suffix('Umut', 'genitive'), 'Umut''un', 'genitive Umut');
select tests.eq(public.tr_suffix('Öykü', 'genitive'), 'Öykü''nün', 'genitive Öykü');
select tests.eq(public.tr_suffix('Ege', 'dative'), 'Ege''ye', 'dative Ege');
select tests.eq(public.tr_suffix('Can', 'dative'), 'Can''a', 'dative Can');

-- privacy RPCs are not callable by clients
set role authenticated;
select tests.login(tests.id('anne'));
select tests.expect_error($q$select * from public.prepare_account_deletion(tests.id('baska'))$q$, 'permission denied');
select tests.expect_error($q$select * from public.delete_baby_for_user(tests.id('anne'), tests.id('can'))$q$, 'permission denied');
reset role;

select tests.logout();
-- service role: deleting Deniz's account removes Can (sole member) but not Defne
begin;
set local role service_role;
create temp table paths on commit drop as select * from public.prepare_account_deletion(tests.id('baska'), false);
select tests.eq((select count(*) from paths where path like 'cccccccc%'), 1::bigint, 'storage objects of the deleted baby are returned');
select tests.eq((select count(*) from babies where id = tests.id('can')), 0::bigint, 'sole-member baby deleted');
select tests.eq((select count(*) from babies where id = tests.id('defne')), 1::bigint, 'shared baby kept');
rollback;

-- last admin leaving => successor promoted
begin;
update family_members set is_admin = false where baby_id = tests.id('ege') and user_id = tests.id('baba');
set local role service_role;
select count(*) from public.prepare_account_deletion(tests.id('anne'), true);
select tests.eq((select is_admin from family_members where baby_id = tests.id('ege') and user_id = tests.id('baba')), true, 'father promoted to admin');
select tests.eq((select count(*) from memories where author_id = tests.id('anne')), 0::bigint, 'optional content deletion');
select tests.eq((select count(*) from storage_cleanup_queue where path like 'aaaaaaaa%') > 0, true, 'deleted media queued for storage cleanup');
rollback;

-- baby deletion by an admin
begin;
set local role service_role;
select tests.expect_error($q$select * from public.delete_baby_for_user(tests.id('teyze'), tests.id('defne'))$q$, 'only admins');
select tests.eq((select count(*) from public.delete_baby_for_user(tests.id('anne'), tests.id('defne'))) > 0, true, 'admin deletes baby, paths returned');
select tests.eq((select count(*) from family_members where baby_id = tests.id('defne')), 0::bigint, 'cascade removes family');
select tests.eq((select count(*) from memories where baby_id = tests.id('defne')), 0::bigint, 'cascade removes memories');
rollback;

-- deleting the auth user (last step of the Edge Function) cascades cleanly
begin;
select count(*) from public.prepare_account_deletion(tests.id('anne'), false);
delete from auth.users where id = tests.id('anne');
select tests.eq((select count(*) from family_members where user_id = tests.id('anne')), 0::bigint, 'memberships removed with the account');
select tests.eq((select count(*) from memories where baby_id = tests.id('defne') and author_id is null) > 0, true, 'family memories kept, author anonymised');
select tests.eq((select count(*) from family_members where baby_id = tests.id('ege') and is_admin), 1::bigint, 'Ege still has an admin');
rollback;
