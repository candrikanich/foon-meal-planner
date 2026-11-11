-- Finished shopping trips (#260), so internal.metrics can count them (docs/metrics.md).
--
-- A trip lives on the shopper's phone until Finish trip. Finishing one now also records, on the server, that the
-- household finished a trip and when: no items, names, store or who shopped. The phone gives the trip an id and sends it
-- through its offline queue, so a finish made offline arrives when the phone reconnects, and a resend is ignored.
--
-- 1. shopping_trips: household and time only. Members of the household can read theirs (it's in the export); nobody
--    writes it except record_shopping_trip. Kept 13 months (a year to compare against, plus a month), pruned daily, and
--    erased with the household (on delete cascade).
-- 2. record_shopping_trip(trip_id, target_household, trip_finished_at): security definer, for a member of the household.
--    The time is the phone's, kept within the last 30 days and never later than now, since a queued finish can arrive
--    late and a phone's clock can be wrong.
-- 3. internal.metrics fills shopping_trips per ISO week (k = 5 households, as every other number).
-- 4. export_household includes the household's trips.

create table public.shopping_trips (
  id uuid primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  finished_at timestamptz not null
);

create index shopping_trips_household_finished on public.shopping_trips (household_id, finished_at);
create index shopping_trips_finished on public.shopping_trips (finished_at);

alter table public.shopping_trips enable row level security;

create policy "members read their household's trips" on public.shopping_trips
  for select to authenticated using (public.is_household_member(household_id));

revoke all on table public.shopping_trips from anon;
revoke insert, update, delete, truncate on table public.shopping_trips from authenticated;

create function public.record_shopping_trip(trip_id uuid, target_household uuid, trip_finished_at timestamptz)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_household_member(target_household) then
    raise exception 'not a member of household %', target_household using errcode = '42501';
  end if;
  insert into public.shopping_trips (id, household_id, finished_at)
  values (trip_id, target_household, least(now(), greatest(trip_finished_at, now() - interval '30 days')))
  on conflict (id) do nothing;
end;
$$;

revoke execute on function public.record_shopping_trip(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.record_shopping_trip(uuid, uuid, timestamptz) to authenticated;

create function public.prune_shopping_trips()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.shopping_trips where finished_at < now() - interval '13 months';
$$;

revoke execute on function public.prune_shopping_trips() from public, anon, authenticated;

select cron.schedule('prune-shopping-trips', '53 3 * * *', 'select public.prune_shopping_trips()');

-- As 20261106090000_internal_metrics, with shopping_trips counted.
create or replace function internal.metrics(from_week date, to_week date)
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
  -- Finished shopping trips (#260), by the household's day the trip finished.
  trips as (
    select t.household_id, date_trunc('week', t.finished_at at time zone h.zone)::date as week
    from public.shopping_trips t
    join homes h on h.id = t.household_id
    cross join params
    where t.finished_at >= params.first_week - 2
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
           co.signups, co.onboarded, co.planned, co.median_hours, co.back_week_1, co.back_week_4,
           tr.trips, tr.households as trip_households
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
    cross join lateral (
      select count(*) as trips, count(distinct t.household_id) as households from trips t where t.week = w.week
    ) tr
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
      'shopping_trips', case when pw.trip_households >= pw.k then pw.trips end,
      'trial_to_paid', null
    ) order by pw.week), '[]'::jsonb)
  )
  from per_week pw;
$$;

revoke all on function internal.metrics(date, date) from public, anon, authenticated;
grant execute on function internal.metrics(date, date) to service_role;

-- As 20261117000000_agreements, plus the household's shopping trips.
create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not (public.is_household_planner(target_household) or public.is_household_manager(target_household)) then
    raise exception 'only planners and parents export the household' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'household', (select to_jsonb(h) - 'owner' from public.households h where id = target_household),
    'members', (select coalesce(jsonb_agg(to_jsonb(m) - 'user_id' - 'household_id' order by m.created_at), '[]')
                from public.members m where household_id = target_household),
    'allergies', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                  from public.member_allergies a where household_id = target_household),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' - 'granted_by' order by c.granted_at), '[]')
                 from public.consents c where household_id = target_household),
    'consent_agreements', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id' - 'agreed_by' order by a.agreed_at), '[]')
                           from public.consent_agreements a where household_id = target_household),
    'agreement_holds', (
      select coalesce(jsonb_agg(to_jsonb(h) order by h.held_at), '[]')
      from (select id, kind, member_id, consent_id, held_version, required_version, was_linked, held_at, released_at,
                   released_reason, relinked
            from public.agreement_holds where household_id = target_household) h),
    'parental_consent_requests', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]')
      from (select id, member_id, status, reason, email_source, text_version, token_sent_at, expires_at, decided_at,
                   confirmed_at, ended_at, created_at
            from public.parental_consent_requests where household_id = target_household) r),
    'meals', (select coalesce(jsonb_agg(to_jsonb(m) - 'household_id' order by m.name), '[]')
              from public.meals m where household_id = target_household),
    'meal_ingredients', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id'), '[]')
                         from public.meal_ingredients i where household_id = target_household),
    'meal_sides', (select coalesce(jsonb_agg(to_jsonb(s) - 'household_id'), '[]')
                   from public.meal_sides s where household_id = target_household),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id' order by i.canonical_name), '[]')
              from public.items i where household_id = target_household),
    'traditions', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id'), '[]')
                   from public.traditions t where household_id = target_household),
    'plans', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.week_start), '[]')
              from public.plans p where household_id = target_household),
    'nights', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.date), '[]')
               from public.plan_nights n where household_id = target_household),
    'attendance', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                   from public.night_attendance a where household_id = target_household),
    'list_items', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id'), '[]')
                   from public.list_items l where household_id = target_household),
    'meal_logs', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                  from public.meal_logs l where household_id = target_household),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                  from public.reactions r where household_id = target_household),
    'hidden_comments', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.hidden_at), '[]')
                        from public.hidden_comments c where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household),
    'attendance_templates', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                             from public.attendance_templates t where household_id = target_household),
    'freezer_stash', (select coalesce(jsonb_agg(to_jsonb(f) - 'household_id' order by f.created_at), '[]')
                      from public.freezer_stash f where household_id = target_household),
    'night_claims', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.created_at), '[]')
                     from public.night_claims c where household_id = target_household),
    'plan_changes', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.id), '[]')
                     from public.plan_changes c where household_id = target_household),
    'notification_log', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                         from public.notification_log l where household_id = target_household),
    'polls', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
              from public.polls p where household_id = target_household),
    'poll_votes', (select coalesce(jsonb_agg(to_jsonb(v) - 'household_id' order by v.voted_at), '[]')
                   from public.poll_votes v where household_id = target_household),
    'receipt_aliases', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.raw_text), '[]')
                        from public.receipt_aliases r where household_id = target_household),
    'ai_jobs', (select coalesce(jsonb_agg(to_jsonb(j) - 'household_id' order by j.created_at), '[]')
                from public.ai_jobs j where household_id = target_household),
    'shopping_trips', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.finished_at), '[]')
                       from public.shopping_trips t where household_id = target_household)
  );
end;
$$;
