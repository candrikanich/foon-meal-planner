-- Starter dishes' cook times (#146): the seeded list, copies picking it up, and the backfill for copies already made.
begin;
select plan(16);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.minutes(meal uuid) returns int language sql as $$
  select cook_minutes from public.meals where id = meal;
$$;

create function pg_temp.dish(dish_slug text) returns uuid language sql as $$
  select id from public.catalog_meals where slug = dish_slug;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner',
   'a0000000-0000-0000-0000-00000000000a');

-- The list -----------------------------------------------------------------------------------
select is((select count(*)::int from public.catalog_meals where cook_minutes is not null), 21, '21 starter dishes have a time');
select is_empty($$ select slug from public.catalog_meals
                   where cook_minutes is null and not (tags && '{quick,slow_cooker}') $$,
  'every dish with no fair guess has a time');
select is_empty($$ select slug from public.catalog_meals
                   where cook_minutes is not null and tags && '{quick,slow_cooker}' $$,
  'quick and slow cooker dishes keep their estimates');
select is_empty($$ select slug from public.catalog_meals where cook_minutes not between 20 and 120 $$,
  'the times are plausible for a weeknight dinner');
select is((select cook_minutes::int from public.catalog_meals where slug = 'lasagna'), 90, 'lasagna takes an hour and a half');

-- A new copy ---------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', pg_temp.dish('baked-ziti'))).cook_minutes::int, 60,
  'a dish added from the catalog comes with its time');
select is((public.add_catalog_meal('00000000-0000-0000-0000-0000000000a0', pg_temp.dish('tacos'))).cook_minutes, null,
  'a quick dish still has none of its own');
reset role;

-- Copies already made ------------------------------------------------------------------------
insert into public.meals (id, household_id, catalog_meal_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', pg_temp.dish('lasagna'), 'Lasagna');
insert into public.meals (id, household_id, catalog_meal_id, name, cook_minutes) values
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', pg_temp.dish('meatloaf-and-mashed-potatoes'),
   'Meatloaf', 120);
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', 'Grandma''s lasagna');
insert into public.meals (id, household_id, catalog_meal_id, name) values
  ('00000000-0000-0000-0000-0000000002a4', '00000000-0000-0000-0000-0000000000a0', pg_temp.dish('sausage-and-noodles'), 'Noodles');
-- Copies a family has made quick or slow cooker: the estimate fits them, and a real time would beat it.
insert into public.meals (id, household_id, catalog_meal_id, name, tags) values
  ('00000000-0000-0000-0000-0000000002a5', '00000000-0000-0000-0000-0000000000a0', pg_temp.dish('pork-tenderloin'),
   'Pork tenderloin', '{slow_cooker}'),
  ('00000000-0000-0000-0000-0000000002a6', '00000000-0000-0000-0000-0000000000a0', pg_temp.dish('homemade-mac-and-cheese'),
   'Mac', '{quick}');
insert into public.meals (id, household_id, catalog_meal_id, name) values
  ('00000000-0000-0000-0000-0000000002a7', '00000000-0000-0000-0000-0000000000a0', pg_temp.dish('potato-soup'),
   'Crockpot potato soup');

select public.backfill_catalog_cook_minutes();
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a1'), 90, 'a copy with no time gets the catalog''s');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a2'), 120, 'a time someone set stays');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a3'), null, 'a family''s own dish is left alone');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a4'), null, 'a copy of a dish with no catalog time stays empty');

select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a5'), null, 'a copy tagged slow cooker keeps its estimate');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a6'), null, 'a copy tagged quick keeps its estimate');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a7'), null, 'a copy named for the slow cooker keeps its estimate');

-- Only the migration runs it -----------------------------------------------------------------
select ok(not has_function_privilege('authenticated', 'public.backfill_catalog_cook_minutes()', 'execute'),
  'the app can''t run the backfill');
select ok(not has_function_privilege('anon', 'public.backfill_catalog_cook_minutes()', 'execute'),
  'nor can anyone signed out');

select * from finish();
rollback;
