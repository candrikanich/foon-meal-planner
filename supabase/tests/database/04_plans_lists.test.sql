-- Plans, nights, attendance, and list items (#6).
begin;
select plan(46);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Alice (planner, owner), Bob (member), Rita (removed). Household B: Carol.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'active', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Rita', 'member', 'removed', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'active', 'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Paella');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Milk'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Taco shells'),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'Saffron');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000b0', '2026-11-01');
insert into public.list_items (household_id, item_id, list) values
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000001b1', 'weekly');

-- Schema shape ------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.plans'::regclass, 'public.plan_nights'::regclass,
                         'public.night_attendance'::regclass, 'public.list_items'::regclass)),
  'RLS on plans, nights, attendance, and list items');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'list_items'),
  'list items stream over Realtime');

-- Planner builds and approves the week (as Alice) ------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select lives_ok(
  $$ insert into public.plans (id, household_id, week_start) values
       ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2026-11-01') $$,
  'a planner starts a week');
select throws_ok(
  $$ insert into public.plans (household_id, week_start) values ('00000000-0000-0000-0000-0000000000a0', '2026-11-01') $$,
  '23505', null, 'one plan per household per week');
select lives_ok(
  $$ insert into public.plan_nights (id, household_id, plan_id, date, effort, dinner_time, meal_id, quick_pick)
     select gen_random_uuid(), '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
            d::date, 'normal', '18:00', null, null
     from generate_series('2026-11-02'::date, '2026-11-07'::date, interval '1 day') d $$,
  'a planner adds the week''s nights');
select lives_ok(
  $$ insert into public.plan_nights (id, household_id, plan_id, date, effort, meal_id, locked) values
       ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0',
        '00000000-0000-0000-0000-0000000003a1', '2026-11-01', 'rushed', '00000000-0000-0000-0000-0000000002a1', true) $$,
  'a night holds a meal');
select lives_ok(
  $$ update public.plan_nights set quick_pick = 'takeout' where date = '2026-11-06' $$,
  'a night holds a quick pick');
select throws_ok(
  $$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where date = '2026-11-06' $$,
  '23514', null, 'a night has a meal or a quick pick, not both');
select throws_ok(
  $$ insert into public.plan_nights (household_id, plan_id, date) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1', '2026-11-08') $$,
  '23514', null, 'a night falls inside its plan''s week');
select throws_ok(
  $$ insert into public.plan_nights (household_id, plan_id, date) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1', '2026-11-01') $$,
  '23505', null, 'one night per date');
select throws_ok(
  $$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002b1'
     where id = '00000000-0000-0000-0000-0000000004a1' $$,
  '23503', null, 'a night cannot use another household''s meal');
select lives_ok(
  $$ insert into public.night_attendance (household_id, plan_night_id, member_id, expected) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1', true),
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false) $$,
  'a planner sets who is home');
select throws_ok(
  $$ insert into public.night_attendance (household_id, plan_night_id, member_id) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3') $$,
  '23514', null, 'removed members are not part of attendance');
select throws_ok(
  $$ insert into public.night_attendance (household_id, plan_night_id, member_id) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000c1') $$,
  '23503', null, 'attendance cannot name another household''s member');
select lives_ok(
  $$ update public.plans set approved_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000003a1' $$,
  'a planner approves the week');
select is((select approved_at from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), now(),
  'approval time is stamped by the database');
update public.plans set approved_at = '2099-01-01' where id = '00000000-0000-0000-0000-0000000003a1';
select is((select approved_at from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), now(),
  're-sending approval keeps the original time');
select throws_ok($$ delete from public.plans $$, '42501', null, 'plans are never deleted');
select throws_ok($$ delete from public.plan_nights $$, '42501', null, 'nights are never deleted');

