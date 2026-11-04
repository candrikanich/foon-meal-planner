-- The planner engagement view (#235): who's pitching in, for planners only.
begin;
select plan(19);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.eng(from_date date = '2026-10-25', to_date date = '2026-10-31') returns jsonb
language sql as $$
  select public.engagement('00000000-0000-0000-0000-0000000000a0', from_date, to_date);
$$;

create function pg_temp.entry(member uuid, from_date date = '2026-10-25', to_date date = '2026-10-31') returns jsonb
language sql as $$
  select e from jsonb_array_elements(pg_temp.eng(from_date, to_date) -> 'members') e
  where (e ->> 'member_id')::uuid = member;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated');
-- The Andersons live on Pacific time, so a request at 05:00 UTC on November 1 was made on October 31.
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"time_zone": "America/Los_Angeles"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
-- Alice plans. Bob is a member, Dan a kid with his own phone. Lou has been removed, and Tot eats separately.
insert into public.members
  (id, household_id, first_name, role, guardian, age_group, user_id, status, eats_separately, created_at) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a', 'active', false, '2026-09-01 12:00Z'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b', 'active', false, '2026-09-01 13:00Z'),
  -- 06:00 UTC on September 2 is still September 1 at home.
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Dan', 'member', false, 'kid',
   'd0000000-0000-0000-0000-00000000000d', 'active', false, '2026-09-02 06:00Z'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Lou', 'member', false, 'adult',
   null, 'removed', false, '2026-09-02 12:00Z'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Tot', 'member', false, 'kid',
   null, 'active', true, '2026-09-03 12:00Z'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c', 'active', false, '2026-09-01 12:00Z');

insert into public.meals (id, household_id, name, status) values
  ('00000000-0000-0000-0000-0000000001c0', '00000000-0000-0000-0000-0000000000a0', 'Chili', 'active'),
  ('00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000000a0', 'Tacos', 'active'),
  ('00000000-0000-0000-0000-0000000001c2', '00000000-0000-0000-0000-0000000000a0', 'Soup', 'active');

insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000002a0', '00000000-0000-0000-0000-0000000000a0', '2026-10-18', now()),
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', '2026-10-25', now());

insert into public.plan_nights (id, household_id, plan_id, date, meal_id, quick_pick) values
  ('00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a0', '2026-10-24', '00000000-0000-0000-0000-0000000001c0', null),
  ('00000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-10-27', '00000000-0000-0000-0000-0000000001c1', null),
  ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-10-29', null, 'takeout'),
  ('00000000-0000-0000-0000-000000000304', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000002a1', '2026-10-31', '00000000-0000-0000-0000-0000000001c2', null);

-- Bob cooks chili the Saturday before and tacos on Tuesday; takeout on Thursday isn't cooking. Dan makes soup.
insert into public.meal_logs (id, household_id, night_id, meal_id, quick_pick, cooked_by_member_id) values
  ('00000000-0000-0000-0000-000000000401', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-0000000001c0', null,
   '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-000000000402', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000302', '00000000-0000-0000-0000-0000000001c1', null,
   '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-000000000403', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000303', null, 'takeout', '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-000000000404', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-000000000304', '00000000-0000-0000-0000-0000000001c2', null,
   '00000000-0000-0000-0000-0000000000a3');

-- Dan rates the chili (the week before), the tacos and the soup. Tot and Lou rate the tacos.
insert into public.reactions (household_id, meal_log_id, member_id, reaction) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000401',
   '00000000-0000-0000-0000-0000000000a3', 'good'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000402',
   '00000000-0000-0000-0000-0000000000a3', 'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000404',
   '00000000-0000-0000-0000-0000000000a3', 'not_for_me'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000402',
   '00000000-0000-0000-0000-0000000000a5', 'favorite'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000402',
   '00000000-0000-0000-0000-0000000000a4', 'good');

-- Bob asks three times: late on October 24 at home (06:00 UTC on the 25th), on the 27th, and late on the 31st (05:00
-- UTC on November 1). Lou asks too. Dan says me too on the 28th.
insert into public.requests (id, household_id, requested_by_member_id, title, created_at) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000000a2', 'Crab legs', '2026-10-25 06:00Z'),
  ('00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000000a2', 'Ramen', '2026-10-27 18:00Z'),
  ('00000000-0000-0000-0000-0000000007a3', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000000a2', 'Pancakes', '2026-11-01 05:00Z'),
  ('00000000-0000-0000-0000-0000000007a4', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000000a4', 'Pie', '2026-10-27 18:00Z');
insert into public.request_plus_ones (household_id, request_id, member_id, created_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000007a2',
   '00000000-0000-0000-0000-0000000000a3', '2026-10-28 18:00Z');

-- Bob and Dan answer Tuesday's check-in. Alice has Bob out on Saturday: that's hers, not an answer.
insert into public.night_attendance (household_id, plan_night_id, member_id, expected, checked_in_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000302',
   '00000000-0000-0000-0000-0000000000a2', true, now()),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000302',
   '00000000-0000-0000-0000-0000000000a3', false, now()),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000304',
   '00000000-0000-0000-0000-0000000000a2', false, null);

