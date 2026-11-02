-- Household shapes (#49): recurring away patterns, eats separately, food rules, two seatings (model only), hidden comments.
-- Nothing here adds a table: the pattern lives in attendance_defaults, the rules in households.settings, and the rest are
-- columns, so tenancy, erase and export come with the tables they're on.
begin;
select plan(126);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true);
$$;

create function pg_temp.defaults(person uuid) returns jsonb language sql as $$
  select attendance_defaults from public.members where id = person;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'gina@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'pat@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'kira@example.com', 'authenticated', 'authenticated'),
  ('90000000-0000-0000-0000-000000000009', 'nell@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
-- Alice owns and parents. Gina parents too. Pat plans but isn't a parent. Bob's a member. Kira's a kid with her own phone.
-- Tot is a toddler with no account. Owen is a kid with no account. Carol runs another household.
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Gina', 'member', true, 'adult',
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Pat', 'planner', false, 'adult',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Kira', 'member', false, 'kid',
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Tot', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Liver');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2);
insert into public.plan_nights (id, household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2, '00000000-0000-0000-0000-0000000002a1'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, '00000000-0000-0000-0000-0000000002a2');

-- Recurring away patterns -------------------------------------------------------------------
-- 2026-11-02 is a Monday. Every other week from it: Nov 2 to 8 out, Nov 9 to 15 home, Nov 16 to 22 out.
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02"}', '2026-11-02'), true, 'out from the first night');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02"}', '2026-11-08'), true, 'out for all seven nights');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02"}', '2026-11-09'), false, 'home the week after');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02"}', '2026-11-16'), true, 'out again the week after that');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02"}', '2026-11-01'), false, 'the pattern starts on its first night');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02"}', '2026-10-26'), false,
  'not even on a night that would have lined up before it');
select is(public.away_pattern_covers('{"every_weeks": 3, "from": "2026-11-02"}', '2026-11-16'), false, 'every three weeks skips two');
select is(public.away_pattern_covers('{"every_weeks": 3, "from": "2026-11-02"}', '2026-11-23'), true, 'and comes back on the third');
-- Every other weekend: Friday the 6th, 7 and 8; home the next; out the 20th.
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-06", "days": [5, 6, 7]}', '2026-11-08'), true,
  'days narrow it to a weekend');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-06", "days": [5, 6, 7]}', '2026-11-09'), false,
  'and leave the rest of that week home');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-06", "days": [5, 6, 7]}', '2026-11-13'), false,
  'home on the weekend between');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-06", "days": [5, 6, 7]}', '2026-11-20'), true,
  'and out on the next one');
-- A weekend started on its Saturday or Sunday is still that weekend: seven-night stretches from there would split it.
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-07", "days": [5, 6, 7]}', d::date), want,
          format('from a Saturday: %s', d))
from (values ('2026-11-06', true), ('2026-11-07', true), ('2026-11-08', true), ('2026-11-13', false), ('2026-11-15', false),
             ('2026-11-20', true), ('2026-11-22', true), ('2026-11-27', false)) as nights (d, want);
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-08", "days": [7, 5, 6]}', d::date), want,
          format('from a Sunday, in any order: %s', d))
from (values ('2026-11-06', true), ('2026-11-08', true), ('2026-11-13', false), ('2026-11-20', true), ('2026-11-27', false))
     as nights (d, want);
