-- Internal metrics (#36): pooled, anonymous, and only for service_role.
begin;
select plan(45);

create function pg_temp.id(kind int, i int) returns uuid language sql immutable as $$
  select format('00000000-0000-0000-%s-%s', lpad(kind::text, 4, '0'), lpad(i::text, 12, '0'))::uuid;
$$;

create function pg_temp.week(result jsonb, monday date) returns jsonb language sql as $$
  select e from jsonb_array_elements(result -> 'weeks') e where e ->> 'week' = monday::text;
$$;

-- Kinds of id: 1 household, 2 account, 3 planner, 4 kid, 5 another adult, 6 dish, 7 plan, 8 and 9 that week's nights,
-- 10 and 11 their logs, 12 next week's plan, 13 its night, 14 its log, 15 request, 16 poll, 17 to 19 an unapproved plan,
-- its night and log, 20 to 23 nights out and their logs.
--
-- Six families signed up on Monday, August 3 (noon in New York). 1 to 3 live on Pacific time. 5 hasn't finished
-- onboarding, and its owner's profile says member: owning the household still makes them a planner. 6 is a sample family.
insert into auth.users (id, email, aud, role)
select pg_temp.id(2, i), format('planner%s@example.com', i), 'authenticated', 'authenticated'
from generate_series(1, 6) i;

insert into public.households (id, name, owner, settings, created_at)
select pg_temp.id(1, i), format('Household %s', i), pg_temp.id(2, i),
       case when i <= 3 then '{"time_zone": "America/Los_Angeles", "onboarded": true}'
            when i = 4 then '{"onboarded": true}'
            when i = 5 then '{"onboarded": false}'
            else '{"sample": true, "onboarded": true}' end::jsonb,
       '2026-08-03 16:00Z'::timestamptz
from generate_series(1, 6) i;

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id, created_at)
select pg_temp.id(3, i), pg_temp.id(1, i), 'Pat', case when i = 5 then 'member' else 'planner' end::public.member_role,
       true, 'adult'::public.age_group, pg_temp.id(2, i), '2026-08-03 16:00Z'::timestamptz
from generate_series(1, 6) i
union all
select pg_temp.id(4, i), pg_temp.id(1, i), 'Kit', 'member'::public.member_role, false, 'kid'::public.age_group, null,
       '2026-08-03 16:00Z'::timestamptz
from generate_series(1, 6) i
union all
select pg_temp.id(5, i), pg_temp.id(1, i), 'Bob', 'member'::public.member_role, false, 'adult'::public.age_group, null,
       '2026-08-03 16:00Z'::timestamptz
from generate_series(1, 3) i;

insert into public.meals (id, household_id, name, status)
select pg_temp.id(6, i), pg_temp.id(1, i), 'Tacos', 'active'::public.meal_status from generate_series(1, 6) i;

-- Each approves the week of August 10, family i i×12 hours after signing up (the sample family after one hour).
insert into public.plans (id, household_id, week_start, approved_at)
select pg_temp.id(7, i), pg_temp.id(1, i), '2026-08-10'::date,
       '2026-08-03 16:00Z'::timestamptz + case when i = 6 then interval '1 hour' else i * interval '12 hours' end
from generate_series(1, 6) i;

insert into public.plan_nights (id, household_id, plan_id, date, meal_id)
select pg_temp.id(8, i), pg_temp.id(1, i), pg_temp.id(7, i), '2026-08-10'::date, pg_temp.id(6, i)
from generate_series(1, 6) i
union all
select pg_temp.id(9, i), pg_temp.id(1, i), pg_temp.id(7, i), '2026-08-11'::date, pg_temp.id(6, i)
from generate_series(1, 6) i;

-- Both nights are logged. The planner cooks, except Monday in family 3, where the kid does.
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id, created_at, updated_at)
select pg_temp.id(10, i), pg_temp.id(1, i), pg_temp.id(8, i), pg_temp.id(6, i),
       case when i = 3 then pg_temp.id(4, i) else pg_temp.id(3, i) end,
       '2026-08-12 01:00Z'::timestamptz, '2026-08-12 01:00Z'::timestamptz
from generate_series(1, 6) i
union all
select pg_temp.id(11, i), pg_temp.id(1, i), pg_temp.id(9, i), pg_temp.id(6, i), pg_temp.id(3, i),
       '2026-08-12 01:00Z'::timestamptz, '2026-08-12 01:00Z'::timestamptz
