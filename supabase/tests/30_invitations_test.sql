-- Invitation lifecycle
set role authenticated;

-- preview & accept the demo invitation as the stranger (Deniz joins Defne as "dede")
select tests.login(tests.id('baska'));
select tests.eq((select baby_first_name from public.preview_invitation('dede2davet')), 'Defne', 'preview is case-insensitive and shows only the first name');
select tests.eq((select public.accept_invitation(' DEDE2DAVET ')), tests.id('defne'), 'accept returns the baby id');
select tests.eq(tests.count($q$select 1 from babies where id = tests.id('defne')$q$), 1::bigint, 'new member can now see the baby');
select tests.eq((select relation from family_members where baby_id = tests.id('defne') and user_id = tests.id('baska')), 'dede', 'relation copied from invitation');
select tests.eq((select is_admin from family_members where baby_id = tests.id('defne') and user_id = tests.id('baska')), false, 'invitee is not admin');
select tests.eq((select 'add_memory' = any(permissions) from family_members where baby_id = tests.id('defne') and user_id = tests.id('baska')), false, 'invitee gets only invited permissions');
select tests.expect_error($q$select public.accept_invitation('DEDE2DAVET')$q$, 'invitation_accepted');
select tests.eq(tests.count($q$select 1 from memories where baby_id = tests.id('can')$q$), 1::bigint, 'Deniz still sees own baby');

-- admin creates invitations; codes are random and well-formed
select tests.login(tests.id('anne'));
insert into family_invitations (id, baby_id, relation, permissions)
  values ('a2000000-0000-4000-8000-000000000001', tests.id('defne'), 'hala', '{view_memories,view_album}');
select tests.eq((select code ~ '^[A-HJ-NP-Z2-9]{10}$' from family_invitations where id = 'a2000000-0000-4000-8000-000000000001'), true, 'generated code format');
select tests.eq((select created_by from family_invitations where id = 'a2000000-0000-4000-8000-000000000001'), tests.id('anne'), 'created_by forced');
select tests.eq((select count(distinct public.generate_invite_code()) from generate_series(1, 2000)), 2000::bigint, '2000 generated codes are unique');

-- revoke
insert into family_invitations (id, baby_id, code, relation) values ('a2000000-0000-4000-8000-000000000003', tests.id('ege'), 'REV2KED222', 'hala');
select public.revoke_invitation('a2000000-0000-4000-8000-000000000003');
select public.revoke_invitation('a2000000-0000-4000-8000-000000000001');
select tests.login(tests.id('teyze'));
select tests.expect_error($q$select public.accept_invitation('REV2KED222')$q$, 'invitation_revoked');
select tests.expect_error($q$select public.revoke_invitation('a2000000-0000-4000-8000-000000000003')$q$, 'not found');
reset role;
select tests.eq((select status from family_invitations where id = 'a2000000-0000-4000-8000-000000000001'), 'revoked', 'revoked invitation status');

-- expired
insert into family_invitations (id, baby_id, code, relation, created_at, expires_at)
  values ('a2000000-0000-4000-8000-000000000002', tests.id('ege'), 'EXP2RED222', 'teyze', now() - interval '10 days', now() - interval '1 day');
set role authenticated;
select tests.login(tests.id('teyze'));
select tests.eq(tests.count($q$select 1 from public.preview_invitation('EXP2RED222')$q$), 0::bigint, 'expired invitation has no preview');
select tests.expect_error($q$select public.accept_invitation('EXP2RED222')$q$, 'invitation_expired');
select tests.expect_error($q$select public.accept_invitation('NNNNNNNNNN')$q$, 'invitation_not_found');

-- e-mail bound invitation
reset role;
insert into family_invitations (baby_id, code, relation, invited_email)
  values (tests.id('ege'), 'MA2LBND222', 'teyze', 'Someone.Else@Example.com');
set role authenticated;
select tests.expect_error($q$select public.accept_invitation('MA2LBND222')$q$, 'invitation_email_mismatch');

-- a non-admin with invite_members cannot invite admins
select tests.login(tests.id('anne'));
update family_members set permissions = permissions || '{invite_members}'::text[] where user_id = tests.id('teyze') and baby_id = tests.id('defne');
select tests.login(tests.id('teyze'));
select tests.expect_error($q$insert into family_invitations (baby_id, relation, is_admin) values (tests.id('defne'), 'amca', true)$q$, 'only admins');
select tests.expect_error($q$insert into family_invitations (baby_id, relation, permissions) values (tests.id('defne'), 'amca', '{manage_members}')$q$, 'only admins');
insert into family_invitations (baby_id, relation) values (tests.id('defne'), 'amca');
select tests.eq(tests.count('select 1 from family_invitations where relation = ''amca'''), 1::bigint, 'inviter with permission can invite a regular member');
insert into family_invitations (id, baby_id, relation, status, accepted_by) values ('a2000000-0000-4000-8000-000000000009', tests.id('defne'), 'amca', 'accepted', tests.id('baska'));
select tests.eq((select status || coalesce(accepted_by::text, '') from family_invitations where id = 'a2000000-0000-4000-8000-000000000009'), 'pending', 'forged invitation status is neutralised');

-- multi-child: admin adds a member of a sibling's family directly
select tests.login(tests.id('anne'));
select tests.eq((select public.add_member_from_sibling(tests.id('ege'), tests.id('teyze'), 'teyze', null, '{view_memories,view_album}') is not null), true, 'admin adds sibling family member');
select tests.expect_error($q$select public.add_member_from_sibling(tests.id('ege'), '99999999-9999-4999-8999-999999999999', 'teyze')$q$, 'not in any of your other families');
select tests.login(tests.id('teyze'));
select tests.expect_error($q$select public.add_member_from_sibling(tests.id('defne'), tests.id('baska'), 'teyze')$q$, 'only admins');
reset role;