-- A bad value must never stop a week from starting, and must not make someone away. The same table is in
-- AwayPatternTests, so the two sides can't disagree about what a hand-written value means.
select is(public.away_pattern_covers(null, '2026-11-02'), false, 'no pattern, home');
select is(public.away_pattern_covers(pattern::jsonb, '2026-11-02'), false, format('home with %s', pattern))
from (values ('"every other week"'), ('[]'), ('{"every_weeks": 2, "from": "soon"}'), ('{"every_weeks": 0, "from": "2026-11-02"}'),
             ('{"every_weeks": 5, "from": "2026-11-02"}'), ('{"every_weeks": 2.5, "from": "2026-11-02"}'),
             ('{"every_weeks": "2", "from": "2026-11-02"}'), ('{"from": "2026-11-02"}'), ('{"every_weeks": 2}'),
             ('{"every_weeks": 2, "from": "infinity"}'), ('{"every_weeks": 2, "from": "Nov 2 2026"}'),
             ('{"every_weeks": 2, "from": "11/02/2026"}'), ('{"every_weeks": 2, "from": "2026-11-2"}'),
             ('{"every_weeks": 2, "from": 20261102}'), ('{"every_weeks": 2, "from": "2026-11-02", "days": "x"}'),
             ('{"every_weeks": 2, "from": "2026-11-02", "days": ["x"]}'), ('{"every_weeks": 2, "from": "2026-11-02", "days": [9]}'),
             ('{"every_weeks": 2, "from": "2026-11-02", "days": [1, "x"]}'), ('{"every_weeks": 2, "from": "2026-11-02", "days": null}'))
     as junk (pattern);
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-02-31"}', '2026-03-03'), false, 'a date that doesn''t exist, home');
select is(public.away_pattern_covers('{"every_weeks": 2.0, "from": "2026-11-02"}', '2026-11-02'), true, '2.0 is 2, as JSON has it');
select is(public.away_pattern_covers('{"every_weeks": 2, "from": "2026-11-02", "days": []}', '2026-11-02'), true, 'no days is all of them');

-- Everyone edits their own schedule; a parent can change anyone's.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ update public.members set attendance_defaults = '{"away_pattern": {"every_weeks": 2, "from": "2026-11-02"}}'
  where id = '00000000-0000-0000-0000-0000000000a2' $$, 'you set your own pattern');
update public.members set attendance_defaults = '{"away_pattern": {"every_weeks": 2, "from": "2026-11-02"}}'
  where id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
update public.members set attendance_defaults = '{"away_pattern": {"every_weeks": 2, "from": "2026-11-02"}}'
  where id = '00000000-0000-0000-0000-0000000000a7';
select pg_temp.as_admin();
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a5'), '{}'::jsonb, 'not someone else''s');
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a7'), '{}'::jsonb, 'nor can another household');

-- The pattern reaches new weeks. 2026-11-01 is a Sunday, the week's first night; Bob's first away night is the Monday.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-08');
select is((select array_agg(extract(day from n.date)::int order by n.date) from public.night_attendance a
           join public.plan_nights n on n.id = a.plan_night_id
           where a.member_id = '00000000-0000-0000-0000-0000000000a2' and not a.expected
             and n.date between '2026-11-01' and '2026-11-14'),
          array[2, 3, 4, 5, 6, 7, 8], 'each new week starts with their nights out, and only those');
select is((select count(*)::int from public.night_attendance a join public.plan_nights n on n.id = a.plan_night_id
           where a.member_id = '00000000-0000-0000-0000-0000000000a1' and not a.expected
             and n.date between '2026-11-01' and '2026-11-14'),
          0, 'nobody else''s nights change');

-- An older app sends the whole schedule, and knows nothing of the pattern. So does a stale phone changing its days.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.members set attendance_defaults = '{"usually_away": [5]}' where id = '00000000-0000-0000-0000-0000000000a2';
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a2'),
  '{"usually_away": [5], "away_pattern": {"every_weeks": 2, "from": "2026-11-02"}}'::jsonb,
  'saving the usual days keeps the pattern');
update public.members set attendance_defaults = '{"away_pattern": {"every_weeks": 3, "from": "2026-11-02"}}'
  where id = '00000000-0000-0000-0000-0000000000a2';
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a2'),
  '{"usually_away": [5], "away_pattern": {"every_weeks": 3, "from": "2026-11-02"}}'::jsonb,
  'saving the pattern keeps the usual days');

-- Saved schedules hold the whole thing.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', 'Custody');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.members set attendance_defaults = '{"away_pattern": null}' where id = '00000000-0000-0000-0000-0000000000a2';
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a2'), '{"usually_away": [5]}'::jsonb, 'null ends the pattern');
update public.members set attendance_defaults = '{"usually_away": null}' where id = '00000000-0000-0000-0000-0000000000a2';
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a2'), '{}'::jsonb, 'null takes away any key');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.apply_attendance_template(id) from public.attendance_templates where name = 'Custody';
select is(pg_temp.defaults('00000000-0000-0000-0000-0000000000a2') -> 'away_pattern',
  '{"every_weeks": 3, "from": "2026-11-02"}'::jsonb, 'a saved schedule brings its pattern back');

