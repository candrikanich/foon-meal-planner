-- Standing traditions (#31): a meal or quick pick on a weekday, and set_nights saving tradition nights locked.
begin;
select plan(20);

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
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Carters'' pizza');

select ok((select relrowsecurity from pg_class where oid = 'public.traditions'::regclass), 'RLS on traditions');

-- A planner sets traditions ------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ insert into public.traditions (household_id, weekday, meal_id, name) values
       ('00000000-0000-0000-0000-0000000000a0', 2, '00000000-0000-0000-0000-0000000002a1', 'Taco Tuesday') $$,
  'a planner sets a standing meal for a weekday');
select lives_ok(
  $$ insert into public.traditions (household_id, weekday, quick_pick) values
       ('00000000-0000-0000-0000-0000000000a0', 5, 'takeout') $$,
  'or a quick pick');
select throws_ok(
  $$ insert into public.traditions (household_id, weekday, quick_pick) values
       ('00000000-0000-0000-0000-0000000000a0', 2, 'eat_out') $$,
  '23505', null, 'one tradition per weekday');
select throws_ok(
  $$ insert into public.traditions (household_id, weekday) values ('00000000-0000-0000-0000-0000000000a0', 3) $$,
  '23514', null, 'a tradition holds a meal or a quick pick');
select throws_ok(
  $$ insert into public.traditions (household_id, weekday, quick_pick) values
       ('00000000-0000-0000-0000-0000000000a0', 8, 'takeout') $$,
  '23514', null, 'weekdays run 1 to 7');
select throws_ok(
  $$ insert into public.traditions (household_id, weekday, meal_id) values
       ('00000000-0000-0000-0000-0000000000a0', 4, '00000000-0000-0000-0000-0000000002b1') $$,
  '23503', null, 'another household''s meal cannot be a tradition');
select lives_ok(
  $$ update public.traditions set quick_pick = 'eat_out' where weekday = 5
       and household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  'a planner changes a tradition');
select lives_ok(
  $$ delete from public.traditions where weekday = 5 and household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  'and removes one');

select lives_ok(
  $$ select public.set_tradition('00000000-0000-0000-0000-0000000000a0', 5::smallint, null, 'takeout', ' Pizza Friday ') $$,
  'set_tradition adds a weekday''s tradition');
select lives_ok(
  $$ select public.set_tradition('00000000-0000-0000-0000-0000000000a0', 5::smallint, null, 'eat_out', '') $$,
  'and replaces it in place');
select is((select (quick_pick, name)::text from public.traditions
           where household_id = '00000000-0000-0000-0000-0000000000a0' and weekday = 5), '(eat_out,)',
  'one row, the latest pick, a blank name cleared');
delete from public.traditions where weekday = 5 and household_id = '00000000-0000-0000-0000-0000000000a0';

-- set_nights saves tradition nights locked ---------------------------------------------------
create temp table week on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
grant select on week to authenticated;
select lives_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(jsonb_build_object(
       'id', %L, 'meal_id', '00000000-0000-0000-0000-0000000002a1', 'reason', 'Taco Tuesday', 'locked', true))) $$,
  (select id from week), (select id from public.plan_nights where plan_id = (select id from week) and date = '2026-11-03')),
  'Build saves a tradition night');
select ok((select locked from public.plan_nights where plan_id = (select id from week) and date = '2026-11-03'),
  'locked');
select ok(not (select locked from public.plan_nights where plan_id = (select id from week) and date = '2026-11-04'),
  'other nights stay unlocked');

-- Members read; other households see nothing -------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.traditions), 1, 'members see the household''s traditions');
select throws_ok(
  $$ insert into public.traditions (household_id, weekday, quick_pick) values
       ('00000000-0000-0000-0000-0000000000a0', 6, 'takeout') $$,
  '42501', null, 'members do not set traditions');
select throws_ok(
  $$ select public.set_tradition('00000000-0000-0000-0000-0000000000a0', 6::smallint, null, 'takeout', null) $$,
  '42501', null, 'not through set_tradition either');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.traditions), 0, 'another household sees none');

set local role anon;
select throws_ok($$ select * from public.traditions $$, '42501', null, 'anon cannot read traditions');

select * from finish();
rollback;
