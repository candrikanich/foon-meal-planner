-- The yearly recap (#65, part 2): "Your year in dinners" for 2026, and the year either side of it.
begin;
select plan(18);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.recap(target_year int = 2026) returns jsonb language sql as $$
  select public.year_recap('00000000-0000-0000-0000-0000000000a0', target_year);
$$;

create function pg_temp.top(target_year int = 2026) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(d ->> 'name', (d ->> 'times')::int) order by ord), '[]'::jsonb)
  from jsonb_array_elements(pg_temp.recap(target_year) -> 'top_dishes') with ordinality as t(d, ord);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"time_zone": "America/New_York"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
-- Dan is a kid. Lou has been removed, Tot eats separately, and Eve only ever picked a night out.
insert into public.members
  (id, household_id, first_name, role, guardian, age_group, user_id, status, eats_separately) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a', 'active', false),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b', 'active', false),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Dan', 'member', false, 'kid', null,
   'active', false),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Lou', 'member', false, 'adult',
   null, 'removed', false),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Tot', 'member', false, 'kid', null,
   'active', true),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Eve', 'member', false, 'adult',
   null, 'active', false),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c', 'active', false);

insert into public.meals (id, household_id, name, status) values
  ('00000000-0000-0000-0000-0000000001c0', '00000000-0000-0000-0000-0000000000a0', 'Chili', 'active'),
  ('00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000000a0', 'Tacos', 'active'),
  ('00000000-0000-0000-0000-0000000001c2', '00000000-0000-0000-0000-0000000000a0', 'Soup', 'active'),
  ('00000000-0000-0000-0000-0000000001c3', '00000000-0000-0000-0000-0000000000a0', 'Pie', 'active'),
  ('00000000-0000-0000-0000-0000000001c4', '00000000-0000-0000-0000-0000000000a0', 'Stew', 'active');

insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000002a0', '00000000-0000-0000-0000-0000000000a0', '2025-12-28', now()),
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', '2026-03-01', now()),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', '2026-06-07', null),  -- a draft
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', '2026-12-27', now());

insert into public.plan_nights (id, household_id, plan_id, date, meal_id, quick_pick) values
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a0', '2025-12-30', '00000000-0000-0000-0000-0000000001c4', null),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-01', '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000312', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-02', '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000313', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-03', '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000314', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-04', '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000315', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-05', '00000000-0000-0000-0000-0000000001c3', null),
  ('00000000-0000-0000-0000-000000000316', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-06', null, 'eat_out'),
  ('00000000-0000-0000-0000-000000000317', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-03-07', '00000000-0000-0000-0000-0000000001c4', null),
  ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a2', '2026-06-08', '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000322', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a2', '2026-06-09', '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000323', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a2', '2026-06-10', '00000000-0000-0000-0000-0000000001c2', null),
  ('00000000-0000-0000-0000-000000000331', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a3', '2026-12-31', '00000000-0000-0000-0000-0000000001c3', null),
  ('00000000-0000-0000-0000-000000000332', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a3', '2027-01-01', '00000000-0000-0000-0000-0000000001c2', null);

-- Pie on December 31 was logged at 11:30 that night in New York: already January 1 in UTC.
insert into public.meal_logs (id, household_id, night_id, meal_id, quick_pick, cooked_by_member_id, created_at) values
  ('00000000-0000-0000-0000-000000000401', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-0000000001c4', null,
   '00000000-0000-0000-0000-0000000000a1', '2025-12-31 01:00+00'),
  ('00000000-0000-0000-0000-000000000411', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-0000000001c1', null,
   '00000000-0000-0000-0000-0000000000a2', '2026-03-02 01:00+00'),
  ('00000000-0000-0000-0000-000000000412', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000312', '00000000-0000-0000-0000-0000000001c0', null,
   '00000000-0000-0000-0000-0000000000a4', '2026-03-03 01:00+00'),
  ('00000000-0000-0000-0000-000000000413', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000313', '00000000-0000-0000-0000-0000000001c1', null,
   '00000000-0000-0000-0000-0000000000a1', '2026-03-04 01:00+00'),
  ('00000000-0000-0000-0000-000000000414', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000314', '00000000-0000-0000-0000-0000000001c0', null,
   '00000000-0000-0000-0000-0000000000a1', '2026-03-05 01:00+00'),
  ('00000000-0000-0000-0000-000000000415', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000315', '00000000-0000-0000-0000-0000000001c3', null,
   '00000000-0000-0000-0000-0000000000a3', '2026-03-06 01:00+00'),
  ('00000000-0000-0000-0000-000000000416', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000316', null, 'eat_out',
   '00000000-0000-0000-0000-0000000000a6', '2026-03-07 01:00+00'),
  ('00000000-0000-0000-0000-000000000417', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000317', '00000000-0000-0000-0000-0000000001c4', null,
   '00000000-0000-0000-0000-0000000000a2', '2026-03-08 01:00+00'),
  ('00000000-0000-0000-0000-000000000421', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-0000000001c2', null,
   '00000000-0000-0000-0000-0000000000a3', '2026-06-09 01:00+00'),
  ('00000000-0000-0000-0000-000000000422', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000322', '00000000-0000-0000-0000-0000000001c2', null,
   '00000000-0000-0000-0000-0000000000a3', '2026-06-10 01:00+00'),
  ('00000000-0000-0000-0000-000000000423', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000323', '00000000-0000-0000-0000-0000000001c2', null,
   '00000000-0000-0000-0000-0000000000a3', '2026-06-11 01:00+00'),
  ('00000000-0000-0000-0000-000000000431', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000331', '00000000-0000-0000-0000-0000000001c3', null,
   '00000000-0000-0000-0000-0000000000a1', '2027-01-01 04:30+00'),
  ('00000000-0000-0000-0000-000000000432', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000332', '00000000-0000-0000-0000-0000000001c2', null,
   '00000000-0000-0000-0000-0000000000a3', '2027-01-02 01:00+00');

insert into public.reactions (household_id, meal_log_id, member_id, reaction) values
  -- March 1, tacos: Dan likes them. Lou (removed) and Tot (eats separately) don't count toward the tie-break.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000411',
   '00000000-0000-0000-0000-0000000000a3', 'good'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000411',
   '00000000-0000-0000-0000-0000000000a4', 'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000411',
   '00000000-0000-0000-0000-0000000000a5', 'favorite'),
  -- March 4, chili: Bob's favorite, and Alice would rather not, which isn't a like.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000414',
   '00000000-0000-0000-0000-0000000000a2', 'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000414',
   '00000000-0000-0000-0000-0000000000a1', 'not_for_me'),
  -- Pie, liked on March 5 and again on December 31.
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000415',
   '00000000-0000-0000-0000-0000000000a1', 'good'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000431',
   '00000000-0000-0000-0000-0000000000a2', 'good');

-- Pie has been archived since and chili retired: they're still part of the year.
update public.meals set status = 'archived' where id = '00000000-0000-0000-0000-0000000001c3';
update public.meals set status = 'retired' where id = '00000000-0000-0000-0000-0000000001c0';

-- Bob, a member, sees the household's year.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((pg_temp.recap() ->> 'logged')::int, 8, '2026: eight dinners logged in approved weeks, December 31 included');
select is(pg_temp.top(), '[["Pie", 2], ["Chili", 2], ["Tacos", 2]]'::jsonb,
  'the top three: most logged, then most liked (only favorite and good, from people who count), then the name; '
  'archived and retired dishes count');
select ok(not (pg_temp.top() @> '[["Soup"]]'::jsonb or pg_temp.top() @> '[["Stew"]]'::jsonb),
  'not soup, whose three June dinners were a draft week, nor stew, made once that year');
select is(pg_temp.recap() -> 'cooks',
  '["00000000-0000-0000-0000-0000000000a2", "00000000-0000-0000-0000-0000000000a1",
    "00000000-0000-0000-0000-0000000000a3"]'::jsonb,
  'thanks in the order they first cooked: not Lou, who was removed, nor Eve, whose night out wasn''t cooking');