-- Eats separately -------------------------------------------------------------------------------
select pg_temp.as_admin();
select is((select eats_separately from public.members where id = '00000000-0000-0000-0000-0000000000a6'), false,
  'nobody eats separately unless a parent says');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'a member can''t flag themselves');
update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a6';
select is((select eats_separately from public.members where id = '00000000-0000-0000-0000-0000000000a6'), false,
  'or anyone else');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select throws_ok($$ update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a5' $$,
  '42501', null, 'a kid can''t flag themselves');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a6' $$,
  '42501', null, 'a planner who isn''t a parent can''t');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'another parent can''t flag the owner');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a6';
select pg_temp.as_admin();
select is((select eats_separately from public.members where id = '00000000-0000-0000-0000-0000000000a6'), false,
  'another household changes nothing');

-- Tot and Owen say not for me on Liver, before anyone's flagged, which retires it; Bob says good.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a6', 'favorite');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a6', 'not_for_me');
select is((select count(*)::int from public.meal_verdicts where member_id = '00000000-0000-0000-0000-0000000000a6'), 2,
  'before the flag, their ratings count');
select is((select likes from public.meal_likes where meal_id = '00000000-0000-0000-0000-0000000002a1'), 1,
  'and their likes');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a6' $$,
  'a parent flags a toddler');
select is((select eats_separately from public.members where id = '00000000-0000-0000-0000-0000000000a6'), true,
  'and everyone can read it, which is what the tonight poll needs');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select eats_separately from public.members where id = '00000000-0000-0000-0000-0000000000a6'), true,
  'a member reads it too');

select is((select count(*)::int from public.meal_verdicts where member_id = '00000000-0000-0000-0000-0000000000a6'), 0,
  'their verdicts stop counting: no dislike or favorite for planning');
select is((select count(*)::int from public.meal_likes where meal_id = '00000000-0000-0000-0000-0000000002a1'), 0,
  'and their likes stop counting');

select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a2',
  '00000000-0000-0000-0000-0000000000a6', 'good') $$, 'FD004', null, 'nobody can rate for them now');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.reactions (household_id, meal_log_id, member_id, reaction)
  select household_id, id, '00000000-0000-0000-0000-0000000000a6', 'good' from public.meal_logs
  where night_id = '00000000-0000-0000-0000-0000000004a2' $$, 'FD004', null, 'not around the function either');
select throws_ok($$ update public.reactions set reaction = 'good'
  where member_id = '00000000-0000-0000-0000-0000000000a6' $$, 'FD004', null, 'and a rating they had stays as it was');

-- The dislike rule's two people don't include them: Owen alone doesn't retire the dish Tot said no to.
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a7', 'not_for_me');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'active',
  'one not for me and a toddler''s doesn''t retire a dish');
-- It's about ratings and votes, not asking: a parent can still ask in their name.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000002a1', null, null, null, null) $$,
  'someone who eats separately can still ask for a dish');
select is((select (m ->> 'eats_separately')::boolean
           from jsonb_array_elements(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'members') m
           where m ->> 'first_name' = 'Tot'), true, 'the export has the flag');

-- Food rules ----------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'lent_fridays') $$,
  '42501', null, 'a member can''t set a food rule');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select throws_ok($$ select public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'lent_fridays') $$,
  '42501', null, 'a kid can''t');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'lent_fridays') $$,
  '42501', null, 'another household can''t');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is(public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'lent_fridays'),
  '[{"avoid": "meat", "when": "lent_fridays"}]'::jsonb, 'a planner sets one, parent or not');
select is(public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'pork', 'every_night'),
  '[{"avoid": "meat", "when": "lent_fridays"}, {"avoid": "pork", "when": "every_night"}]'::jsonb,
  'a second adds to what''s on the server, not to what the phone last saw');
