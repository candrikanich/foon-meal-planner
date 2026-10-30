-- Vacation mode and attendance templates (#52). Away dates live in households.settings, written through
-- add_away_dates and remove_away_dates so the weeks already started follow; templates are saved copies of everyone's
-- usual schedule.
begin;
select plan(122);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dee@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'pat@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'zed@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"dinner_time": "17:30"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
-- Alice owns and plans. Bob is a member. Owen works Monday to Thursday. Sam was removed. Dee has an account to delete.
-- Pat plans but isn't a parent.
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
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Pat', 'planner',
   'e0000000-0000-0000-0000-00000000000e', 'active', 'adult', '{}'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner',
   'c0000000-0000-0000-0000-00000000000c', 'active', 'adult', '{}');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Soup');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Taco shells'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Dish soap'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Broth'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'Salt');

-- Who's home on a night, from the planner's view.
create function pg_temp.home(night date) returns text[] language sql as $$
  select coalesce(array_agg(m.first_name order by m.first_name) filter (where a.expected), '{}')
  from public.night_attendance a
  join public.plan_nights n on n.id = a.plan_night_id
  join public.members m on m.id = a.member_id
  where n.household_id = '00000000-0000-0000-0000-0000000000a0' and n.date = night;
$$;

create function pg_temp.away_dates(target uuid) returns jsonb language sql as $$
  select settings -> 'away_dates' from public.households where id = target;
$$;

-- 2037-11-01 is a Sunday, safely ahead of the clock.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Away dates: who may set them, and what's accepted.
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-05', '2037-11-03') $$,
  '22023', null, 'the last night can''t come before the first');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', null, '2037-11-03') $$,
  '22023', null, 'both nights are needed');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', 'infinity') $$,
  '22023', null, 'infinity isn''t a night');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-01-01', '2039-01-01') $$,
  '22023', null, 'a stretch can''t run past a year');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2020-01-01', '2020-01-02') $$,
  '22023', null, 'or be over already');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', d::date, d::date)
                    from generate_series('2038-01-01'::date, '2038-04-01', '2 days') d $$,
  '22023', null, 'and there can''t be endless stretches');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000b0', '2037-11-03', '2037-11-04') $$,
  '42501', null, 'not for another household');
select throws_ok($$ select public.remove_away_dates('00000000-0000-0000-0000-0000000000b0', '2037-11-03', '2037-11-04') $$,
  '42501', null, 'in either direction');
select throws_ok($$ select public.set_away_dates('00000000-0000-0000-0000-0000000000a0', '[]') $$, '42883', null,
  'there''s no way to replace the whole list');