select is(pg_temp.recap() -> 'tried',
  '["00000000-0000-0000-0000-0000000000a3", "00000000-0000-0000-0000-0000000000a1",
    "00000000-0000-0000-0000-0000000000a2"]'::jsonb,
  'who tried something new, in the order they first did, without counts');
select is((pg_temp.recap() -> 'stats' ->> 'at_table')::int, 7, 'at the table: every dinner but the night out');
select is((pg_temp.recap() -> 'stats' ->> 'new_dishes')::int, 3,
  'new dishes: tacos, chili, and pie, not stew, first had in 2025');
select is((pg_temp.recap() -> 'stats' ->> 'weeks_planned')::int, 3,
  'weeks planned: the three approved weeks touching 2026, not the draft');

-- Either side of the year.
select is(pg_temp.top(2027), '[["Soup", 1]]'::jsonb, '2027 starts with January 1''s soup, not December 31''s pie');
select is(pg_temp.recap(2027) -> 'cooks', '["00000000-0000-0000-0000-0000000000a3"]'::jsonb, '2027''s cook so far');
select is(pg_temp.top(2025), '[["Stew", 1]]'::jsonb, '2025 ends with stew');
select is(pg_temp.recap(2024),
  '{"logged": 0, "top_dishes": [], "cooks": [], "tried": [], "stats": {"dinners": 0, "dishes": 0, "ideas": 0,
    "cooked_by_others": 0, "at_table": 0, "new_dishes": 0, "weeks_planned": 0}}'::jsonb,
  'a year with nothing logged says nothing');

-- Another household learns nothing.
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is(pg_temp.recap(),
  '{"logged": 0, "top_dishes": [], "cooks": [], "tried": [], "stats": {"dinners": 0, "dishes": 0, "ideas": 0,
    "cooked_by_others": 0, "at_table": 0, "new_dishes": 0, "weeks_planned": 0}}'::jsonb,
  'another household''s member gets nothing');

reset role;
select ok(not has_function_privilege('anon', 'public.year_recap(uuid, int)', 'execute'), 'not for anon');
select ok(not has_function_privilege('public', 'public.year_recap(uuid, int)', 'execute'), 'not for public');
select ok(has_function_privilege('authenticated', 'public.year_recap(uuid, int)', 'execute'), 'for signed-in people');
select is((select provolatile from pg_proc where proname = 'year_recap'), 's', 'read-only');
select ok((select not prosecdef and proconfig @> array['search_path=""'] from pg_proc where proname = 'year_recap'),
  'security invoker, with an empty search_path');

select * from finish();
rollback;