select is(public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'fridays'),
  '[{"avoid": "pork", "when": "every_night"}, {"avoid": "meat", "when": "fridays"}]'::jsonb,
  'one rule per food: setting it again replaces it');
select is(public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'pork', null),
  '[{"avoid": "meat", "when": "fridays"}]'::jsonb, 'null takes it away');
select throws_ok($$ select public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'kosher', 'every_night') $$,
  '22023', null, 'only the foods it can recognize');
select throws_ok($$ select public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'advent') $$,
  '22023', null, 'and the nights it knows');

-- An older app saves its settings without the key, and a newer one's rule it can't read stays too.
select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"takeout_nights": 2}');
select is((select settings -> 'food_rules' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '[{"avoid": "meat", "when": "fridays"}]'::jsonb, 'a whole-settings save leaves the rules alone');
select pg_temp.as_admin();
update public.households set settings = settings || '{"food_rules": [{"avoid": "dairy", "when": "every_night"}]}'
  where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'fridays'),
  '[{"avoid": "dairy", "when": "every_night"}, {"avoid": "meat", "when": "fridays"}]'::jsonb,
  'a rule this version doesn''t know survives');
select is((select settings -> 'food_rules' -> 1 ->> 'when' from public.households
           where id = '00000000-0000-0000-0000-0000000000a0'), 'fridays', 'and it''s saved');

-- Only set_food_rule writes them. A planner's other routes keep what's there, from any app.
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"food_rules": [], "takeout_nights": 1}');
select is((select settings -> 'food_rules' -> 1 ->> 'avoid' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  'meat', 'a patch with the key doesn''t change them');
select is((select settings ->> 'takeout_nights' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '1', 'and the rest of the patch still lands');
update public.households set settings = settings || '{"food_rules": []}' where id = '00000000-0000-0000-0000-0000000000a0';
select is((select settings -> 'food_rules' -> 1 ->> 'avoid' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  'meat', 'nor does a direct write');
update public.households set settings = settings - 'food_rules' where id = '00000000-0000-0000-0000-0000000000a0';
select is((select settings -> 'food_rules' -> 1 ->> 'avoid' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  'meat', 'nor does leaving the key out of a direct write');
select is(public.set_food_rule('00000000-0000-0000-0000-0000000000a0', 'meat', 'fridays') -> 1 ->> 'avoid', 'meat',
  'and set_food_rule still gets through');
select pg_temp.as_user('90000000-0000-0000-0000-000000000009');
select ok(not (public.create_household('Nells', null, 'Nell', '{"food_rules": [{"avoid": "meat", "when": "fridays"}]}')).settings ? 'food_rules',
  'a new household starts without them');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select settings -> 'food_rules' from public.households where id = '00000000-0000-0000-0000-0000000000b0'),
  null, 'another household has none of it');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'household' -> 'settings' -> 'food_rules' -> 1,
  '{"avoid": "meat", "when": "fridays"}'::jsonb, 'the export has them, with the rest of the settings');

-- Two seatings: the model only ------------------------------------------------------------------
select pg_temp.as_admin();
select is((select seating from public.night_attendance a join public.plan_nights n on n.id = a.plan_night_id
           where n.date = '2026-11-02' and a.member_id = '00000000-0000-0000-0000-0000000000a1'), 1::smallint,
  'create_week puts everyone in the first seating');
select is((select count(*)::int from public.plan_nights where date = '2026-11-02' and second_seating_time is not null), 0,
  'and no night has a second one');
select throws_ok($$ update public.night_attendance set seating = 3 $$, '23514', null, 'there are only two');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ update public.night_attendance set seating = 2 where member_id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'nothing writes a seating yet, not even a planner');
select throws_ok($$ update public.plan_nights set second_seating_time = '19:30' where date = '2026-11-02' $$,
  '42501', null, 'or a second time');
select ok(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'attendance' -> 0 ? 'seating',
  'the export has the seating');

