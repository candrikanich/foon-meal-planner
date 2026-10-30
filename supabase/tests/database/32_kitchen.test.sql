-- Start-cooking nudge and kitchen equipment (#55): a dish's time to cook lives on the meal and goes through save_meal;
-- what the kitchen lacks lives in households.settings, saved by update_household_settings.
begin;
select plan(20);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.minutes(meal uuid) returns int language sql as $$
  select cook_minutes from public.meals where id = meal;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"dinner_time": "17:30"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
-- Alice plans. Bob is a member. Carol plans another household.
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name, servings) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Lasagna', 8);

-- A dish's time ----------------------------------------------------------------------------
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a1'), null, 'no time until someone says');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna', 8::smallint, '{}', '{}',
  null, null, '[]'::jsonb, null, 90::smallint) $$, 'a planner saves a time');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a1'), 90, 'and it''s kept');

-- Older builds don't send it. The last TestFlight build keeps saving meals until it's replaced.
select lives_ok($$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna', 8::smallint, '{}', '{}',
  null, null, '[]'::jsonb, null) $$, 'a save from an older build still works');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a1'), 90, 'and leaves the time alone');
select lives_ok($$ select public.create_meal('00000000-0000-0000-0000-0000000000a0', 'Soup', 4::smallint, '{}', '{}',
  null, null, '[]'::jsonb) $$, 'quick add still works');

select is((public.copy_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna, again')).cook_minutes, 90::smallint,
  'copy and tweak keeps the time');

select is((select element ->> 'cook_minutes' from jsonb_array_elements(
             public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'meals') as meals (element)
           where element ->> 'name' = 'Lasagna'), '90', 'the export includes it');

select lives_ok($$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna', 8::smallint, '{}', '{}',
  null, null, '[]'::jsonb, null, 0::smallint) $$, 'sending 0 clears it');
select is(pg_temp.minutes('00000000-0000-0000-0000-0000000002a1'), null, 'back to no time');

select throws_ok($$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna', 8::smallint, '{}', '{}',
  null, null, '[]'::jsonb, null, 1441::smallint) $$, '23514', null, 'a day is the longest time');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna', 8::smallint, '{}', '{}',
  null, null, '[]'::jsonb, null, 30::smallint) $$, '42501', null, 'a member can''t set a time');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Lasagna', 8::smallint, '{}', '{}',
  null, null, '[]'::jsonb, null, 30::smallint) $$, 'P0002', null, 'and another household can''t even find the meal');

-- The equipment list -----------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"missing_equipment": ["grill"], "start_cooking_nudge": false}') $$, 'a planner saves the list');
select is((select settings -> 'missing_equipment' from public.households
           where id = '00000000-0000-0000-0000-0000000000a0'), '["grill"]'::jsonb, 'it''s saved');
select is((select settings ->> 'dinner_time' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '17:30', 'the other settings stay');

-- An older app knows nothing of the list, and saves its settings without it.
select lives_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"takeout_nights": 1}') $$, 'a save from an older build');
select is((select settings -> 'missing_equipment' from public.households
           where id = '00000000-0000-0000-0000-0000000000a0'), '["grill"]'::jsonb, 'leaves the list alone');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"missing_equipment": []}') $$, '42501', null, 'a member can''t change the list');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"missing_equipment": []}') $$, '42501', null, 'nor can another household');

select * from finish();
rollback;
