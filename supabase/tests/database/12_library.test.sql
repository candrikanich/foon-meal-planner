-- Library screen (#18): add_catalog_meal copies a starter dish into the library, and
-- meal_history counts the nights a meal was on an approved plan.
begin;
select plan(18);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Fixtures: household A (planner Alice, member Bob), household B (planner Carol) ------------
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

insert into public.catalog_meals (id, slug, name, category, tags, servings, prep_steps) values
  ('00000000-0000-0000-0000-00000000ca01', 'test-tacos', 'Test tacos', 'Tex-Mex', '{quick,beginner}', 6,
   '[{"step": "thaw", "hours": 24}]');
insert into public.catalog_ingredients (catalog_meal_id, name, category, quantity_text, position) values
  ('00000000-0000-0000-0000-00000000ca01', 'ground beef', 'meat_seafood', '1 lb', 1),
  ('00000000-0000-0000-0000-00000000ca01', 'taco shells', 'pantry', null, 2),
  ('00000000-0000-0000-0000-00000000ca01', 'Cheddar cheese', 'dairy_eggs', '2 cups', 3);
-- Alice already has "Cheddar Cheese": the copy reuses it rather than adding a second item.
insert into public.items (id, household_id, canonical_name, category) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'cheddar cheese', 'dairy_eggs');

-- add_catalog_meal --------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
create temp table copied on commit drop as
  select * from public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000ca01');
grant select on copied to authenticated;

select is((select name from copied), 'Test tacos', 'the copy takes the dish name');
select is((select (servings, tags, catalog_meal_id, status)::text from copied),
  '(6,"{quick,beginner}",00000000-0000-0000-0000-00000000ca01,active)', 'servings, tags, and the catalog link carry over');
select is((select prep_steps from copied), '[{"step": "thaw", "hours": 24}]'::jsonb, 'prep steps carry over');
select results_eq(
  $$ select i.canonical_name, mi.quantity_text, mi.position::int
     from public.meal_ingredients mi join public.items i on i.id = mi.item_id
     where mi.meal_id = (select id from copied) order by mi.position $$,
  $$ values ('ground beef', '1 lb', 1), ('taco shells', null, 2), ('cheddar cheese', '2 cups', 3) $$,
  'ingredients copy in order with their quantities');
select is((select count(*)::int from public.items where household_id = '00000000-0000-0000-0000-0000000000a0'), 3,
  'an item the household already has is reused, not duplicated');
select is((public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000ca01')).id,
  (select id from copied), 'adding the same dish again returns the copy already in the library');
select is((select count(*)::int from public.meals where household_id = '00000000-0000-0000-0000-0000000000a0'), 1,
  'no second copy');
update public.meals set status = 'retired' where id = (select id from copied);
select is((public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000ca01')).status,
  'retired'::public.meal_status, 'a dish the dislike rule retired is returned as is, not copied fresh');
update public.meals set status = 'active' where id = (select id from copied);

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000ca01') $$,
  '42501', null, 'a member who is not a planner cannot add dishes');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ select public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000ca01') $$,
  '42501', null, 'a planner cannot add dishes to another household');
select throws_ok(
  $$ select public.add_catalog_meal('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-00000000dead') $$,
  'P0002', null, 'an unknown catalog dish is an error, not an empty meal');

set local role anon;
select throws_ok(
  $$ select public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000ca01') $$,
  '42501', null, 'anon cannot call add_catalog_meal');

-- meal_history ------------------------------------------------------------------------------
select pg_temp.as_admin();
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', current_date - 14, now()),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', current_date - 7, null),
  ('00000000-0000-0000-0000-0000000003a3', '00000000-0000-0000-0000-0000000000a0', current_date, now());
insert into public.plan_nights (household_id, plan_id, date, meal_id)
  select '00000000-0000-0000-0000-0000000000a0', plan_id, date, (select id from copied)
  from (values
    ('00000000-0000-0000-0000-0000000003a1'::uuid, current_date - 14),  -- made
    ('00000000-0000-0000-0000-0000000003a1'::uuid, current_date - 10),  -- made
    ('00000000-0000-0000-0000-0000000003a2'::uuid, current_date - 5),   -- never approved
    ('00000000-0000-0000-0000-0000000003a3'::uuid, current_date + 1)    -- not yet
  ) as nights (plan_id, date);

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select (times_made, last_made)::text from public.meal_history where meal_id = (select id from copied)),
  (2, current_date - 10)::text, 'history counts past nights of approved plans only');
select is((select household_id from public.meal_history where meal_id = (select id from copied)),
  '00000000-0000-0000-0000-0000000000a0'::uuid, 'history rows carry the household');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.meal_history), 0, 'another household sees none of this history');

set local role anon;
select throws_ok($$ select * from public.meal_history $$, '42501', null, 'anon cannot read history');

select pg_temp.as_admin();
select is((select reloptions from pg_class where oid = 'public.meal_history'::regclass),
  '{security_invoker=true}'::text[], 'the view runs with the reader''s row-level security');
select ok(not has_table_privilege('authenticated', 'public.meal_history', 'insert'), 'history is read-only');

select * from finish();
rollback;
