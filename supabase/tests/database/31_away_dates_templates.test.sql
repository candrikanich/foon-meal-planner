-- Vacation mode and attendance templates (#52). Away dates live in households.settings, written through
-- set_away_dates so the weeks already started follow; templates are saved copies of everyone's usual schedule.
begin;
select plan(62);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dee@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"dinner_time": "17:30"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
-- Alice plans. Bob is a member. Owen works Monday to Thursday. Sam was removed. Dee has an account to delete.
insert into public.members (id, household_id, first_name, role, user_id, status, age_group, attendance_defaults) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner',
   'a0000000-0000-0000-0000-00000000000a', 'active', 'adult', '{}'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member',
   'b0000000-0000-0000-0000-00000000000b', 'active', 'adult', '{"usually_away": [5]}'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member',
   null, 'active', 'kid', '{"usually_away": [1, 2, 3, 4]}'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Sam', 'member',
   null, 'removed', 'kid', '{"usually_away": [6]}'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Dee', 'member',
   'd0000000-0000-0000-0000-00000000000d', 'active', 'adult', '{"usually_away": [7]}'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner',
   'c0000000-0000-0000-0000-00000000000c', 'active', 'adult', '{}');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Soup');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Taco shells'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Dish soap'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Broth');

-- Who's home on a night, from the planner's view.
create function pg_temp.home(night date) returns text[] language sql as $$
  select coalesce(array_agg(m.first_name order by m.first_name) filter (where a.expected), '{}')
  from public.night_attendance a
  join public.plan_nights n on n.id = a.plan_night_id
  join public.members m on m.id = a.member_id
  where n.household_id = '00000000-0000-0000-0000-0000000000a0' and n.date = night;
$$;

-- 2037-11-01 is a Sunday, safely ahead of the clock.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Away dates: who may set them, and what's accepted.
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0', '{}') $$, '22023', null,
  'dates must be a list');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "2037-11-05", "to": "2037-11-03"}]') $$, '22023', null, 'the last night can''t come before the first');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "someday", "to": "2037-11-03"}]') $$, '22023', null, 'dates must be dates');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "2037-01-01", "to": "2039-01-01"}]') $$, '22023', null, 'a stretch can''t run past a year');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  (select jsonb_agg(jsonb_build_object('from', '2037-11-01', 'to', '2037-11-02')) from generate_series(1, 41))) $$,
  '22023', null, 'and there can''t be endless stretches');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000b0', '[]') $$, '42501', null,
  'not for another household');

