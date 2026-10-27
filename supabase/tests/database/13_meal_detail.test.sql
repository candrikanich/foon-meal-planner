-- Meal detail (#19): recipe steps, save_meal (meal fields and ingredient lines in one go), and
-- copy_meal (Copy and tweak).
begin;
select plan(29);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
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

insert into public.catalog_meals (id, slug, name, category) values
  ('00000000-0000-0000-0000-00000000ca01', 'test-tacos', 'Test tacos', 'Tex-Mex');
insert into public.catalog_ingredients (catalog_meal_id, name, category) values
  ('00000000-0000-0000-0000-00000000ca01', 'Sour cream', 'dairy_eggs');
insert into public.items (id, household_id, canonical_name, category) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Ground beef', 'meat_seafood');
insert into public.meals (id, household_id, catalog_meal_id, name, servings, tags, prep_steps, photo_path) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-00000000ca01', 'Tacos', 4, '{quick}',
   '[{"step": "Thaw the beef", "lead_hours": 24}]', '00000000-0000-0000-0000-0000000000a0/meals/x.jpg');
insert into public.meal_ingredients (household_id, meal_id, item_id, quantity_text, position) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   '00000000-0000-0000-0000-0000000001a1', '1 lb', 1);

-- Steps column -----------------------------------------------------------------------------
select has_column('public', 'meals', 'steps', 'meals carry optional recipe steps');
select is((select steps from public.meals where id = '00000000-0000-0000-0000-0000000002a1'), '{}'::text[],
  'steps default to none');

-- save_meal --------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(
  (public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Our tacos', 5::smallint, '{quick,beginner}',
                    '{"Brown the beef","Warm the shells"}', 'https://example.com/tacos',
                    '00000000-0000-0000-0000-0000000000a1',
                    '[{"name": " ground beef ", "quantity": "2 lb"}, {"name": "sour cream"},
                      {"name": "Grandma''s spice mix", "quantity": "1 tbsp"}, {"name": "   "}]'::jsonb)).name,
  'Our tacos', 'a planner saves the meal');
select is((select (servings, tags, steps, source_url, made_by_member_id)::text from public.meals
           where id = '00000000-0000-0000-0000-0000000002a1'),
  '(5,"{quick,beginner}","{""Brown the beef"",""Warm the shells""}",https://example.com/tacos,00000000-0000-0000-0000-0000000000a1)',
  'servings, tags, steps, link, and made-by are saved');
select results_eq(
  $$ select i.canonical_name, mi.quantity_text, mi.position::int from public.meal_ingredients mi
     join public.items i on i.id = mi.item_id
     where mi.meal_id = '00000000-0000-0000-0000-0000000002a1' order by mi.position $$,
  $$ values ('Ground beef', '2 lb', 1), ('sour cream', null, 2), ('Grandma''s spice mix', '1 tbsp', 3) $$,
  'ingredient lines are replaced in order; blank lines are skipped and names trimmed');
select is((select count(*)::int from public.items where household_id = '00000000-0000-0000-0000-0000000000a0'
           and name_key = 'ground beef'), 1, 'an existing item is reused, whatever its spelling');
select is((select category::text from public.items where household_id = '00000000-0000-0000-0000-0000000000a0'
           and name_key = 'sour cream'), 'dairy_eggs', 'a new item takes the starter pack''s category for that name');
select is((select category::text from public.items where household_id = '00000000-0000-0000-0000-0000000000a0'
           and name_key = 'grandma''s spice mix'), 'other', 'an unknown item is filed under other');
select is((select photo_path from public.meals where id = '00000000-0000-0000-0000-0000000002a1'),
  '00000000-0000-0000-0000-0000000000a0/meals/x.jpg', 'saving leaves the photo alone');
select is(
  (public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Our tacos', 5::smallint, '{}', '{}', null, null,
                    '[]'::jsonb)).source_url,
  null, 'the link and made-by can be cleared');
select is((select count(*)::int from public.meal_ingredients where meal_id = '00000000-0000-0000-0000-0000000002a1'), 0,
  'saving no lines clears the ingredients');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', null, null,
       '[{"name": "x", "quantity": "this quantity is far too long to be a real quantity for anything at all ok"}]') $$,
  '23514', null, 'a quantity over 60 characters is refused');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', 'javascript:alert(1)',
       null, '[]') $$,
  '23514', null, 'only http and https links are kept');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', null, null,
       '{"name": "not an array"}') $$,
  '22023', null, 'lines must be a JSON array');

select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', null,
       '00000000-0000-0000-0000-0000000000c1', '[]') $$,
  '23503', null, 'made-by must be someone in this household');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', array[null, 'x'],
       null, null, '[]') $$,
  '23514', null, 'a step cannot be empty (null)');
select lives_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', null, null,
       '[{"name": 42}, {"name": {"x": 1}}, null, "milk", {"name": "Milk"}]') $$,
  'lines whose name is not text are skipped');
select is((select count(*)::int from public.meal_ingredients where meal_id = '00000000-0000-0000-0000-0000000002a1'), 1,
  'only the real ingredient is kept');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Hacked', 4::smallint, '{}', '{}', null, null, '[]') $$,
  '42501', null, 'a member who is not a planner cannot edit a meal');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Hacked', 4::smallint, '{}', '{}', null, null, '[]') $$,
  'P0002', null, 'another household''s meal is not found');

-- copy_meal --------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Our tacos', 5::smallint, '{quick}',
       '{"Brown the beef"}', 'https://example.com/tacos', null,
       '[{"name": "Ground beef", "quantity": "2 lb"}, {"name": "Taco shells"}]') $$,
  'a planner saves a recipe to copy');
create temp table copied on commit drop as
  select * from public.copy_meal('00000000-0000-0000-0000-0000000002a1', 'Our tacos, spicy');
grant select on copied to authenticated;

select is((select name from copied), 'Our tacos, spicy', 'the copy takes the new name');
select is((select (servings, tags, steps, source_url, status, catalog_meal_id, photo_path)::text from copied),
  '(5,{quick},"{""Brown the beef""}",https://example.com/tacos,active,,)',
  'the copy keeps the recipe but not the catalog link or the photo');
select is((select prep_steps from copied), '[{"step": "Thaw the beef", "lead_hours": 24}]'::jsonb, 'prep steps copy');
select results_eq(
  $$ select item_id, quantity_text, position::int from public.meal_ingredients where meal_id = (select id from copied)
     order by position $$,
  $$ select item_id, quantity_text, position::int from public.meal_ingredients
     where meal_id = '00000000-0000-0000-0000-0000000002a1' order by position $$,
  'the copy has the same ingredient lines');

update public.meals set status = 'retired' where id = (select id from copied);
select throws_ok(
  $$ select public.copy_meal((select id from copied), 'Back again') $$,
  '42501', null, 'a retired meal is not copied');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.copy_meal('00000000-0000-0000-0000-0000000002a1', 'Mine') $$,
  '42501', null, 'a member who is not a planner cannot copy a meal');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ select public.copy_meal('00000000-0000-0000-0000-0000000002a1', 'Mine') $$,
  'P0002', null, 'another household''s meal is not found');

set local role anon;
select throws_ok($$ select public.copy_meal('00000000-0000-0000-0000-0000000002a1', 'Mine') $$,
  '42501', null, 'anon cannot copy meals');

select * from finish();
rollback;