-- Cross-household isolation (as Alice) ------------------------------------------------------
select is_empty($$ select 1 from public.plans where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household''s plans are invisible');
select is_empty($$ select 1 from public.list_items where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household''s list is invisible');
select throws_ok(
  $$ insert into public.list_items (household_id, item_id, list) values
       ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000001b1', 'quick') $$,
  '42501', null, 'cannot add to another household''s list');
select throws_ok(
  $$ insert into public.list_items (household_id, item_id, list) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001b1', 'quick') $$,
  '23503', null, 'a list item cannot use another household''s item');

-- Members read the plan and work the list (as Bob) ------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

select is((select count(*)::int from public.plan_nights), 7, 'a member sees the week');
select is((select count(*)::int from public.night_attendance), 2, 'a member sees attendance');
select throws_ok(
  $$ insert into public.plans (household_id, week_start) values ('00000000-0000-0000-0000-0000000000a0', '2026-11-08') $$,
  '42501', null, 'a member cannot start a week');
update public.plan_nights set meal_id = null where id = '00000000-0000-0000-0000-0000000004a1';
update public.night_attendance set expected = true where member_id = '00000000-0000-0000-0000-0000000000a2';

select lives_ok(
  $$ insert into public.list_items (id, household_id, item_id, list, urgency, source, note) values
       ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0',
        '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight', 'pivot', 'for mac and cheese') $$,
  'a member adds to the quick list');
select throws_ok(
  $$ insert into public.list_items (household_id, item_id, list, source) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'staple') $$,
  '23505', null, 'an item is on a list once until checked off');
select lives_ok(
  $$ update public.list_items set checked_at = '2000-01-01' where id = '00000000-0000-0000-0000-0000000005a1' $$,
  'a member checks an item off');
select is((select checked_by from public.list_items where id = '00000000-0000-0000-0000-0000000005a1'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'check-off records who did it');
select is((select checked_at from public.list_items where id = '00000000-0000-0000-0000-0000000005a1'), now(),
  'check-off time is stamped by the database');
update public.list_items set checked_at = '1999-01-01' where id = '00000000-0000-0000-0000-0000000005a1';
select is((select checked_at from public.list_items where id = '00000000-0000-0000-0000-0000000005a1'), now(),
  'a replayed check-off keeps the original time');
select throws_ok(
  $$ update public.list_items set checked_by = '00000000-0000-0000-0000-0000000000a1'
     where id = '00000000-0000-0000-0000-0000000005a1' $$,
  '42501', null, 'nobody checks off in someone else''s name');
select lives_ok(
  $$ update public.list_items set checked_at = null where id = '00000000-0000-0000-0000-0000000005a1' $$,
  'a member unchecks an item');
select is((select checked_by from public.list_items where id = '00000000-0000-0000-0000-0000000005a1'), null,
  'unchecking clears who checked it');
update public.list_items set checked_at = now() where id = '00000000-0000-0000-0000-0000000005a1';
select lives_ok(
  $$ insert into public.list_items (household_id, item_id, list, source) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'staple') $$,
  'a checked-off item can go back on the list');
select throws_ok(
  $$ update public.list_items set checked_at = null where id = '00000000-0000-0000-0000-0000000005a1' $$,
  '23505', null, 'unchecking cannot duplicate an item that is back on the list');
select lives_ok(
  $$ delete from public.list_items where id = '00000000-0000-0000-0000-0000000005a1' $$,
  'a member removes a list item');
select lives_ok(
  $$ select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick') $$,
  'add_to_list adds an item');
select is((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick',
                              'tonight', 'pivot', 'for tacos')).urgency::text, 'tonight',
  'adding it again merges and raises urgency');
select is((select count(*)::int from public.list_items
           where item_id = '00000000-0000-0000-0000-0000000001a2' and checked_at is null), 1,
  'the merged item shows once');
select throws_ok(
  $$ select public.add_to_list('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000001b1', 'quick') $$,
  '42501', null, 'add_to_list cannot reach another household''s list');

-- Outsiders ---------------------------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select is_empty($$ select 1 from public.list_items $$, 'a user without a household sees no list');
select is_empty($$ select 1 from public.plans $$, 'a user without a household sees no plans');

-- Attempts above changed nothing ------------------------------------------------------------
select pg_temp.as_admin();
select is((select meal_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000004a1'),
  '00000000-0000-0000-0000-0000000002a1'::uuid, 'a member cannot change the plan');
select is((select expected from public.night_attendance where member_id = '00000000-0000-0000-0000-0000000000a2'), false,
  'a member cannot change attendance');

select * from finish();
rollback;