-- Dan claims Saturday. Bob claimed Thursday and took it back.
insert into public.night_claims (household_id, night_id, member_id, released_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000304',
   '00000000-0000-0000-0000-0000000000a3', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-000000000303',
   '00000000-0000-0000-0000-0000000000a2', now());

-- Members, kids, and another household's planner are refused.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select pg_temp.eng() $$, '42501', null, 'a member who doesn''t plan is refused');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ select pg_temp.eng() $$, '42501', null, 'a kid is refused');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select pg_temp.eng() $$, '42501', null, 'another household''s planner is refused');

-- Alice, a planner, sees everyone still in the family.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select jsonb_agg(e -> 'member_id') from jsonb_array_elements(pg_temp.eng() -> 'members') e),
  '["00000000-0000-0000-0000-0000000000a1", "00000000-0000-0000-0000-0000000000a2",
    "00000000-0000-0000-0000-0000000000a3", "00000000-0000-0000-0000-0000000000a5"]'::jsonb,
  'everyone but the removed member, in the order they joined');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a1'),
  '{"member_id": "00000000-0000-0000-0000-0000000000a1", "ideas": 0, "me_toos": 0, "rated": 0, "check_ins": 0,
    "claimed": 0, "cooked": [], "last_idea_on": null, "joined_on": "2026-09-01"}'::jsonb,
  'someone who did nothing that week is still there, at zero');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a2'),
  '{"member_id": "00000000-0000-0000-0000-0000000000a2", "ideas": 2, "me_toos": 0, "rated": 0, "check_ins": 1,
    "claimed": 0, "cooked": ["2026-10-27"], "last_idea_on": "2026-10-31", "joined_on": "2026-09-01"}'::jsonb,
  'Bob: two ideas by the household''s day, one check-in, and Tuesday''s tacos');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a2') -> 'claimed', '0'::jsonb,
  'a claim taken back doesn''t count');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a2') -> 'cooked', '["2026-10-27"]'::jsonb,
  'takeout isn''t cooking, and the Saturday before is outside the week');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a3'),
  '{"member_id": "00000000-0000-0000-0000-0000000000a3", "ideas": 0, "me_toos": 1, "rated": 2, "check_ins": 1,
    "claimed": 1, "cooked": ["2026-10-31"], "last_idea_on": "2026-10-28", "joined_on": "2026-09-01"}'::jsonb,
  'Dan: a me-too, two dinners rated, a check-in, Saturday claimed and cooked; he joined on September 1 at home');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a5') -> 'rated', '0'::jsonb,
  'someone who eats separately doesn''t rate');

-- The window is the household's days.
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a2', '2026-10-24', '2026-10-24') - 'member_id' - 'joined_on',
  '{"ideas": 1, "me_toos": 0, "rated": 0, "check_ins": 0, "claimed": 0, "cooked": ["2026-10-24"],
    "last_idea_on": "2026-10-24"}'::jsonb,
  'October 24 alone: the request made late that evening at home, and the chili');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a2', '2026-11-01', '2026-11-07') -> 'ideas', '0'::jsonb,
  'the request at 05:00 UTC on November 1 isn''t November''s');

-- A planner changing the night's attendance wipes the answer, so it no longer counts as a check-in.
reset role;
update public.night_attendance set expected = false
where plan_night_id = '00000000-0000-0000-0000-000000000302' and member_id = '00000000-0000-0000-0000-0000000000a3';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.entry('00000000-0000-0000-0000-0000000000a3') -> 'check_ins', '0'::jsonb,
  'a check-in a planner has since overwritten isn''t counted');

-- Carol's own household is hers to see.
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is(public.engagement('00000000-0000-0000-0000-0000000000b0', '2026-10-25', '2026-10-31') -> 'members' -> 0
            -> 'member_id',
  '"00000000-0000-0000-0000-0000000000c1"'::jsonb, 'a planner sees their own household');

reset role;
select ok(not has_function_privilege('anon', 'public.engagement(uuid, date, date)', 'execute'), 'not for anon');
select ok(not has_function_privilege('public', 'public.engagement(uuid, date, date)', 'execute'), 'not for public');
select ok(has_function_privilege('authenticated', 'public.engagement(uuid, date, date)', 'execute'),
  'for signed-in people');
select ok((select not prosecdef and proconfig @> array['search_path=""'] from pg_proc where proname = 'engagement'),
  'security invoker, with an empty search path');
select is((select provolatile from pg_proc where proname = 'engagement'), 's', 'read-only');

select * from finish();
rollback;