-- A week starts around them: everyone's out on those nights, and only those.
select lives_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "2037-11-03", "to": "2037-11-04", "note": "dropped"}]') $$, 'a planner sets away dates');
select is((select settings -> 'away_dates' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'saved in settings, with only the dates');
select is((select settings ->> 'dinner_time' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '17:30', 'the other settings stay');
select lives_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"takeout_nights": 2}') $$, 'a settings save from an app that doesn''t know the key');
select ok(public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-04'), 'keeps the dates');
select ok(public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-03'), 'the first night counts');
select ok(not public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-05'), 'the day after doesn''t');
select ok(not public.household_away_on('00000000-0000-0000-0000-0000000000b0', '2037-11-03'),
  'nor does another household''s');

select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2037-11-01') $$, 'the week starts');
select is(pg_temp.home('2037-11-03'), '{}'::text[], 'nobody''s home on the first away night');
select is(pg_temp.home('2037-11-04'), '{}'::text[], 'or the last');
select is(pg_temp.home('2037-11-05'), '{Alice,Bob,Dee}'::text[], 'the night after is back to usual schedules');
select is(pg_temp.home('2037-11-02'), '{Alice,Bob,Dee}'::text[], 'and so is the night before');

reset role;
insert into public.members (id, household_id, first_name, role, age_group) values
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Gran', 'member', 'adult');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2037-11-01') $$,
  'reopening fills in someone added later');
select is(pg_temp.home('2037-11-03'), '{}'::text[], 'who''s out on away nights too');
select is(pg_temp.home('2037-11-05'), '{Alice,Bob,Dee,Gran}'::text[], 'and home on the others');

-- Ending the stretch puts usual schedules back.
select lives_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0', '[]') $$, 'clearing the dates');
select is(pg_temp.home('2037-11-03'), '{Alice,Bob,Dee,Gran}'::text[], 'restores the usual schedule');
select ok(not public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-03'), 'and they''re not away');

-- Marking dates over a week already planned takes what was planned off those nights, and nothing else.
reset role;
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', locked = true, reason = 'Tradition'
where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-03';
update public.plan_nights set quick_pick = 'takeout'
where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-04';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2'
where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-05';
insert into public.requests (id, household_id, requested_by_member_id, meal_id, status, planned_night_id) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-0000000002a1', 'planned',
   (select id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-03'));
insert into public.list_items (household_id, item_id, list, source, plan_id, checked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'weekly', 'plan',
   (select id from public.plans where household_id = '00000000-0000-0000-0000-0000000000a0' and week_start = '2037-11-01'), null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3', 'weekly', 'plan',
   (select id from public.plans where household_id = '00000000-0000-0000-0000-0000000000a0' and week_start = '2037-11-01'), now());
insert into public.list_items (household_id, item_id, list, source) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick', 'manual');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "2037-11-03", "to": "2037-11-04"}]') $$, 'marking dates over a planned week');
select is_empty($$ select 1 from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0'
  and date in ('2037-11-03', '2037-11-04') and (meal_id is not null or quick_pick is not null or locked or reason is not null) $$,
  'away nights lose their picks, locks and chips');
select is((select meal_id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0'
  and date = '2037-11-05'), '00000000-0000-0000-0000-0000000002a2'::uuid, 'the night after keeps its dinner');
select is(pg_temp.home('2037-11-04'), '{}'::text[], 'and nobody''s home on them');
select is((select status::text from public.requests where id = '00000000-0000-0000-0000-0000000005a1'), 'open',
  'a request planned for an away night goes back to open');
select is((select planned_night_id from public.requests where id = '00000000-0000-0000-0000-0000000005a1'), null,
  'with no night');
select is((select count(*)::int from public.list_items where plan_id is not null and checked_at is null), 1,
  'a list that still has a dinner to shop for is left for Update the list');

-- With no dinner left to cook, the week's open lines go. Bought ones and hand-added ones stay.
select lives_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "2037-11-03", "to": "2037-11-07"}]') $$, 'away for the rest of the week');
select is((select count(*)::int from public.list_items where plan_id is not null and checked_at is null), 0,
  'open lines for a week nobody''s cooking in go');
select is((select count(*)::int from public.list_items where plan_id is not null and checked_at is not null), 1,
  'what was already bought stays');
select is((select count(*)::int from public.list_items where plan_id is null), 1, 'and hand-added items stay');

-- Past nights are history.
reset role;
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', '2020-11-01');
insert into public.plan_nights (household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000006a1', '2020-11-02',
   '00000000-0000-0000-0000-0000000002a1');
insert into public.night_attendance (household_id, plan_night_id, member_id, expected) values
  ('00000000-0000-0000-0000-0000000000a0',
   (select id from public.plan_nights where plan_id = '00000000-0000-0000-0000-0000000006a1'),
   '00000000-0000-0000-0000-0000000000a1', true);
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0',
  '[{"from": "2020-11-02", "to": "2020-11-02"}]') $$, 'dates over a past night');
select ok((select meal_id is not null from public.plan_nights where plan_id = '00000000-0000-0000-0000-0000000006a1'),
  'leave its dinner');
select is(pg_temp.home('2020-11-02'), '{Alice}'::text[], 'and who was home');

-- Members can read them, only planners set them.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0', '[]') $$, '42501', null,
  'a member can''t set away dates');