from generate_series(1, 6) i;

-- The planner and the kid are home both nights; the kid rates Monday's dinner.
insert into public.night_attendance (household_id, plan_night_id, member_id, expected)
select pg_temp.id(1, i), night, who, true
from generate_series(1, 6) i
cross join lateral (values (pg_temp.id(8, i)), (pg_temp.id(9, i))) n (night)
cross join lateral (values (pg_temp.id(3, i)), (pg_temp.id(4, i))) m (who);
insert into public.reactions (household_id, meal_log_id, member_id, reaction, created_at, updated_at)
select pg_temp.id(1, i), pg_temp.id(10, i), pg_temp.id(4, i), 'good'::public.reaction_kind,
       '2026-08-12 02:00Z'::timestamptz, '2026-08-12 02:00Z'::timestamptz
from generate_series(1, 6) i;

-- Monday's help, a different kind in each family; Tuesday's comes only from planners, which doesn't count.
-- 1: the kid asked for Monday's dish, and claimed Tuesday but took it back.
insert into public.requests (id, household_id, requested_by_member_id, meal_id, status, planned_night_id, created_at)
values (pg_temp.id(15, 1), pg_temp.id(1, 1), pg_temp.id(4, 1), pg_temp.id(6, 1), 'planned', pg_temp.id(8, 1),
        '2026-08-05 15:00Z');
insert into public.night_claims (household_id, night_id, member_id, created_at, released_at)
values (pg_temp.id(1, 1), pg_temp.id(9, 1), pg_temp.id(4, 1), '2026-08-06 15:00Z', '2026-08-07 15:00Z');
-- 2: the kid claimed Monday; the planner asked for Tuesday's dish.
insert into public.night_claims (household_id, night_id, member_id, created_at)
values (pg_temp.id(1, 2), pg_temp.id(8, 2), pg_temp.id(4, 2), '2026-08-06 15:00Z');
insert into public.requests (id, household_id, requested_by_member_id, meal_id, status, planned_night_id, created_at)
values (pg_temp.id(15, 2), pg_temp.id(1, 2), pg_temp.id(3, 2), pg_temp.id(6, 2), 'planned', pg_temp.id(9, 2),
        '2026-08-05 15:00Z');
-- 3: the kid cooked Monday (above).
-- 4: the planner asked for Monday's dish and the kid said me too.
insert into public.requests (id, household_id, requested_by_member_id, meal_id, status, planned_night_id, created_at)
values (pg_temp.id(15, 4), pg_temp.id(1, 4), pg_temp.id(3, 4), pg_temp.id(6, 4), 'planned', pg_temp.id(8, 4),
        '2026-08-05 15:00Z');
insert into public.request_plus_ones (household_id, request_id, member_id, created_at)
values (pg_temp.id(1, 4), pg_temp.id(15, 4), pg_temp.id(4, 4), '2026-08-06 15:00Z');
-- 5: the kid voted in Monday's poll; the owner claimed Tuesday.
insert into public.polls (id, household_id, night_id, started_by, options, closes_at, created_at)
values (pg_temp.id(16, 5), pg_temp.id(1, 5), pg_temp.id(8, 5), pg_temp.id(3, 5), '[]', '2026-08-10 22:00Z',
        '2026-08-10 20:00Z');
insert into public.poll_votes (poll_id, member_id, household_id, choice, voted_at)
values (pg_temp.id(16, 5), pg_temp.id(4, 5), pg_temp.id(1, 5), 0, '2026-08-10 21:00Z');
insert into public.night_claims (household_id, night_id, member_id, created_at)
values (pg_temp.id(1, 5), pg_temp.id(9, 5), pg_temp.id(3, 5), '2026-08-06 15:00Z');
-- 6, the sample family: the kid claimed both nights. None of it counts.
insert into public.night_claims (household_id, night_id, member_id, created_at)
values (pg_temp.id(1, 6), pg_temp.id(8, 6), pg_temp.id(4, 6), '2026-08-06 15:00Z'),
       (pg_temp.id(1, 6), pg_temp.id(9, 6), pg_temp.id(4, 6), '2026-08-06 15:00Z');

