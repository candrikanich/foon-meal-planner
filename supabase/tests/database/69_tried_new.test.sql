-- Picky-eater wins (#65, part 1): who tried a new dish, for the weekly recap and a member's month.
begin;
select plan(18);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.tried(from_date date = '2026-10-25', to_date date = '2026-10-31') returns jsonb
language sql as $$
  select public.tried_new('00000000-0000-0000-0000-0000000000a0', from_date, to_date)::jsonb;
$$;

create function pg_temp.dishes(member uuid, from_date date = '2026-10-25', to_date date = '2026-10-31') returns int
language sql as $$
  select (e ->> 'dishes')::int from jsonb_array_elements(pg_temp.tried(from_date, to_date)) e
  where (e ->> 'member_id')::uuid = member;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
-- Dan is a kid. Lou has been removed, and Tot eats separately.
insert into public.members
  (id, household_id, first_name, role, guardian, age_group, user_id, status, eats_separately) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a', 'active', false),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b', 'active', false),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Dan', 'member', false, 'kid', null,
   'active', false),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0',
   'Lou', 'member', false, 'adult', null,
   'removed', false),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Tot', 'member', false, 'kid', null,
   'active', true),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c', 'active', false);

insert into public.meals (id, household_id, name, status) values
  ('00000000-0000-0000-0000-0000000001c0', '00000000-0000-0000-0000-0000000000a0', 'Chili', 'active'),
  ('00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000000a0', 'Tacos', 'active'),
  ('00000000-0000-0000-0000-0000000001c2', '00000000-0000-0000-0000-0000000000a0', 'Soup', 'active'),
  ('00000000-0000-0000-0000-0000000001c3', '00000000-0000-0000-0000-0000000000a0', 'Pie', 'active');

insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000002a0', '00000000-0000-0000-0000-0000000000a0', '2026-10-18', now()),
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', '2026-10-25', now()),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', '2026-11-01', now()),
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', '2026-11-08', null);  -- a draft

insert into public.plan_nights (id, household_id, plan_id, date, meal_id, quick_pick) values
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a0',
   '2026-10-20', '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1',
   '2026-10-25', '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000312', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1',
   '2026-10-27', '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000313', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1',
   '2026-10-29', '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000314', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1',
   '2026-10-31', '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a2',
   '2026-11-01', '00000000-0000-0000-0000-0000000001c3', null),
  ('00000000-0000-0000-0000-000000000322', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a2',
   '2026-11-02', '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000331', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a3',
   '2026-11-09', '00000000-0000-0000-0000-0000000001c3', null);

insert into public.meal_logs (id, household_id, night_id, meal_id, quick_pick) values
  ('00000000-0000-0000-0000-000000000401', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000301',
   '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000411', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000311',
   '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000412', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000312',
   '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000413', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000313',
   '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000414', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000314',
   '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000421', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000321',
   '00000000-0000-0000-0000-0000000001c3', null),
  ('00000000-0000-0000-0000-000000000422', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000322',
   '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000431', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000331',
   '00000000-0000-0000-0000-0000000001c3', null);

insert into public.reactions (household_id, meal_log_id, member_id, reaction) values
  -- The week before: Alice has had chili.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000401',
   '00000000-0000-0000-0000-0000000000a1',
   'good'),
  -- October 25: Dan tries tacos. Lou (removed) and Tot (eats separately) don't count.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000411',
   '00000000-0000-0000-0000-0000000000a3',
   'good'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000411',
   '00000000-0000-0000-0000-0000000000a4',
   'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000411',
   '00000000-0000-0000-0000-0000000000a5',
   'favorite'),
  -- October 27: chili again for Alice, and Bob tries it and would rather not: still a try.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000412',
   '00000000-0000-0000-0000-0000000000a1',
   'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000412',
   '00000000-0000-0000-0000-0000000000a2',
   'not_for_me'),
  -- October 29: tacos a second time for Dan. October 31: Alice tries soup.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000413',
   '00000000-0000-0000-0000-0000000000a3',
   'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000414',
   '00000000-0000-0000-0000-0000000000a1',
   'good'),
  -- November 1: Dan tries pie. November 2: Bob tries soup. November 9 is a draft week.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000421',
   '00000000-0000-0000-0000-0000000000a3',
   'good'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000422',
   '00000000-0000-0000-0000-0000000000a2',
   'good'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000431',
   '00000000-0000-0000-0000-0000000000a1',
   'good');