-- A week starts around them: everyone's out on those nights, and only those.
select is(public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-04'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'a planner adds dates and gets the list back');
select is(pg_temp.away_dates('00000000-0000-0000-0000-0000000000a0'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'saved in settings');
select is((select settings ->> 'dinner_time' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '17:30', 'the other settings stay');
select lives_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"takeout_nights": 2, "away_dates": []}') $$, 'a settings save that sends a stale list');
select is(pg_temp.away_dates('00000000-0000-0000-0000-0000000000a0'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'doesn''t touch the dates');
select is((select settings ->> 'takeout_nights' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '2', 'but saves the rest');

-- A planner can edit settings directly, but not the dates: only the two functions change them.
update public.households set settings = settings || '{"away_dates": [], "takeout_nights": 3}'
where id = '00000000-0000-0000-0000-0000000000a0';
select is(pg_temp.away_dates('00000000-0000-0000-0000-0000000000a0'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'a planner''s direct edit can''t clear the dates');
select is((select settings ->> 'takeout_nights' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '3', 'and the rest of it saves');
update public.households set settings = '{"dinner_time": "17:30", "takeout_nights": 2}'
where id = '00000000-0000-0000-0000-0000000000a0';
select is(pg_temp.away_dates('00000000-0000-0000-0000-0000000000a0'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'nor can replacing all the settings');

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
create temp table zeds on commit drop as
  select * from public.create_household('Zeds', null, 'Zed',
    '{"dinner_time": "18:30", "away_dates": [{"from": "2037-11-03", "to": "2037-11-04"}]}');
grant select on zeds to authenticated;
select is((select settings from zeds), '{"dinner_time": "18:30"}'::jsonb, 'a new household can''t start with dates');
update public.households set settings = settings || '{"away_dates": [{"from": "2037-11-03", "to": "2037-11-04"}]}'
where id = (select id from zeds);
select is(pg_temp.away_dates((select id from zeds)), null, 'or get them by a direct edit');
select is(public.add_away_dates((select id from zeds), '2037-11-03', '2037-11-04'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'the function''s own write goes through');
select is(pg_temp.away_dates((select id from zeds)),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'and is saved');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select ok(public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-03'), 'the first night counts');
select ok(public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-04'), 'and the last');
select ok(not public.household_away_on('00000000-0000-0000-0000-0000000000a0', '2037-11-05'), 'the day after doesn''t');
select ok(not public.household_away_on('00000000-0000-0000-0000-0000000000b0', '2037-11-03'),
  'nor does another household''s');

select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2037-11-01') $$, 'the week starts');
select is(pg_temp.home('2037-11-03'), '{}'::text[], 'nobody''s home on the first away night');
select is(pg_temp.home('2037-11-04'), '{}'::text[], 'or the last');
select is(pg_temp.home('2037-11-05'), '{Alice,Bob,Dee,Pat}'::text[], 'the night after is back to usual schedules');
select is(pg_temp.home('2037-11-02'), '{Alice,Bob,Dee,Pat}'::text[], 'and so is the night before');

reset role;
insert into public.members (id, household_id, first_name, role, age_group) values
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Gran', 'member', 'adult');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2037-11-01') $$,
  'reopening fills in someone added later');
select is(pg_temp.home('2037-11-03'), '{}'::text[], 'who''s out on away nights too');
select is(pg_temp.home('2037-11-05'), '{Alice,Bob,Dee,Gran,Pat}'::text[], 'and home on the others');

-- A device that hasn't heard about the first stretch doesn't lose it: the server merges.
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-12-20', '2037-12-22') $$,
  'a second planner adds another stretch');
select is(pg_temp.away_dates('00000000-0000-0000-0000-0000000000a0'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}, {"from": "2037-12-20", "to": "2037-12-22"}]'::jsonb,
  'the first is still there, in date order');
select is(public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-12-23', '2037-12-24'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}, {"from": "2037-12-20", "to": "2037-12-24"}]'::jsonb,
  'one that runs on from another joins it');
select is(public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-12-21', '2037-12-22'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}, {"from": "2037-12-20", "to": "2037-12-24"}]'::jsonb,
  'one inside another changes nothing');
select is(public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-12-20', '2037-12-24'),
  '[{"from": "2037-11-03", "to": "2037-11-04"}]'::jsonb, 'removing one keeps the other');

-- Ending the stretch puts usual schedules back.
select is(public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-04'), '[]'::jsonb,
  'clearing the dates');
select is(pg_temp.home('2037-11-03'), '{Alice,Bob,Dee,Gran,Pat}'::text[], 'restores the usual schedule');
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
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000006a2', '00000000-0000-0000-0000-0000000000a0', '2037-11-08', now());
-- This week's plan line and low staple, another week's line, and a hand-added item that merged into a plan line.
insert into public.list_items (household_id, item_id, list, source, plan_id, note) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'weekly', 'plan',
   (select id from public.plans where household_id = '00000000-0000-0000-0000-0000000000a0' and week_start = '2037-11-01'), null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'weekly', 'staple',
   (select id from public.plans where household_id = '00000000-0000-0000-0000-0000000000a0' and week_start = '2037-11-01'), null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3', 'weekly', 'plan',
   '00000000-0000-0000-0000-0000000006a2', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4', 'weekly', 'plan',
   (select id from public.plans where household_id = '00000000-0000-0000-0000-0000000000a0' and week_start = '2037-11-01'),
   'the good kind');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-04') $$,
  'marking dates over a planned week');
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

-- The list is left for Update the list, even with no dinner left: a line can be another week's, a staple, or merged.
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-07') $$,
  'away for the rest of the week');
select is((select plan_id from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3'),
  '00000000-0000-0000-0000-0000000006a2'::uuid, 'another week''s line stays');
select is((select source::text from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2'),
  'staple', 'so does a low staple');
select is((select note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a4'),
  'the good kind', 'and a line someone merged into');
select is((select count(*)::int from public.list_items where household_id = '00000000-0000-0000-0000-0000000000a0'), 4,
  'no line goes at all');

-- Shortening a stretch restores only the nights it gave up.
select is(public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-04'),
  '[{"from": "2037-11-05", "to": "2037-11-07"}]'::jsonb, 'taking nights off the front keeps the rest');
select is(pg_temp.home('2037-11-04'), '{Alice,Bob,Dee,Gran,Pat}'::text[], 'nights given up are back');
select is(pg_temp.home('2037-11-05'), '{}'::text[], 'nights still covered aren''t');
select is(public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-06', '2037-11-06'),
  '[{"from": "2037-11-05", "to": "2037-11-05"}, {"from": "2037-11-07", "to": "2037-11-07"}]'::jsonb,
  'taking one from the middle splits it');
select is(public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-01', '2037-11-30'), '[]'::jsonb,
  'and a wide one clears them');

-- Someone who left since isn't marked home by the restore.
reset role;
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a6';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03') $$,
  'away again');
select lives_ok($$ select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03') $$,
  'and back');
select is(pg_temp.home('2037-11-03'), '{Alice,Bob,Dee,Pat}'::text[], 'a removed member stays out');
reset role;
update public.members set status = 'active', removed_at = null where id = '00000000-0000-0000-0000-0000000000a6';

-- Nothing lands on an away night through the front door, whatever a device thinks the dates are.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03') $$,
  'away on the 3rd');
select throws_ok($$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1'
                    where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-03' $$,
  '22023', null, 'a swap onto it is refused');
select throws_ok($$ select public.set_nights(
    (select plan_id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-03'),
    jsonb_build_array(jsonb_build_object(
      'id', (select id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-03'),
      'quick_pick', 'takeout'))) $$,
  '22023', null, 'and so is a saved draft');
select lives_ok($$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1'
                   where household_id = '00000000-0000-0000-0000-0000000000a0' and date = '2037-11-02' $$,
  'another night is fine');
select lives_ok($$ select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03') $$,
  'back again');

-- From today on, and tonight's dinner stays: someone marking dates at 9pm has already eaten it.
reset role;
create temp table days on commit drop as
  select public.household_today('00000000-0000-0000-0000-0000000000a0') as today;
grant select on days to authenticated;
create function pg_temp.today() returns date language sql as $$ select today from days $$;
create function pg_temp.sunday(day date) returns date language sql as $$
  select day - (extract(isodow from day)::int % 7);
$$;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', d) from
    (select distinct pg_temp.sunday(pg_temp.today() + o) as d from generate_series(-1, 3) o) w $$, 'weeks around today');
reset role;
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1'
where household_id = '00000000-0000-0000-0000-0000000000a0' and date between pg_temp.today() - 1 and pg_temp.today() + 2;
-- A dinner already logged for the night two days on (only reachable with a clock change, but the rule is what's tested).
insert into public.meal_logs (household_id, night_id, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0',
   (select id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0' and date = pg_temp.today() + 2),
   '00000000-0000-0000-0000-0000000002a1');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', pg_temp.today() - 1, pg_temp.today() + 3) $$,
  'a stretch that started yesterday');
create function pg_temp.pick(day date) returns uuid language sql as $$
  select meal_id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0' and date = day;
$$;
select ok(pg_temp.pick(pg_temp.today() - 1) is not null, 'leaves last night''s dinner');
select ok(cardinality(pg_temp.home(pg_temp.today() - 1)) > 0, 'and who was home');
select ok(pg_temp.pick(pg_temp.today()) is not null, 'leaves tonight''s dinner');
select ok(cardinality(pg_temp.home(pg_temp.today())) > 0, 'and who''s home for it');
select is(pg_temp.pick(pg_temp.today() + 1), null, 'clears tomorrow''s');
select is(pg_temp.home(pg_temp.today() + 1), '{}'::text[], 'with everyone out');
select ok(pg_temp.pick(pg_temp.today() + 2) is not null, 'a logged dinner stays');
select ok(cardinality(pg_temp.home(pg_temp.today() + 2)) > 0, 'with who was home');
select lives_ok($$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2'
                   where household_id = '00000000-0000-0000-0000-0000000000a0' and date = pg_temp.today() $$,
  'tonight can still be changed, since it holds a dinner');
select lives_ok($$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2'
                   where household_id = '00000000-0000-0000-0000-0000000000a0' and date = pg_temp.today() - 1 $$,
  'and a past night can be corrected ("We had something else")');
-- Swapping tonight's dinner off leaves it an away night like the rest, so a stale device's draft skips it.
select lives_ok($$ update public.plan_nights set meal_id = null
                   where household_id = '00000000-0000-0000-0000-0000000000a0' and date = pg_temp.today() $$,
  'swapping tonight''s dinner off');
select is(pg_temp.home(pg_temp.today()), '{}'::text[], 'leaves nobody home');
select throws_ok($$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2'
                    where household_id = '00000000-0000-0000-0000-0000000000a0' and date = pg_temp.today() $$,
  '22023', null, 'and a dinner can''t go back on');
select is(public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', pg_temp.today() - 1, pg_temp.today() + 3),
  '[]'::jsonb, 'cleared');
select ok(cardinality(pg_temp.home(pg_temp.today())) > 0, 'and tonight is back to usual schedules');

-- Reads leniently: a bad value written directly never stops a week from starting. An ended stretch drops on the next change.
reset role;
update public.households set settings = '{"away_dates": [{"from": "soon", "to": "2037-11-04"}, 3, {"from": "infinity", "to": "infinity"},
  {"from": "2037-11-03", "to": "2037-11-03"}, {"from": "2020-01-01", "to": "2020-01-02"}]}'
where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000b0', '2037-11-01') $$,
  'a week starts despite bad dates');
select ok(public.household_away_on('00000000-0000-0000-0000-0000000000b0', '2037-11-03'), 'the good one still counts');
select is(public.add_away_dates('00000000-0000-0000-0000-0000000000b0', '2037-12-01', '2037-12-01'),
  '[{"from": "2037-11-03", "to": "2037-11-03"}, {"from": "2037-12-01", "to": "2037-12-01"}]'::jsonb,
  'the next change tidies the rest away');
reset role;
update public.households set settings = '{"away_dates": "nope"}' where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select ok(not public.household_away_on('00000000-0000-0000-0000-0000000000b0', '2037-11-03'), 'a value that isn''t a list is none');

-- However many are stored, removing always works; only adding is capped.
reset role;
update public.households
set settings = jsonb_build_object('away_dates', (
  select jsonb_agg(jsonb_build_object('from', d::date::text, 'to', d::date::text) order by d)
  from generate_series('2038-01-01'::date, '2038-01-01'::date + 100, '2 days') d))
where id = '00000000-0000-0000-0000-0000000000b0';
select is(jsonb_array_length(pg_temp.away_dates('00000000-0000-0000-0000-0000000000b0')), 51, 'fifty-one stretches stored');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is(jsonb_array_length(public.remove_away_dates('00000000-0000-0000-0000-0000000000b0', '2038-01-01', '2038-01-01')), 50,
  'one can still be removed');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000b0', '2039-01-01', '2039-01-01') $$,
  '22023', null, 'but none added');

-- Members can read them, only planners set them.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-04') $$,
  '42501', null, 'a member can''t add away dates');