-- Hiding a comment ------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', 'good');
update public.reactions set comment = 'Too spicy for me' where member_id = '00000000-0000-0000-0000-0000000000a2';
select is((select comment from public.meal_comments where member_id = '00000000-0000-0000-0000-0000000000a2'),
  'Too spicy for me', 'the family sees a comment');
select is((select hidden from public.meal_comments where member_id = '00000000-0000-0000-0000-0000000000a2'), false,
  'not hidden');

select throws_ok($$ select public.set_comment_hidden(id, true) from public.reactions
  where member_id = '00000000-0000-0000-0000-0000000000a2' $$, '42501', null, 'a member can''t hide one, even their own');
select throws_ok($$ delete from public.hidden_comments $$, '42501', null, 'or write the table directly');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select throws_ok($$ select public.set_comment_hidden(id, true) from public.reactions
  where member_id = '00000000-0000-0000-0000-0000000000a2' $$, '42501', null, 'a kid can''t');
select pg_temp.as_admin();
create temp table the_comment on commit drop as
  select id from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a2';
grant select on the_comment to authenticated;
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(format($$ select public.set_comment_hidden(%L, true) $$, (select id from the_comment)),
  'P0002', null, 'another household can''t even tell it''s there');
select is((select count(*)::int from public.meal_comments), 0, 'and reads none of ours');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select lives_ok(format($$ select public.set_comment_hidden(%L, true) $$, (select id from the_comment)),
  'a planner hides it, parent or not');
select is((select hidden from public.meal_comments where id = (select id from the_comment)), true,
  'planners still see it, marked hidden, so they can bring it back');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.meal_comments where id = (select id from the_comment)), 0,
  'the person who wrote it doesn''t see it');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is((select count(*)::int from public.meal_comments where id = (select id from the_comment)), 0,
  'nor does anyone else who isn''t a planner');

select pg_temp.as_admin();
select is((select comment from public.hidden_comments where reaction_id = (select id from the_comment)), 'Too spicy for me',
  'hiding deletes nothing');
select is((select reaction::text from public.reactions where id = (select id from the_comment)), 'good',
  'and the rating still counts');
select is((select entered_by_member_id from public.reactions where id = (select id from the_comment)),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'a planner hiding it doesn''t make it theirs');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.reactions set comment = 'Still too spicy' where id = (select id from the_comment);
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select hidden from public.meal_comments where id = (select id from the_comment)), true,
  'editing it doesn''t bring it back');

-- The export is a planner's, and planners see hidden comments: it has the text, marked hidden.
select ok((select r ->> 'comment' = 'Still too spicy'
           from jsonb_array_elements(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'hidden_comments') r
           where (r ->> 'reaction_id')::uuid = (select id from the_comment)), 'the export says it''s hidden');

select lives_ok(format($$ select public.set_comment_hidden(%L, false) $$, (select id from the_comment)),
  'a planner brings it back');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select comment from public.meal_comments where id = (select id from the_comment)), 'Still too spicy',
  'and the family sees it again');

-- Like verdicts: someone who eats separately, or who's been removed, doesn't show. Owen's rating is from before.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.reactions set comment = 'Not this again' where member_id = '00000000-0000-0000-0000-0000000000a7';
select is((select comment from public.meal_comments where member_id = '00000000-0000-0000-0000-0000000000a7'), 'Not this again',
  'Owen''s comment shows');
select pg_temp.as_admin();
update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a7';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.meal_comments where member_id = '00000000-0000-0000-0000-0000000000a7'), 0,
  'not once they eat separately');
select pg_temp.as_admin();
update public.members set eats_separately = false, status = 'removed' where id = '00000000-0000-0000-0000-0000000000a7';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.meal_comments where member_id = '00000000-0000-0000-0000-0000000000a7'), 0,
  'nor once they''re removed');

-- Retention clears the text whether it's hidden or not.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_comment_hidden((select id from the_comment), true);
select pg_temp.as_admin();
select public.delete_account_data('b0000000-0000-0000-0000-00000000000b');
select is((select comment from public.hidden_comments where reaction_id = (select id from the_comment)), null,
  'deleting an account clears a hidden comment too');

select * from finish();
rollback;