-- Bob, in families 1 to 3, asks for ramen at 05:00 UTC on August 17: still Sunday the 16th on Pacific time, so it's that
-- week's, but Monday in New York.
insert into public.requests (household_id, requested_by_member_id, title, created_at)
select pg_temp.id(1, i), pg_temp.id(5, i), 'Ramen', '2026-08-17 05:00Z'::timestamptz from generate_series(1, 3) i;

-- Families 1 to 4 also plan and log the week of August 17: only four, so too few to say anything.
insert into public.plans (id, household_id, week_start, approved_at)
select pg_temp.id(12, i), pg_temp.id(1, i), '2026-08-17'::date, '2026-08-16 12:00Z'::timestamptz from generate_series(1, 4) i;
insert into public.plan_nights (id, household_id, plan_id, date, meal_id)
select pg_temp.id(13, i), pg_temp.id(1, i), pg_temp.id(12, i), '2026-08-17'::date, pg_temp.id(6, i)
from generate_series(1, 4) i;
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id, created_at, updated_at)
select pg_temp.id(14, i), pg_temp.id(1, i), pg_temp.id(13, i), pg_temp.id(6, i), pg_temp.id(3, i),
       '2026-08-18 01:00Z'::timestamptz, '2026-08-18 01:00Z'::timestamptz
from generate_series(1, 4) i;

-- Family 1 also ate out on Wednesday and fended for themselves on Thursday, both logged: neither is a dinner at home.
insert into public.plan_nights (id, household_id, plan_id, date, quick_pick)
values (pg_temp.id(20, 1), pg_temp.id(1, 1), pg_temp.id(7, 1), '2026-08-12', 'eat_out'),
       (pg_temp.id(21, 1), pg_temp.id(1, 1), pg_temp.id(7, 1), '2026-08-13', 'fend_for_yourselves');
insert into public.meal_logs (id, household_id, night_id, quick_pick, created_at, updated_at)
values (pg_temp.id(22, 1), pg_temp.id(1, 1), pg_temp.id(20, 1), 'eat_out', '2026-08-14 01:00Z', '2026-08-14 01:00Z'),
       (pg_temp.id(23, 1), pg_temp.id(1, 1), pg_temp.id(21, 1), 'fend_for_yourselves', '2026-08-14 01:00Z',
        '2026-08-14 01:00Z');

-- Families 1 to 5 draft the week of August 24 and log a dinner in it, but never approve it.
insert into public.plans (id, household_id, week_start, approved_at)
select pg_temp.id(17, i), pg_temp.id(1, i), '2026-08-24'::date, null::timestamptz from generate_series(1, 5) i;
insert into public.plan_nights (id, household_id, plan_id, date, meal_id)
select pg_temp.id(18, i), pg_temp.id(1, i), pg_temp.id(17, i), '2026-08-24'::date, pg_temp.id(6, i)
from generate_series(1, 5) i;
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id, created_at, updated_at)
select pg_temp.id(19, i), pg_temp.id(1, i), pg_temp.id(18, i), pg_temp.id(6, i), pg_temp.id(4, i),
       '2026-08-25 01:00Z'::timestamptz, '2026-08-25 01:00Z'::timestamptz
from generate_series(1, 5) i;

-- Two more families sign up the week of August 10: too few for that week's sign-up numbers.
insert into public.households (id, name, owner, settings, created_at)
select pg_temp.id(1, i), format('Household %s', i), null::uuid, '{"onboarded": true}'::jsonb,
       '2026-08-12 16:00Z'::timestamptz
from generate_series(7, 8) i;

-- Families 1 and 2 are back four weeks after signing up.
insert into public.requests (household_id, requested_by_member_id, title, created_at)
select pg_temp.id(1, i), pg_temp.id(4, i), 'Pie', '2026-09-01 16:00Z'::timestamptz from generate_series(1, 2) i;

-- Who can run it ------------------------------------------------------------------------------------------------------

select ok(not has_function_privilege('anon', 'internal.metrics(date, date)', 'execute'), 'not for anon');
select ok(not has_function_privilege('authenticated', 'internal.metrics(date, date)', 'execute'),
  'not for signed-in people');
select ok(not has_function_privilege('public', 'internal.metrics(date, date)', 'execute'), 'not for public');
select ok(has_function_privilege('service_role', 'internal.metrics(date, date)', 'execute'), 'for service_role');
select ok(not has_schema_privilege('anon', 'internal', 'usage'), 'anon can''t reach the schema');
select ok(not has_schema_privilege('authenticated', 'internal', 'usage'), 'signed-in people can''t reach the schema');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc
           where proname = 'metrics' and pronamespace = 'internal'::regnamespace),
  'security definer, with an empty search path');
