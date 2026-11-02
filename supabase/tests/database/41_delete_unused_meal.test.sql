-- Deleting a dish that's never been used (#168): only a planner in the household, only while nothing else depends on it, and
-- an idea linked to it keeps its name and link.
begin;
select plan(28);

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
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a0', 'test flour');
insert into public.meals (id, household_id, name, photo_path, status) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a0', 'Unused', '00000000-0000-0000-0000-0000000000a0/meals/x.jpg', 'active'),
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a0', 'Archived import', null, 'archived'),
  ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a0', 'Planned', null, 'active'),
  ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a0', 'Cooked', null, 'active'),
  ('00000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a0', 'Traditional', null, 'active'),
  ('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000a0', 'A side', null, 'active'),
  ('00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a0', 'Noted', null, 'active'),
  ('00000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a0', 'Frozen', null, 'active'),
  ('00000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000a0', 'Swapped away', null, 'active'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a0', 'Has a side', null, 'active'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a0', 'Idea dish', null, 'active'),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000b0', 'Theirs', null, 'active');
insert into public.meal_ingredients (id, household_id, meal_id, item_id) values
  ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000007a1');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000005a0', '00000000-0000-0000-0000-0000000000a0', public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_nights (id, household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a0', public.household_today('00000000-0000-0000-0000-0000000000a0'), '00000000-0000-0000-0000-000000000003'),
  ('00000000-0000-0000-0000-0000000006a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a0', public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, null);
insert into public.meal_logs (household_id, night_id, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-000000000004');
insert into public.traditions (household_id, weekday, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', 2, '00000000-0000-0000-0000-000000000005');
insert into public.meal_sides (household_id, meal_id, side_meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000006');
insert into public.serving_notes (household_id, meal_id, member_id, note) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a2', 'No sauce');
insert into public.freezer_stash (household_id, meal_id, made_on) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000008', public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_changes (household_id, night_id, kind, before_meal_id, before_locked, after_locked) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000006a2', 'pick', '00000000-0000-0000-0000-000000000009', false, false);
insert into public.requests (id, household_id, requested_by_member_id, meal_id, title, link, status, planned_night_id) values
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b', 'Instagram find', 'https://example.com/post', 'planned', '00000000-0000-0000-0000-0000000006a2'),
  ('00000000-0000-0000-0000-0000000009a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b', null, null, 'open', null),
  ('00000000-0000-0000-0000-0000000009a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b', 'Clutter', null, 'archived', null),
  ('00000000-0000-0000-0000-0000000009a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b', 'Crab legs', null, 'special', null);

-- What each person is offered.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select set_eq($$ select public.unused_meals('00000000-0000-0000-0000-0000000000a0') $$,
  array['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a',
        '00000000-0000-0000-0000-00000000000b']::uuid[],
  'a planner sees the dishes nothing depends on, a linked idea and an own side list included');
select is_empty($$ select public.unused_meals('00000000-0000-0000-0000-0000000000b0') $$, 'nothing from another household');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is_empty($$ select public.unused_meals('00000000-0000-0000-0000-0000000000a0') $$, 'a member who isn''t a planner is offered nothing');

-- Who may delete.
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000001') $$, '42501', null, 'a member who isn''t a planner can''t');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000001') $$, 'P0002', null, 'another household can''t');
reset role;
select isnt_empty($$ select 1 from public.meals where id = '00000000-0000-0000-0000-000000000001' $$, 'and the dish is still there');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.meal_is_unused('00000000-0000-0000-0000-000000000001') $$, '42501', null, 'the check runs only inside these functions');

-- What's refused.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000003') $$, 'FD015', null, 'on a plan night');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000004') $$, 'FD015', null, 'logged, which is also how a rating reaches a dish');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000005') $$, 'FD015', null, 'a tradition');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000006') $$, 'FD015', null, 'another dish''s side');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000007') $$, 'FD015', null, 'a serving note someone wrote');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000008') $$, 'FD015', null, 'in the freezer');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-000000000009') $$, 'FD015', null, 'in the plan''s change history');
select throws_ok($$ select public.delete_unused_meal('00000000-0000-0000-0000-00000000000c') $$, 'P0002', null, 'a dish in another household');

-- A delete.
select is(public.delete_unused_meal('00000000-0000-0000-0000-000000000001'), '00000000-0000-0000-0000-0000000000a0/meals/x.jpg', 'it hands back the photo to remove');
select is(public.delete_unused_meal('00000000-0000-0000-0000-000000000002'), null, 'an archived import goes, and has no photo');
select is(public.delete_unused_meal('00000000-0000-0000-0000-00000000000a'), null, 'a dish with its own side goes');
select is(public.delete_unused_meal('00000000-0000-0000-0000-00000000000b'), null, 'a dish with linked ideas goes');
reset role;
select is_empty($$ select 1 from public.meals where id in ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002') $$, 'the dishes are gone');
select is_empty($$ select 1 from public.meal_ingredients where meal_id = '00000000-0000-0000-0000-000000000001' $$, 'its ingredient lines too');
select isnt_empty($$ select 1 from public.items where id = '00000000-0000-0000-0000-0000000007a1' $$, 'the household keeps the item');
select is_empty($$ select 1 from public.meal_sides where meal_id = '00000000-0000-0000-0000-00000000000a' $$, 'its side list goes');
select isnt_empty($$ select 1 from public.meals where id = '00000000-0000-0000-0000-000000000006' $$, 'the side itself stays');

-- Ideas linked to it.
select results_eq($$ select title, link, status::text, planned_night_id, meal_id from public.requests where id = '00000000-0000-0000-0000-0000000009a1' $$,
  $$ values ('Instagram find', 'https://example.com/post', 'open', null::uuid, null::uuid) $$, 'a planned idea keeps its name and link and goes back to waiting');
select is((select title from public.requests where id = '00000000-0000-0000-0000-0000000009a2'), 'Idea dish', 'an idea with no name of its own takes the dish''s');
select is((select status::text from public.requests where id = '00000000-0000-0000-0000-0000000009a3'), 'archived', 'an archived idea stays archived');
select is((select status::text from public.requests where id = '00000000-0000-0000-0000-0000000009a4'), 'special', 'a special-occasion idea stays saved');

select * from finish();
rollback;
