-- Catalog (shared, read-only) and household library: meals, items, meal ingredients (#5).
begin;
select plan(48);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Fixtures: household A (planner Alice, member Bob), household B (planner Carol) -----------
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
-- Household D is mid-onboarding: Dave owns it but hasn't added his own profile yet.
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000d0', 'Daltons', 'd0000000-0000-0000-0000-00000000000d');
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'c0000000-0000-0000-0000-00000000000c');

insert into public.catalog_meals (id, slug, name, category, tags, popular, servings) values
  ('00000000-0000-0000-0000-00000000ca01', 'test-tacos', 'Test tacos', 'Tex-Mex', '{quick,beginner}', true, 4);
insert into public.catalog_ingredients (catalog_meal_id, name, category, quantity_text, position) values
  ('00000000-0000-0000-0000-00000000ca01', 'ground beef', 'meat_seafood', '1 lb', 1);

insert into public.items (id, household_id, canonical_name, category) values
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'saffron', 'pantry');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Paella');

-- Schema shape ------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.catalog_meals'::regclass, 'public.catalog_ingredients'::regclass,
                         'public.meals'::regclass, 'public.meal_ingredients'::regclass, 'public.items'::regclass)),
  'RLS on every catalog and library table');

-- Catalog: readable by everyone, writable by no client --------------------------------------
set local role anon;
select is((select count(*)::int from public.catalog_meals where slug = 'test-tacos'), 1, 'anon reads the catalog');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.catalog_ingredients
           where catalog_meal_id = '00000000-0000-0000-0000-00000000ca01'), 1, 'members read catalog ingredients');
select throws_ok($$ insert into public.catalog_meals (slug, name, category) values ('x', 'X', 'Pasta') $$,
  '42501', null, 'clients cannot add catalog dishes');
select throws_ok($$ update public.catalog_meals set name = 'Hacked' $$,
  '42501', null, 'clients cannot edit catalog dishes');
select throws_ok($$ delete from public.catalog_ingredients $$,
  '42501', null, 'clients cannot delete catalog ingredients');

-- Planner manages the library (as Alice) ----------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select lives_ok(
  $$ insert into public.meals (id, household_id, catalog_meal_id, name, servings, tags, made_by_member_id) values
       ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
        '00000000-0000-0000-0000-00000000ca01', 'Our tacos', 5, '{quick,beginner}',
        '00000000-0000-0000-0000-0000000000a1') $$,
  'a planner copies a catalog dish into the library');
select lives_ok(
  $$ insert into public.items (id, household_id, canonical_name, category) values
       ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Ground beef', 'meat_seafood') $$,
  'a planner adds an item');
select lives_ok(
  $$ insert into public.meal_ingredients (household_id, meal_id, item_id, quantity_text, position) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
        '00000000-0000-0000-0000-0000000001a1', '1 lb', 1) $$,
  'a planner adds an ingredient to a meal');
select throws_ok(
  $$ update public.meal_ingredients set item_id = '00000000-0000-0000-0000-0000000001b1'
     where meal_id = '00000000-0000-0000-0000-0000000002a1' $$,
  '23503', null, 'an ingredient cannot be repointed at another household''s item');
select lives_ok(
  $$ insert into public.meals (household_id, name) values ('00000000-0000-0000-0000-0000000000a0', 'Leftover surprise') $$,
  'quick add needs only a name');
select is((select servings::int from public.meals where name = 'Leftover surprise'), 4, 'servings default to 4');
select lives_ok(
  $$ update public.meals set status = 'archived' where name = 'Leftover surprise' $$,
  'a planner archives a meal');
select throws_ok($$ delete from public.meals where name = 'Leftover surprise' $$,
  '42501', null, 'meals are never hard-deleted');
select throws_ok($$ delete from public.items where id = '00000000-0000-0000-0000-0000000001a1' $$,
  '42501', null, 'items are never hard-deleted');
select throws_ok(
  $$ insert into public.items (household_id, canonical_name) values ('00000000-0000-0000-0000-0000000000a0', 'ground BEEF') $$,
  '23505', null, 'item names are unique per household, ignoring case');
select throws_ok(
  $$ insert into public.meals (household_id, name, tags) values ('00000000-0000-0000-0000-0000000000a0', 'X', '{deep_fried}') $$,
  '22P02', null, 'tags come from the fixed list');
select throws_ok(
  $$ insert into public.meals (household_id, name, source_url) values ('00000000-0000-0000-0000-0000000000a0', 'X', 'javascript:alert(1)') $$,
  '23514', null, 'source URLs must be http or https');
select throws_ok(
  $$ insert into public.meals (household_id, name, servings) values ('00000000-0000-0000-0000-0000000000a0', 'X', 0) $$,
  '23514', null, 'servings must be positive');
select throws_ok(
  $$ insert into public.items (household_id, canonical_name, keep_on_hand) values ('00000000-0000-0000-0000-0000000000a0', 'Bagels', true) $$,
  '23514', null, 'a keep-on-hand item needs a stock state');
select lives_ok(
  $$ insert into public.items (household_id, canonical_name, category, keep_on_hand, stock_state) values
       ('00000000-0000-0000-0000-0000000000a0', 'Milk', 'dairy_eggs', true, 'in') $$,
  'a staple is added with its stock state');