select is((select provolatile from pg_proc where proname = 'metrics' and pronamespace = 'internal'::regnamespace), 's',
  'read-only');

select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id(2, 1), 'role', 'authenticated')::text, true);
set local role authenticated;
select throws_ok($$ select internal.metrics('2026-08-03', '2026-08-31') $$, '42501', null,
  'a planner calling it is refused');
reset role;
set local role anon;
select throws_ok($$ select internal.metrics('2026-08-03', '2026-08-31') $$, '42501', null, 'anon calling it is refused');
reset role;

create temp table result as select internal.metrics('2026-08-03', '2026-09-04') as m;

-- What it says ----------------------------------------------------------------------------------------------------------

select is((select jsonb_agg(e -> 'week') from result, jsonb_array_elements(m -> 'weeks') e),
  '["2026-08-03", "2026-08-10", "2026-08-17", "2026-08-24", "2026-08-31"]'::jsonb,
  'one entry per ISO week, Monday first, through the week the range ends in');
select is((select m -> 'min_households' from result), '5'::jsonb, 'it says how small a cell it hides');
select ok((select m::text !~* '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' from result),
  'no ids anywhere');
select ok((select m::text !~ '(Pat|Kit|Bob|Tacos|Ramen|Pie|Household)' from result), 'no names or dishes anywhere');

select is((select pg_temp.week(m, '2026-08-10') -> 'dinners' from result), '10'::jsonb,
  'ten dinners: the sample family''s left out, and so are eating out and fending for yourselves');
select is((select pg_temp.week(m, '2026-08-10') -> 'shared_dinners' from result), '5'::jsonb,
  'a kid''s request, claim, cooking, me too and vote each count; a planner''s or the owner''s own, or a claim taken back, don''t');
select is((select (pg_temp.week(m, '2026-08-10') ->> 'north_star')::numeric from result), 0.5,
  'north star: half the dinners had someone other than a planner pitching in');
select is((select (pg_temp.week(m, '2026-08-10') ->> 'contributors_per_household')::numeric from result), 2.0,
  'median contributors: the kid, and Bob''s ask counted on his household''s Sunday');
select is((select (pg_temp.week(m, '2026-08-10') ->> 'after_dinner_response_rate')::numeric from result), 0.25,
  'response rate: 5 ratings for 20 people home at a logged dish');
select is((select pg_temp.week(m, '2026-08-10') -> 'plans_approved' from result), '5'::jsonb, 'plans approved');
select is((select pg_temp.week(m, '2026-08-10') -> 'active_households' from result), '5'::jsonb,
  'weekly active households');
select is((select pg_temp.week(m, '2026-08-10') -> 'households' from result), 'null'::jsonb,
  'households signed up by the week''s end: under 10 is null, not a rounded 0');

select is((select pg_temp.week(m, '2026-08-03') -> 'signups' from result), '5'::jsonb, 'signups that week');
select is((select (pg_temp.week(m, '2026-08-03') ->> 'onboarding_completion')::numeric from result), 0.8,
  'onboarding completion: one of five hasn''t finished');
select is((select (pg_temp.week(m, '2026-08-03') ->> 'first_plan_rate')::numeric from result), 1.0,
  'every family there has approved a plan');
select is((select (pg_temp.week(m, '2026-08-03') ->> 'median_hours_to_first_plan')::numeric from result), 36.0,
  'median time to a first approved plan: 12, 24, 36, 48 and 60 hours');
select is((select (pg_temp.week(m, '2026-08-03') ->> 'retention_w1')::numeric from result), 1.0,
  'week-1 retention: all five did something the next week');
select is((select (pg_temp.week(m, '2026-08-03') ->> 'retention_w4')::numeric from result), 0.4,
  'week-4 retention: two of five were back');

select is((select jsonb_build_object(
             'signups', w -> 'signups', 'onboarding_completion', w -> 'onboarding_completion',
             'first_plan_rate', w -> 'first_plan_rate', 'retention_w1', w -> 'retention_w1',
             'retention_w4', w -> 'retention_w4')
           from result, pg_temp.week(m, '2026-08-10') w),
  '{"signups": null, "onboarding_completion": null, "first_plan_rate": null, "retention_w1": null,
    "retention_w4": null}'::jsonb,
  'two sign-ups in a week: none of that week''s sign-up numbers show');