select throws_ok($$ select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-04') $$,
  '42501', null, 'or remove them');

-- Attendance templates are parents' to save, switch, and delete; everyone reads them.
select throws_ok($$ select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', 'Summer') $$,
  '42501', null, 'a member can''t save a template');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', 'Summer') $$,
  '42501', null, 'nor a planner who isn''t a parent');

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
    '00000000-0000-0000-0000-0000000000a6', '{}'::jsonb,
    '00000000-0000-0000-0000-0000000000a7', '{}'::jsonb),
  'it holds everyone''s usual schedule, without removed members');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select name from public.attendance_templates), 'School year', 'a member reads it');
select throws_ok($$ insert into public.attendance_templates (household_id, name)
                    values ('00000000-0000-0000-0000-0000000000a0', 'Sneaky') $$, '42501', null, 'and can''t write it directly');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.attendance_templates (household_id, name)
                    values ('00000000-0000-0000-0000-0000000000a0', 'Sneaky') $$, '42501', null, 'nor can a parent');
select throws_ok($$ update public.attendance_templates set schedules = '{}' $$, '42501', null, 'in either direction');

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
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.apply_attendance_template((select id from public.attendance_templates)) $$,
  '42501', null, 'nor a planner who isn''t a parent');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.apply_attendance_template((select id from public.attendance_templates)) $$,
  'a parent switches');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a3'),
  '{"usually_away": [1]}'::jsonb, 'switching sets the saved schedule');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a6'),
  '{"usually_away": [2]}'::jsonb, 'someone not in it keeps theirs');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a4'),
  '{"usually_away": [2]}'::jsonb, 'and a removed member isn''t touched');