-- Cross-household isolation (as Alice) ------------------------------------------------------
select is_empty($$ select 1 from public.meals where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household''s meals are invisible');
select is_empty($$ select 1 from public.items where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household''s items are invisible');
select throws_ok(
  $$ insert into public.meals (household_id, name) values ('00000000-0000-0000-0000-0000000000b0', 'Intruder') $$,
  '42501', null, 'cannot add meals to another household');
select throws_ok(
  $$ insert into public.meal_ingredients (household_id, meal_id, item_id) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
        '00000000-0000-0000-0000-0000000001b1') $$,
  '23503', null, 'a meal cannot use another household''s item');
select throws_ok(
  $$ insert into public.meals (household_id, name, made_by_member_id) values
       ('00000000-0000-0000-0000-0000000000a0', 'X', '00000000-0000-0000-0000-0000000000c1') $$,
  '23503', null, 'made-by must be a member of the same household');
update public.meals set name = 'Hacked' where id = '00000000-0000-0000-0000-0000000002b1';
update public.items set canonical_name = 'Hacked' where id = '00000000-0000-0000-0000-0000000001b1';
select throws_ok(
  $$ select public.ensure_item('00000000-0000-0000-0000-0000000000b0', 'saffron') $$,
  '42501', null, 'ensure_item cannot reach another household''s item');

-- Members read the library, write items only (as Bob) ---------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

select is((select count(*)::int from public.meals), 2, 'a member sees the household library');
select is((select count(*)::int from public.meal_ingredients), 1, 'a member sees meal ingredients');
select throws_ok(
  $$ insert into public.meals (household_id, name) values ('00000000-0000-0000-0000-0000000000a0', 'Pizza') $$,
  '42501', null, 'a member cannot add meals');
select throws_ok(
  $$ insert into public.meal_ingredients (household_id, meal_id, item_id) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
        '00000000-0000-0000-0000-0000000001a1') $$,
  '42501', null, 'a member cannot add ingredients');
update public.meals set name = 'Bob''s tacos' where id = '00000000-0000-0000-0000-0000000002a1';
delete from public.meal_ingredients;
update public.meal_ingredients set quantity_text = '9 lb';
select is((select count(*)::int from public.meal_ingredients), 1, 'a member cannot remove ingredients');
select is((select quantity_text from public.meal_ingredients), '1 lb', 'a member cannot edit ingredients');
select lives_ok(
  $$ update public.items set stock_state = 'low' where canonical_name = 'Milk' $$,
  'a member marks a staple low');
select lives_ok(
  $$ insert into public.items (household_id, canonical_name, category) values
       ('00000000-0000-0000-0000-0000000000a0', 'Paper towels', 'household') $$,
  'a member adds an item');
select is((public.ensure_item('00000000-0000-0000-0000-0000000000a0', ' MILK ', 'other')).keep_on_hand, true,
  'ensure_item returns an existing staple untouched');
select is((select count(*)::int from public.items where name_key = 'milk'), 1, 'ensure_item does not duplicate');
select is((public.ensure_item('00000000-0000-0000-0000-0000000000a0', 'Apples', 'produce')).category::text, 'produce',
  'ensure_item creates a missing item');
select throws_ok(
  $$ update public.items set canonical_name = 'Gross beef' where canonical_name = 'Ground beef' $$,
  '42501', null, 'a member cannot rename an item used by recipes');
select throws_ok(
  $$ update public.items set category = 'frozen' where canonical_name = 'Ground beef' $$,
  '42501', null, 'a member cannot recategorize an item');
select lives_ok(
  $$ update public.items set keep_on_hand = true, stock_state = 'out' where canonical_name = 'Paper towels' $$,
  'a member marks an item as a staple');
select throws_ok(
  $$ update public.items set household_id = '00000000-0000-0000-0000-0000000000b0' where canonical_name = 'Milk' $$,
  '42501', null, 'items cannot move between households');

-- Planner removes an ingredient line (editing a recipe) ------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ delete from public.meal_ingredients where meal_id = '00000000-0000-0000-0000-0000000002a1' $$,
  'a planner removes an ingredient from a meal');

-- The owner builds the library before adding their own profile (onboarding) ---------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok(
  $$ insert into public.items (household_id, canonical_name, category) values
       ('00000000-0000-0000-0000-0000000000d0', 'Taco shells', 'pantry') $$,
  'an owner with no profile yet adds items');
select is((select count(*)::int from public.items), 1, 'an owner with no profile yet reads their items');

-- Attempts above changed nothing ------------------------------------------------------------
select pg_temp.as_admin();
select is((select name from public.meals where id = '00000000-0000-0000-0000-0000000002b1'), 'Paella',
  'cross-household meal update had no effect');
select is((select canonical_name from public.items where id = '00000000-0000-0000-0000-0000000001b1'), 'saffron',
  'cross-household item update had no effect');
select is((select name from public.meals where id = '00000000-0000-0000-0000-0000000002a1'), 'Our tacos',
  'a member cannot rename meals');

select * from finish();
rollback;
