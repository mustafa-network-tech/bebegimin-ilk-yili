-- Same-family, two-baby context isolation. RLS intentionally grants Anne
-- access to both babies; detail reads must therefore bind baby_id and id.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

set role authenticated;
select tests.login(tests.id('anne'));

select tests.eq(
  tests.count($q$select 1 from memories where baby_id = tests.id('defne') and id = 'e0000000-0000-4000-8000-000000000001'$q$),
  1::bigint,
  'Defne route resolves Defne memory'
);
select tests.eq(
  tests.count($q$select 1 from memories where baby_id = tests.id('ege') and id = 'e0000000-0000-4000-8000-000000000001'$q$),
  0::bigint,
  'Ege route cannot resolve Defne memory id'
);
select tests.eq(
  tests.count($q$select 1 from media where baby_id = tests.id('ege') and memory_id = 'e0000000-0000-4000-8000-000000000001'$q$),
  0::bigint,
  'Ege media context cannot return Defne attachments'
);
select tests.eq(
  tests.count($q$select 1 from letters where baby_id = tests.id('ege') and id = 'c0000000-0000-4000-8000-000000000001'$q$),
  0::bigint,
  'Ege route cannot resolve Defne letter id'
);
select tests.eq(
  tests.count($q$select 1 from milestones where baby_id = tests.id('ege') and id = 'd0000000-0000-4000-8000-000000000001'$q$),
  0::bigint,
  'Ege route cannot resolve Defne milestone id'
);

reset role;