-- Bob, a member, sees the household's.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is(pg_temp.tried(),
  '[{"member_id": "00000000-0000-0000-0000-0000000000a3", "dishes": 1},
    {"member_id": "00000000-0000-0000-0000-0000000000a2", "dishes": 1},
    {"member_id": "00000000-0000-0000-0000-0000000000a1", "dishes": 1}]'::jsonb,
  'the week of October 25: in the order they first tried something');
select is(pg_temp.dishes('00000000-0000-0000-0000-0000000000a2'), 1, 'not for me is still a try');
select is(pg_temp.dishes('00000000-0000-0000-0000-0000000000a3'), 1, 'a second log of the same dish isn''t a new try');
select is(pg_temp.dishes('00000000-0000-0000-0000-0000000000a1'), 1,
  'chili isn''t new to Alice: she reacted to it the week before');
select ok(not (pg_temp.tried() @> '[{"member_id": "00000000-0000-0000-0000-0000000000a4"}]'::jsonb
            or pg_temp.tried() @> '[{"member_id": "00000000-0000-0000-0000-0000000000a5"}]'::jsonb),
  'nobody removed, and nobody who eats separately');
select is(public.week_recap('00000000-0000-0000-0000-0000000000a0', '2026-10-25', '2026-10-31')::jsonb -> 'tried',
  '["00000000-0000-0000-0000-0000000000a3", "00000000-0000-0000-0000-0000000000a2",
    "00000000-0000-0000-0000-0000000000a1"]'::jsonb,
  'the recap names them in that order, without counts');
select is(pg_temp.tried('2026-10-18', '2026-10-24'),
  '[{"member_id": "00000000-0000-0000-0000-0000000000a1", "dishes": 1}]'::jsonb, 'the week before: Alice''s chili');

-- The month, by the household's day: each night's date is its household day, both ends included.
select is(pg_temp.tried('2026-10-01', '2026-10-31'),
  '[{"member_id": "00000000-0000-0000-0000-0000000000a1", "dishes": 2},
    {"member_id": "00000000-0000-0000-0000-0000000000a3", "dishes": 1},
    {"member_id": "00000000-0000-0000-0000-0000000000a2", "dishes": 1}]'::jsonb,
  'October: Alice''s chili and soup, the 31st included');
select is(pg_temp.tried('2026-11-01', '2026-11-30'),
  '[{"member_id": "00000000-0000-0000-0000-0000000000a3", "dishes": 1},
    {"member_id": "00000000-0000-0000-0000-0000000000a2", "dishes": 1}]'::jsonb,
  'November: not October 31, and not the draft week');
select is(pg_temp.tried('2026-11-01', '2026-11-01'),
  '[{"member_id": "00000000-0000-0000-0000-0000000000a3", "dishes": 1}]'::jsonb, 'the 1st alone is Dan''s pie');
select is(pg_temp.tried('2026-11-08', '2026-11-14'), '[]'::jsonb, 'a draft week tried nothing');

-- Dan changes his tacos rating within its 24 hours: still one try.
reset role;
update public.reactions set reaction = 'not_for_me'
where meal_log_id = '00000000-0000-0000-0000-000000000411' and member_id = '00000000-0000-0000-0000-0000000000a3';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.dishes('00000000-0000-0000-0000-0000000000a3'), 1, 'a changed reaction is still one try');

-- Another household learns nothing.
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is(pg_temp.tried('2026-10-01', '2026-11-30'), '[]'::jsonb, 'another household''s member gets nothing');

reset role;
select ok(not has_function_privilege('anon', 'public.tried_new(uuid, date, date)', 'execute'), 'not for anon');
select ok(not has_function_privilege('public', 'public.tried_new(uuid, date, date)', 'execute'), 'not for public');
select ok(has_function_privilege('authenticated', 'public.tried_new(uuid, date, date)', 'execute'),
  'for signed-in people');
select is((select provolatile from pg_proc where proname = 'tried_new'), 's', 'read-only');
select ok((select not prosecdef and proconfig @> array['search_path=""'] from pg_proc where proname = 'tried_new'),
  'security invoker, with an empty search_path');

select * from finish();
rollback;