-- Attendance templates.
select throws_ok($$ select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', 'Summer') $$,
  '42501', null, 'a member can''t save a template');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', '   ') $$,
  '22023', null, 'a template needs a name');
create temp table school on commit drop as
  select * from public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', ' School year ');
grant select on school to authenticated;
select is((select name from school), 'School year', 'saved with a trimmed name');
select is((select schedules from school), jsonb_build_object(
    '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb,
    '00000000-0000-0000-0000-0000000000a2', '{"usually_away": [5]}'::jsonb,
    '00000000-0000-0000-0000-0000000000a3', '{"usually_away": [1, 2, 3, 4]}'::jsonb,
    '00000000-0000-0000-0000-0000000000a5', '{"usually_away": [7]}'::jsonb,
    '00000000-0000-0000-0000-0000000000a6', '{}'::jsonb),
  'it holds everyone''s usual schedule, without removed members');

-- Saving under the same name replaces it, whatever the capitals.
reset role;
update public.members set attendance_defaults = '{"usually_away": [1]}'
where id = '00000000-0000-0000-0000-0000000000a3';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', 'SCHOOL YEAR') $$,
  'saving under the same name');
select is((select count(*)::int from public.attendance_templates), 1, 'replaces rather than duplicates');
select is((select schedules -> '00000000-0000-0000-0000-0000000000a3' from public.attendance_templates),
  '{"usually_away": [1]}'::jsonb, 'with the schedule as it is now');

-- Switching sets everyone's usual schedule; someone added since keeps theirs, and existing weeks stay as they are.
reset role;
update public.members set attendance_defaults = '{"usually_away": [2]}'
where household_id = '00000000-0000-0000-0000-0000000000a0';
update public.attendance_templates set schedules = schedules - '00000000-0000-0000-0000-0000000000a6';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.apply_attendance_template((select id from public.attendance_templates)) $$,
  '42501', null, 'a member can''t switch templates');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.apply_attendance_template((select id from public.attendance_templates)) $$,
  'a planner switches');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a3'),
  '{"usually_away": [1]}'::jsonb, 'switching sets the saved schedule');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a6'),
  '{"usually_away": [2]}'::jsonb, 'someone not in it keeps theirs');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a4'),
  '{"usually_away": [2]}'::jsonb, 'and a removed member isn''t touched');
select is(pg_temp.home('2037-11-02'), '{Alice,Bob,Dee,Gran}'::text[], 'nights already made stay as they are');

-- Tenancy: another household can't read, switch, or delete it.
reset role;
create temp table saved on commit drop as select id from public.attendance_templates;
grant select on saved to authenticated;
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.attendance_templates $$, 'another household can''t read templates');
select throws_ok($$ select public.apply_attendance_template((select id from saved)) $$,
  'P0002', null, 'or switch to one');
delete from public.attendance_templates where id = (select id from saved);
reset role;
select is((select count(*)::int from public.attendance_templates), 1, 'or delete one');

-- Only a planner deletes one.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
delete from public.attendance_templates where id = (select id from saved);
reset role;
select is((select count(*)::int from public.attendance_templates), 1, 'a member can''t delete one');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'attendance_templates'), 1,
  'templates are in the export');

-- Deleting an account takes that person's saved schedules with their other personal data.
reset role;
select is(public.delete_account_data('d0000000-0000-0000-0000-00000000000d'), 'profile_anonymized', 'Dee deletes her account');
select ok(not (select schedules ? '00000000-0000-0000-0000-0000000000a5' from public.attendance_templates),
  'her schedule leaves the templates');

-- A removed kid's, after the retention window, goes the same way.
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a3';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a3';
select ok(public.anonymize_expired_profiles() >= 1, 'the retention job runs');
select ok(not (select schedules ? '00000000-0000-0000-0000-0000000000a3' from public.attendance_templates),
  'and a removed kid''s schedule leaves the templates');

select * from finish();
rollback;
