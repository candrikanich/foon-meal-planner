-- Approve to weekly list (#26): approve_plan stamps the week and writes its weekly list in one transaction.
begin;
select plan(19);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'c0000000-0000-0000-0000-00000000000c');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Ground beef'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Cheddar cheese'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Cereal'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'Taco shells'),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'Saffron');

select has_column('public', 'list_items', 'quantity', 'list lines carry an amount');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
create temp table week on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
grant select on week to authenticated, anon;

-- Someone already put taco shells on the weekly list by hand.
insert into public.list_items (household_id, item_id, list, source) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4', 'weekly', 'manual');

select lives_ok(format($$ select public.approve_plan(%L, '[
    {"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "1 lb + 1 lb"},
    {"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "2 cups", "note": "Get dairy-free (Nora)"},
    {"item_id": "00000000-0000-0000-0000-0000000001a3", "staple": true},
    {"item_id": "00000000-0000-0000-0000-0000000001a4"}
  ]') $$, (select id from week)), 'a planner approves the week');
select isnt((select approved_at from public.plans where id = (select id from week)), null, 'the week is stamped approved');
select results_eq(
  $$ select i.canonical_name, l.source::text, l.quantity, l.note from public.list_items l
     join public.items i on i.id = l.item_id where l.list = 'weekly' and l.checked_at is null order by i.canonical_name $$,
  $$ values ('Cereal', 'staple', null::text, null::text),
            ('Cheddar cheese', 'plan', '2 cups', 'Get dairy-free (Nora)'),
            ('Ground beef', 'plan', '1 lb + 1 lb', null),
            ('Taco shells', 'manual', null, null) $$,
  'the weekly list holds the plan''s lines; a hand-added line stays as it was');

-- A swap later: beef is gone, cheese changes. Approving again updates the list.
update public.list_items set checked_at = now() where item_id = '00000000-0000-0000-0000-0000000001a3';
select lives_ok(format($$ select public.approve_plan(%L, '[
    {"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "3 cups"}
  ]') $$, (select id from week)), 'approving again after a swap');
select results_eq(
  $$ select i.canonical_name, l.quantity, l.note from public.list_items l join public.items i on i.id = l.item_id
     where l.list = 'weekly' and l.checked_at is null order by i.canonical_name $$,
  $$ values ('Cheddar cheese', '3 cups', null::text), ('Taco shells', null, null) $$,
  'the plan''s stale lines go, its lines update, hand-added lines stay');
select is((select count(*)::int from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3'
           and checked_at is not null), 1, 'a line already bought is left alone');

-- Bought this week: approving again doesn't put it back.
select lives_ok(format($$ select public.approve_plan(%L, '[
    {"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "3 cups"},
    {"item_id": "00000000-0000-0000-0000-0000000001a3", "staple": true}
  ]') $$, (select id from week)), 'approving again with an item already bought');
select is((select count(*)::int from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3'
           and checked_at is null), 0, 'what was bought for this week isn''t listed again');

-- Next week's approval leaves this week's lines alone.
create temp table next_week on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-08');
grant select on next_week to authenticated, anon;
select lives_ok(format($$ select public.approve_plan(%L, '[
    {"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "2 lb"}
  ]') $$, (select id from next_week)), 'a planner approves next week');
select is((select count(*)::int from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2'
           and checked_at is null), 1, 'this week''s cheese is still on the list');
delete from public.list_items where plan_id = (select id from next_week);

select throws_ok(format($$ select public.approve_plan(%L, '[{"item_id": "00000000-0000-0000-0000-0000000001b1"}]') $$,
  (select id from week)), '23503', null, 'another household''s item cannot be listed');
select throws_ok(format($$ select public.approve_plan(%L, '[{"item_id": "00000000-0000-0000-0000-0000000001a1",
  "quantity": "%s"}]') $$, (select id from week), repeat('x', 61)), '23514', null, 'amounts stay short');
select throws_ok(format($$ select public.approve_plan(%L, '{"item_id": "x"}') $$, (select id from week)),
  '22023', null, 'lines must be a JSON array');
select is((select count(*)::int from public.list_items where list = 'weekly' and checked_at is null), 2,
  'a refused approval changes nothing');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(format($$ select public.approve_plan(%L, '[]') $$, (select id from week)),
  '42501', null, 'a member who is not a planner cannot approve');
select is((select count(*)::int from public.list_items where list = 'weekly'), 3, 'members read the list');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(format($$ select public.approve_plan(%L, '[]') $$, (select id from week)),
  'P0002', null, 'another household''s plan is not found');

set local role anon;
select throws_ok(format($$ select public.approve_plan(%L, '[]') $$, (select id from week)),
  '42501', null, 'anon cannot approve');

select * from finish();
rollback;
