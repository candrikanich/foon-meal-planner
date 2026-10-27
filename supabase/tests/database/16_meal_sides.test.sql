-- Side dish pairings (#32): a meal's sides are other library meals or simple items, saved with the meal.
begin;
select plan(21);

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
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Spaghetti'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Caesar salad'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Carters'' secret bread');

select ok((select relrowsecurity from pg_class where oid = 'public.meal_sides'::regclass), 'RLS on meal_sides');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[{"name": "spaghetti"}]',
       '[{"meal_id": "00000000-0000-0000-0000-0000000002a2"}, {"name": " Garlic bread "}, {"name": "  "}]') $$,
  'a planner saves sides with the meal');
select results_eq(
  $$ select s.side_meal_id, i.canonical_name, s.position::int from public.meal_sides s
     left join public.items i on i.id = s.item_id
     where s.meal_id = '00000000-0000-0000-0000-0000000002a1' order by s.position $$,
  $$ values ('00000000-0000-0000-0000-0000000002a2'::uuid, null::text, 1), (null, 'Garlic bread', 2) $$,
  'a side is a library meal or an item, in order; blank names are skipped');
select lives_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[{"name": "spaghetti"}]') $$,
  'saving without sides still works (older callers)');
select is((select count(*)::int from public.meal_sides where meal_id = '00000000-0000-0000-0000-0000000002a1'), 2,
  'and leaves the sides as they were');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '[{"meal_id": "00000000-0000-0000-0000-0000000002a1"}]') $$,
  '23514', null, 'a meal is not its own side');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '[{"meal_id": "00000000-0000-0000-0000-0000000002b1"}]') $$,
  '23503', null, 'a side cannot be another household''s meal');
select lives_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '[{"name": "Salad"}, {"name": "salad"}, {"meal_id": "00000000-0000-0000-0000-0000000002a2"},
               {"meal_id": "00000000-0000-0000-0000-0000000002a2"}]') $$,
  'repeated sides are saved once');
select is((select count(*)::int from public.meal_sides where meal_id = '00000000-0000-0000-0000-0000000002a1'), 2,
  'one per side');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '{"name": "not an array"}') $$,
  '22023', null, 'sides must be a JSON array');
update public.meals set status = 'retired' where id = '00000000-0000-0000-0000-0000000002a2';
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '[{"meal_id": "00000000-0000-0000-0000-0000000002a2"}]') $$,
  '42501', null, 'a retired meal is not a side');
update public.meals set status = 'archived' where id = '00000000-0000-0000-0000-0000000002a2';
select lives_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '[{"name": "Salad"}, {"meal_id": "00000000-0000-0000-0000-0000000002a2"}]') $$,
  'an archived meal can still be a side');
update public.meals set status = 'active' where id = '00000000-0000-0000-0000-0000000002a2';

-- copy_meal keeps the sides ------------------------------------------------------------------
create temp table copied on commit drop as
  select * from public.copy_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti (copy)');
grant select on copied to authenticated;
select is((select count(*)::int from public.meal_sides where meal_id = (select id from copied)), 2,
  'Copy and tweak keeps the sides');

-- Reads and writes ---------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.meal_sides where meal_id = '00000000-0000-0000-0000-0000000002a1'), 2,
  'members read sides');
select throws_ok(
  $$ insert into public.meal_sides (household_id, meal_id, side_meal_id) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000002a1') $$,
  '42501', null, 'members do not add sides');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Spaghetti', 4::smallint, '{}', '{}', null, null,
       '[]', '[]') $$,
  '42501', null, 'members do not save meals');
delete from public.meal_sides where meal_id = '00000000-0000-0000-0000-0000000002a1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.meal_sides where meal_id = '00000000-0000-0000-0000-0000000002a1'), 2,
  'members do not remove sides');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.meal_sides), 0, 'another household sees no sides');
delete from public.meal_sides;
select throws_ok(
  $$ insert into public.meal_sides (household_id, meal_id, side_meal_id) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000002a2') $$,
  '42501', null, 'another household''s planner cannot add sides');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.meal_sides where meal_id = '00000000-0000-0000-0000-0000000002a1'), 2,
  'another household''s planner does not remove sides');

set local role anon;
select throws_ok($$ select * from public.meal_sides $$, '42501', null, 'anon cannot read sides');

select * from finish();
rollback;
