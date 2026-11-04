-- Internal metrics (#36): whether Foon shares the load, measured anonymously from what's already stored (docs/metrics.md,
-- docs/spec.md → Success metrics: internal). No new tracking: no events, no columns, nothing the app sends.
--
-- internal.metrics(from_week, to_week) returns one object per ISO week (Monday to Sunday) from from_week's week through
-- to_week's, with counts and rates pooled over every household. It never returns an id, a name, a dish, or anything about
-- one household: each number is built from at least 5 households or it's null (small-cell suppression).
--
-- Who can run it: only service_role and the dashboard's SQL editor (postgres). The `internal` schema isn't one PostgREST
-- exposes (supabase/config.toml → api.schemas), and usage on it and execute on the function are revoked from public, anon
-- and authenticated. Security definer so it reads past row-level security, with an empty search path.
--
-- Rules (the planner, household-day and dinner rules are reused from is_household_planner, engagement and family_stats):
--   * Sample families (settings.sample, or settings.sample_pending while one is being filled in) aren't counted. This rule
--     is new here: the family-facing functions count a sample family's own data for that family.
--   * A planner is a member whose role is planner, or whose account owns the household (is_household_planner's rule).
--     It's the role as it stands now; the database doesn't keep role history.
--   * Days are the household's: a night's date is already its household day, and a timestamp is read in the household's
--     time zone (New York when none is saved, as household_today does).
--   * A dinner is a logged dinner at the table on a night of an approved week: a dish, leftovers, takeout or a freezer raid
--     (family_stats' at_table). Eating out and fending for yourselves aren't dinners anyone helped with at home.
--   * Someone other than the planner contributed to a dinner when a non-planner asked for what landed on that night
--     (a request planned there), said me too to it, voted in that night's poll, holds a claim on the night (not taken
--     back), or cooked its dish. Quick picks aren't cooking, as for cook credit.
--   * A household is active in a week when anyone in it did something stored that week: added a member, asked, said me
--     too, reacted, voted or started a poll, claimed or released a night, confirmed a dinner, thanked the cook, answered a
--     check-in, made or approved a plan, added a dish, or added or checked off a list line. The overnight job's
--     unconfirmed logs aren't anyone doing something, so only confirmed logs count.
--
-- Waiting on something, so always null: shopping_trips (a trip lives on the shopper's device until Finish trip and is never
-- stored; store runs are pruned after a day and aren't trips) and trial_to_paid (StoreKit and entitlements are #66).

create schema if not exists internal;
revoke all on schema internal from public, anon, authenticated;
grant usage on schema internal to service_role;

create function internal.metrics(from_week date, to_week date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with params as (
    select date_trunc('week', from_week::timestamp)::date as first_week,
           date_trunc('week', to_week::timestamp)::date as last_week,
           5 as min_households
  ),
  weeks as (
    select w::date as week
    from params, generate_series(params.first_week::timestamp, params.last_week::timestamp, interval '1 week') w
  ),
  homes as (
    select h.id, h.owner, h.settings, h.created_at,
           coalesce(public.valid_time_zone(h.settings ->> 'time_zone'), 'America/New_York') as zone
    from public.households h
    where coalesce(h.settings ->> 'sample', 'false') <> 'true'
      and coalesce(h.settings ->> 'sample_pending', 'false') <> 'true'
  ),
  people as (
    select m.id, m.household_id, m.status, m.eats_separately,
           (m.role = 'planner' or (m.user_id is not null and m.user_id = h.owner)) as planner
    from public.members m
    join homes h on h.id = m.household_id
  ),
  dinners as (
    select n.id as night_id, n.household_id, date_trunc('week', n.date::timestamp)::date as week,
           l.id as log_id, l.meal_id
    from public.plan_nights n
    join homes h on h.id = n.household_id
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    join public.meal_logs l on l.night_id = n.id and l.household_id = n.household_id
    cross join params
    where p.approved_at is not null
      and (l.meal_id is not null or l.quick_pick in ('leftovers', 'takeout', 'freezer_raid'))
      and n.date between params.first_week and params.last_week + 6
  ),
  night_help as (
    select r.planned_night_id as night_id, r.requested_by_member_id as member_id
    from public.requests r
    where r.planned_night_id is not null
    union
    select r.planned_night_id, o.member_id
    from public.request_plus_ones o
    join public.requests r on r.id = o.request_id and r.household_id = o.household_id
    where r.planned_night_id is not null
    union
    select q.night_id, v.member_id
    from public.poll_votes v
    join public.polls q on q.id = v.poll_id and q.household_id = v.household_id
    union
    select c.night_id, c.member_id
    from public.night_claims c
    where c.released_at is null
    union
    select l.night_id, l.cooked_by_member_id
    from public.meal_logs l
    where l.meal_id is not null and l.cooked_by_member_id is not null
  ),
  helpers as (
    select distinct d.night_id, d.household_id, d.week, x.member_id
    from dinners d
    join night_help x on x.night_id = d.night_id
    join people m on m.id = x.member_id and m.household_id = d.household_id and not m.planner
  ),
  -- Asking counts the week it was asked, whether or not it's been planned yet.
  contributors as (
    select household_id, week, member_id from helpers
    union
    select a.household_id, date_trunc('week', a.at at time zone h.zone)::date, a.member_id
    from (
      select r.household_id, r.requested_by_member_id as member_id, r.created_at as at from public.requests r
      union all
      select o.household_id, o.member_id, o.created_at from public.request_plus_ones o
    ) a
    join homes h on h.id = a.household_id
    join people m on m.id = a.member_id and not m.planner
  ),
  household_weeks as (
    select d.household_id, d.week, count(*) as dinners, count(s.night_id) as shared
    from dinners d
    left join (select distinct night_id from helpers) s on s.night_id = d.night_id
    group by d.household_id, d.week
  ),
  household_contributors as (
    select hw.household_id, hw.week,
           (select count(distinct c.member_id) from contributors c
            where c.household_id = hw.household_id and c.week = hw.week) as contributors
    from household_weeks hw
  ),
  -- Who was marked home for a logged dish and could rate it: not removed, and not someone who eats separately (they
  -- don't rate). Any reaction they left on that dinner is an answer.
  responses as (
    select d.household_id, d.week, count(*) as eaters, count(r.id) as answered
    from dinners d
    join public.night_attendance a on a.plan_night_id = d.night_id and a.household_id = d.household_id and a.expected
    join people m on m.id = a.member_id and m.status <> 'removed' and not m.eats_separately
    left join public.reactions r on r.meal_log_id = d.log_id and r.member_id = a.member_id
    where d.meal_id is not null
    group by d.household_id, d.week
  ),
  activity as (
    select household_id, created_at as at from public.members
    union all select household_id, created_at from public.requests
    union all select household_id, created_at from public.request_plus_ones
    union all select household_id, created_at from public.reactions
    union all select household_id, voted_at from public.poll_votes
    union all select household_id, created_at from public.polls
    union all select household_id, created_at from public.night_claims
    union all select household_id, released_at from public.night_claims where released_at is not null
    union all select household_id, updated_at from public.meal_logs where verified
    union all select household_id, created_at from public.chef_thanks
    union all select household_id, checked_in_at from public.night_attendance where checked_in_at is not null
    union all select household_id, created_at from public.plans
    union all select household_id, approved_at from public.plans where approved_at is not null
    union all select household_id, created_at from public.meals
    union all select household_id, created_at from public.list_items
    union all select household_id, checked_at from public.list_items where checked_at is not null
  ),
  active_weeks as (
    select distinct a.household_id, date_trunc('week', a.at at time zone h.zone)::date as week
    from activity a
    join homes h on h.id = a.household_id
    cross join params
    where a.at >= params.first_week - 2
  ),
  -- Sign-up cohorts, by the household's day it was made. A household from before onboarding has no flag and counts
  -- as done, as the app reads it.
  cohorts as (
    select c.*,
           exists (select 1 from active_weeks a where a.household_id = c.id and a.week = c.week + 7) as back_week_1,
           exists (select 1 from active_weeks a where a.household_id = c.id and a.week = c.week + 28) as back_week_4
    from (
      select h.id, h.created_at, date_trunc('week', h.created_at at time zone h.zone)::date as week,
             coalesce(h.settings ->> 'onboarded', 'true') <> 'false' as onboarded,
             (select min(p.approved_at) from public.plans p where p.household_id = h.id) as first_approved_at
      from homes h
    ) c
    cross join params
    where c.week between params.first_week and params.last_week
  ),
  per_week as (
    select w.week, k.min_households as k,
           (select count(*) from homes h where (h.created_at at time zone h.zone)::date <= w.week + 6) as households,
           (select count(*) from active_weeks a where a.week = w.week) as active,
           pa.plans as plans_approved, pa.households as plan_households,
           ns.households as dinner_households, ns.dinners, ns.shared,
           (select percentile_cont(0.5) within group (order by hc.contributors)
            from household_contributors hc where hc.week = w.week) as median_contributors,
           rr.households as response_households, rr.eaters, rr.answered,
           co.signups, co.onboarded, co.planned, co.median_hours, co.back_week_1, co.back_week_4
    from weeks w
    cross join params k
    cross join lateral (
      select count(*) as households, coalesce(sum(hw.dinners), 0) as dinners, coalesce(sum(hw.shared), 0) as shared
      from household_weeks hw where hw.week = w.week
    ) ns
    -- A plan's week can start on any day (Sunday by default), so it goes in the ISO week of its middle day, the one
    -- holding most of its dinners.
    cross join lateral (
      select count(*) as plans, count(distinct p.household_id) as households
      from public.plans p join homes h on h.id = p.household_id
      where p.approved_at is not null and date_trunc('week', (p.week_start + 3)::timestamp)::date = w.week
    ) pa
    cross join lateral (
      select count(*) as households, coalesce(sum(r.eaters), 0) as eaters, coalesce(sum(r.answered), 0) as answered
      from responses r where r.week = w.week
    ) rr
    cross join lateral (
      select count(*) as signups,
             count(*) filter (where c.onboarded) as onboarded,
             count(c.first_approved_at) as planned,
             percentile_cont(0.5) within group (
               order by extract(epoch from c.first_approved_at - c.created_at)::float8 / 3600) as median_hours,
             count(*) filter (where c.back_week_1) as back_week_1,
             count(*) filter (where c.back_week_4) as back_week_4
      from cohorts c where c.week = w.week
    ) co
  )
  select jsonb_build_object(
    'min_households', (select min_households from params),
    'weeks', coalesce(jsonb_agg(jsonb_build_object(
      'week', pw.week,
      'iso_week', to_char(pw.week, 'IYYY-"W"IW'),
      -- Rounded down to tens: week-to-week differences in an exact running total would give away suppressed signups.
      -- Under 10 is null rather than 0, which would read as no households at all.
      'households', case when pw.households >= 10 then (pw.households / 10) * 10 end,
      'active_households', case when pw.active >= pw.k then pw.active end,
      'plans_approved', case when pw.plan_households >= pw.k then pw.plans_approved end,
      'dinners', case when pw.dinner_households >= pw.k then pw.dinners end,
      'shared_dinners', case when pw.dinner_households >= pw.k then pw.shared end,
      'north_star', case when pw.dinner_households >= pw.k
                         then round(pw.shared::numeric / nullif(pw.dinners, 0), 3) end,
      'contributors_per_household', case when pw.dinner_households >= pw.k
                                         then round(pw.median_contributors::numeric, 1) end,
      'after_dinner_response_rate', case when pw.response_households >= pw.k
                                         then round(pw.answered::numeric / nullif(pw.eaters, 0), 3) end,
      'signups', case when pw.signups >= pw.k then pw.signups end,
      'onboarding_completion', case when pw.signups >= pw.k
                                    then round(pw.onboarded::numeric / pw.signups, 3) end,
      'first_plan_rate', case when pw.signups >= pw.k then round(pw.planned::numeric / pw.signups, 3) end,
      'median_hours_to_first_plan', case when pw.planned >= pw.k then round(pw.median_hours::numeric, 1) end,
      -- A cohort's week 1 or week 4 has to be over before it's a number, in every time zone: current_date is UTC's, so
      -- a day's margin covers households behind it.
      'retention_w1', case when pw.signups >= pw.k and pw.week + 13 < current_date - 1
                           then round(pw.back_week_1::numeric / pw.signups, 3) end,
      'retention_w4', case when pw.signups >= pw.k and pw.week + 34 < current_date - 1
                           then round(pw.back_week_4::numeric / pw.signups, 3) end,
      'shopping_trips', null,
      'trial_to_paid', null
    ) order by pw.week), '[]'::jsonb)
  )
  from per_week pw;
$$;

revoke all on function internal.metrics(date, date) from public, anon, authenticated;
grant execute on function internal.metrics(date, date) to service_role;
