-- Quick add (#20): create_meal makes a meal from a name and optional ingredient lines in one go.
begin;
select plan(11);

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

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
create temp table made on commit drop as
  select * from public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Taco night', 4::smallint, '{quick}', '{}',
                                   null, null,
                                   '[{"name": "ground beef", "quantity": "1 lb"}, {"name": "taco shells"}]');
grant select on made to authenticated;

select is((select (household_id, name, servings, tags, status, catalog_meal_id)::text from made),
  '(00000000-0000-0000-0000-0000000000a0,"Taco night",4,{quick},active,)', 'a planner quick-adds a meal');
select results_eq(
  $$ select i.canonical_name, mi.quantity_text from public.meal_ingredients mi join public.items i on i.id = mi.item_id
     where mi.meal_id = (select id from made) order by mi.position $$,
  $$ values ('ground beef', '1 lb'), ('taco shells', null) $$,
  'its ingredients are saved in order');
select is(
  (public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Leftover soup', 4::smallint, '{}', '{}', null, null,
                      '[]')).name,
  'Leftover soup', 'a name alone is enough');
select is((select count(*)::int from public.meal_ingredients mi join public.meals m on m.id = mi.meal_id
           where m.name = 'Leftover soup'), 0, 'with no ingredients yet');
select throws_ok(
  $$ select public.create_meal('00000000-0000-0000-0000-0000000000a0', '   ', 4::smallint, '{}', '{}', null, null, '[]') $$,
  '23514', null, 'a blank name is refused');

select throws_ok(
  $$ select public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Half made', 4::smallint, '{}', '{}', null, null,
       '[{"name": "this ingredient name is far too long to be stored as a single household item ok"}]') $$,
  '23514', null, 'a bad ingredient refuses the whole meal');
select is((select count(*)::int from public.meals where name = 'Half made'), 0, 'no half-made meal is left behind');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Mine', 4::smallint, '{}', '{}', null, null, '[]') $$,
  '42501', null, 'a member who is not a planner cannot add meals');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ select public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Mine', 4::smallint, '{}', '{}', null, null, '[]') $$,
  '42501', null, 'a planner cannot add meals to another household');
select is((select count(*)::int from public.meals where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'and sees nothing of that household');

set local role anon;
select throws_ok(
  $$ select public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Mine', 4::smallint, '{}', '{}', null, null, '[]') $$,
  '42501', null, 'anon cannot add meals');

select * from finish();
rollback;
