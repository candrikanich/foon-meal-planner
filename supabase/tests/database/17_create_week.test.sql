-- Week generation (#22): create_week builds 7 nights from the start day with attendance pre-filled
-- from each member's usual schedule and away status.
begin;
select plan(25);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"dinner_time": "17:30"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
-- 2026-11-01 is a Sunday. Owen works Monday to Thursday (ISO weekdays 1-4). Grace is away until
-- Wednesday the 4th; Rita is away with no return date; Sam was removed.
insert into public.members (id, household_id, first_name, role, user_id, status, away_until, attendance_defaults) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner',
   'a0000000-0000-0000-0000-00000000000a', 'active', null, '{}'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member',
   'b0000000-0000-0000-0000-00000000000b', 'active', null, '{}'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member',
   null, 'active', null, '{"usually_away": [1, 2, 3, 4]}'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'member',
   null, 'away', '2026-11-04', '{}'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Rita', 'member',
   null, 'away', null, '{}'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Sam', 'member',
   null, 'removed', null, '{}'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner',
   'c0000000-0000-0000-0000-00000000000c', 'active', null, '{}');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
create temp table week on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
grant select on week to authenticated;

select is((select week_start from week), '2026-11-01'::date, 'a planner creates the week');
select results_eq(
  $$ select date, effort::text, dinner_time, locked from public.plan_nights where plan_id = (select id from week)
     order by date $$,
  $$ select d::date, 'normal', '17:30'::time, false from generate_series('2026-11-01'::date, '2026-11-07', '1 day') d $$,
  'seven nights from the start day, normal effort, the household''s dinner time');
select is((select count(*)::int from public.night_attendance a join public.plan_nights n on n.id = a.plan_night_id
           where n.plan_id = (select id from week)), 35, 'everyone not removed has a row each night (5 x 7)');
select is((select count(*)::int from public.night_attendance where member_id = '00000000-0000-0000-0000-0000000000a6'), 0,
  'removed members are left out');

create function pg_temp.expected(member uuid, night date) returns boolean language sql as $$
  select a.expected from public.night_attendance a join public.plan_nights n on n.id = a.plan_night_id
  where a.member_id = member and n.date = night and n.plan_id = (select id from week);
$$;
select ok(pg_temp.expected('00000000-0000-0000-0000-0000000000a1', '2026-11-03'), 'Alice is home');
select ok(pg_temp.expected('00000000-0000-0000-0000-0000000000a3', '2026-11-01'), 'Owen is home Sunday');
select ok(not pg_temp.expected('00000000-0000-0000-0000-0000000000a3', '2026-11-02'), 'Owen works Monday');
select ok(not pg_temp.expected('00000000-0000-0000-0000-0000000000a3', '2026-11-05'), 'and Thursday');
select ok(pg_temp.expected('00000000-0000-0000-0000-0000000000a3', '2026-11-06'), 'and is home Friday');
select ok(not pg_temp.expected('00000000-0000-0000-0000-0000000000a4', '2026-11-03'), 'Grace is away before her return');
select ok(pg_temp.expected('00000000-0000-0000-0000-0000000000a4', '2026-11-04'), 'and home from her return date');
select ok(not pg_temp.expected('00000000-0000-0000-0000-0000000000a5', '2026-11-07'),
  'Rita, away with no return date, is away all week');

select is((public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01')).id, (select id from week),
  'creating the same week again returns it');
select is((select count(*)::int from public.plan_nights where plan_id = (select id from week)), 7, 'still seven nights');

select throws_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-03') $$,
  '22023', null, 'a week starts on the shopping day');

-- Someone added after the week was made gets their nights when it's opened again.
insert into public.members (id, household_id, first_name, role) values
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member');
select is((public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01')).id, (select id from week),
  'reopening returns the same week');
select is((select count(*)::int from public.night_attendance where member_id = '00000000-0000-0000-0000-0000000000a7'), 7,
  'and fills in the new member''s nights');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-08') $$,
  '42501', null, 'a member who is not a planner cannot create a week');

select lives_ok(
  $$ update public.members set attendance_defaults = '{"usually_away": [6]}'
     where id = '00000000-0000-0000-0000-0000000000a2' $$,
  'a member sets their own usual schedule');
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a2'),
  '{"usually_away": [6]}'::jsonb, 'and it is saved');
update public.members set attendance_defaults = '{"usually_away": [1]}' where id = '00000000-0000-0000-0000-0000000000a3';
select is((select attendance_defaults from public.members where id = '00000000-0000-0000-0000-0000000000a3'),
  '{"usually_away": [1, 2, 3, 4]}'::jsonb, 'but not someone else''s');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-08') $$,
  '42501', null, 'another household''s planner cannot create a week');

-- Dinner time: the default without a setting, and a bad setting never blocks a week.
create temp table carters on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000b0', '2026-11-01');
grant select on carters to authenticated;
select is((select distinct dinner_time from public.plan_nights where plan_id = (select id from carters)),
  '18:00'::time, 'nights start at 18:00 without a dinner time setting');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.households set settings = '{"dinner_time": "dinner o''clock", "week_start": "x"}'
  where id = '00000000-0000-0000-0000-0000000000a0';
select lives_ok($$ select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-08') $$,
  'a bad setting falls back to the defaults');
select is((select distinct n.dinner_time from public.plan_nights n join public.plans p on p.id = n.plan_id
           where p.week_start = '2026-11-08' and p.household_id = '00000000-0000-0000-0000-0000000000a0'),
  '18:00'::time, 'at 18:00');

select * from finish();
rollback;