select is((select jsonb_build_object('dinners', w -> 'dinners', 'plans_approved', w -> 'plans_approved')
           from result, pg_temp.week(m, '2026-08-24') w),
  '{"dinners": null, "plans_approved": null}'::jsonb,
  'a week that was never approved has no dinners and no plans');
select is((select pg_temp.week(m, '2026-08-03') -> 'dinners' from result), 'null'::jsonb,
  'no dinners that week is no number, not zero');
select is((select pg_temp.week(m, '2026-08-10') -> 'shopping_trips' from result), 'null'::jsonb,
  'no finished trips that week is no number (91 covers trips)');
select is((select pg_temp.week(m, '2026-08-10') -> 'trial_to_paid' from result), 'null'::jsonb,
  'trial-to-paid waits on #66');

-- Four households is too few ------------------------------------------------------------------------------------------

select is((select jsonb_build_object(
             'dinners', w -> 'dinners', 'north_star', w -> 'north_star', 'plans_approved', w -> 'plans_approved',
             'active_households', w -> 'active_households',
             'contributors_per_household', w -> 'contributors_per_household')
           from result, pg_temp.week(m, '2026-08-17') w),
  '{"dinners": null, "north_star": null, "plans_approved": null, "active_households": null,
    "contributors_per_household": null}'::jsonb,
  'four households in a week: every number is suppressed');

-- Family 5 plans and logs that week too, with a week that starts on Sunday the 16th: it belongs with the ISO week of its
-- middle day, August 19, not the week its Sunday is in. Its owner cooks: still a planner, so the dinner isn't shared.
insert into public.plans (id, household_id, week_start, approved_at)
values (pg_temp.id(12, 5), pg_temp.id(1, 5), '2026-08-16', '2026-08-16 12:00Z');
insert into public.plan_nights (id, household_id, plan_id, date, meal_id)
values (pg_temp.id(13, 5), pg_temp.id(1, 5), pg_temp.id(12, 5), '2026-08-17', pg_temp.id(6, 5));
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id, created_at, updated_at)
values (pg_temp.id(14, 5), pg_temp.id(1, 5), pg_temp.id(13, 5), pg_temp.id(6, 5), pg_temp.id(3, 5),
        '2026-08-18 01:00Z', '2026-08-18 01:00Z');

create temp table five_weeks as select internal.metrics('2026-08-10', '2026-08-17') as m;
create temp table five as select pg_temp.week(m, '2026-08-17') as w from five_weeks;
select is((select w -> 'dinners' from five), '5'::jsonb, 'five households: the dinners show');
select is((select (w ->> 'north_star')::numeric from five), 0.0, 'and none were shared: the owner cooked');
select is((select w -> 'plans_approved' from five), '5'::jsonb,
  'plans approved show, the Sunday-start week counted with its middle');
select is((select pg_temp.week(m, '2026-08-10') -> 'plans_approved' from five_weeks), '5'::jsonb,
  'and not in the week its Sunday falls in');
select is((select w -> 'active_households' from five), '5'::jsonb, 'active households show');
select is((select (w ->> 'contributors_per_household')::numeric from five), 0.0,
  'nobody but planners pitched in that week');

select is(internal.metrics('2026-08-17', '2026-08-03') -> 'weeks', '[]'::jsonb, 'a backwards range is empty');

-- Five families sign up this week, on UTC so their week is the server's. None has planned yet.
insert into public.households (id, name, owner, settings)
select pg_temp.id(1, i), format('Household %s', i), null::uuid, '{"time_zone": "UTC"}'::jsonb
from generate_series(9, 13) i;

create temp table this_week as select pg_temp.week(internal.metrics(current_date, current_date),
                                                   date_trunc('week', current_date::timestamp)::date) as w;
select is((select w -> 'signups' from this_week), '5'::jsonb, 'this week''s five sign-ups show');
select is((select w -> 'retention_w1' from this_week), 'null'::jsonb, 'week-1 retention waits for next week to be over');
select is((select w -> 'median_hours_to_first_plan' from this_week), 'null'::jsonb,
  'five signed up but none has a plan: no median time to one');
select is((select w -> 'households' from this_week), '10'::jsonb, '12 households so far, rounded down to 10');

select * from finish();
rollback;