select is(pg_temp.home('2037-11-02'), '{Alice,Bob,Dee,Gran,Pat}'::text[], 'nights already made stay as they are');

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

-- Only a parent deletes one.
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
delete from public.attendance_templates where id = (select id from saved);
reset role;
select is((select count(*)::int from public.attendance_templates), 1, 'a non-parent planner can''t delete one');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'attendance_templates'), 1,
  'templates are in the export');

-- A person's saved schedules go when they leave the family, however they leave.
select lives_ok($$ update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a3' $$,
  'a parent removes Owen');
select ok(not (select schedules ? '00000000-0000-0000-0000-0000000000a3' from public.attendance_templates),
  'his schedule leaves the templates');
reset role;
select is(public.delete_account_data('d0000000-0000-0000-0000-00000000000d'), 'profile_anonymized', 'Dee deletes her account');
select ok(not (select schedules ? '00000000-0000-0000-0000-0000000000a5' from public.attendance_templates),
  'her schedule leaves the templates');
select ok((select schedules ? '00000000-0000-0000-0000-0000000000a1' from public.attendance_templates),
  'and everyone else''s stay');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
delete from public.attendance_templates where id = (select id from saved);
select is_empty($$ select 1 from public.attendance_templates $$, 'a parent deletes one');

select * from finish();
rollback;
