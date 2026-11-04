-- The planner engagement view (#235): who's pitching in, for planners only (docs/spec.md → Keeping kids engaged
-- without nagging). It celebrates what people did and gives a parent a quiet note to nudge in person; the app words it
-- and never ranks, totals or compares anyone. Read-only, and it reads only what's already stored: no new tracking.
--
-- Security invoker, not definer: every table it reads (members, requests, request_plus_ones, reactions, meal_logs,
-- plan_nights, plans, night_attendance, night_claims) is readable by any member of the household under row-level
-- security, so a planner already reads all of it. The planner check on top is what keeps it from members and kids: it
-- raises 42501 for anyone who isn't a planner of the household (another household's planner included).
--
-- One entry per member not removed, in the order they joined; the app shows them in family order. Days are the
-- household's: a request or me-too counts on the household day it was made, everything else on its night's date, and
-- both ends of [from_date, to_date] are included.
--   * ideas: requests they asked for (themselves, or with the phone passed to them), whatever happened to them since.
--   * me_toos: their me-toos, as they stand now; one taken back is gone, so it doesn't count.
--   * rated: dinners they reacted to.
--   * check_ins: "Home tonight?" answers still on record. A planner's later change to that night's attendance
--     clears the answer (20261101130000_day_of_check_in.sql), so it no longer counts.
--   * claimed: nights they offered to cook that they haven't taken back.
--   * cooked: the nights, in order, of logged dishes they cooked, in approved weeks; quick picks aren't cooking, as for
--     cook credit.
--   * last_idea_on: the latest household day, up to to_date, they asked for something or said me too, whenever it was;
--     null if never. joined_on: the household day their profile was made. Both are for the app's "in 3 weeks" note.
-- Someone who eats separately doesn't rate, cook, claim or count toward me-toos (docs/spec.md → Outliers), so those
-- are zero for them; ideas and check-ins count as stored.

create function public.engagement(target_household uuid, from_date date, to_date date)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  household_zone text;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners see who''s pitching in' using errcode = '42501';
  end if;

  select public.valid_time_zone(h.settings ->> 'time_zone') into household_zone
  from public.households h where h.id = target_household;
  household_zone := coalesce(household_zone, 'America/New_York');

  return (
    with people as (
      select m.id, m.eats_separately, m.created_at
      from public.members m
      where m.household_id = target_household and m.status <> 'removed'
    ),
    asked as (
      select r.requested_by_member_id as member_id, (r.created_at at time zone household_zone)::date as day,
             false as me_too
      from public.requests r
      where r.household_id = target_household
      union all
      select p.member_id, (p.created_at at time zone household_zone)::date, true
      from public.request_plus_ones p
      where p.household_id = target_household
    ),
    rated as (
      select r.member_id, count(*) as dinners
      from public.reactions r
      join public.meal_logs l on l.id = r.meal_log_id and l.household_id = r.household_id
      join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
      where r.household_id = target_household and n.date between from_date and to_date
      group by r.member_id
    ),
    checked_in as (
      select a.member_id, count(*) as nights
      from public.night_attendance a
      join public.plan_nights n on n.id = a.plan_night_id and n.household_id = a.household_id
      where a.household_id = target_household
        and a.checked_in_at is not null
        and n.date between from_date and to_date
      group by a.member_id
    ),
    claimed as (
      select c.member_id, count(distinct c.night_id) as nights
      from public.night_claims c
      join public.plan_nights n on n.id = c.night_id and n.household_id = c.household_id
      where c.household_id = target_household
        and c.released_at is null
        and n.date between from_date and to_date
      group by c.member_id
    ),
    cooked as (
      select l.cooked_by_member_id as member_id, jsonb_agg(n.date order by n.date) as nights
      from public.meal_logs l
      join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
      join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
      where l.household_id = target_household
        and p.approved_at is not null
        and l.meal_id is not null
        and l.cooked_by_member_id is not null
        and n.date between from_date and to_date
      group by l.cooked_by_member_id
    )
    select jsonb_build_object('members', coalesce(jsonb_agg(jsonb_build_object(
      'member_id', p.id,
      'ideas', (select count(*) from asked a
                where a.member_id = p.id and not a.me_too and a.day between from_date and to_date),
      'me_toos', case when p.eats_separately then 0 else
                   (select count(*) from asked a
                    where a.member_id = p.id and a.me_too and a.day between from_date and to_date) end,
      'rated', case when p.eats_separately then 0 else
                 coalesce((select r.dinners from rated r where r.member_id = p.id), 0) end,
      'check_ins', coalesce((select c.nights from checked_in c where c.member_id = p.id), 0),
      'claimed', case when p.eats_separately then 0 else
                   coalesce((select c.nights from claimed c where c.member_id = p.id), 0) end,
      'cooked', case when p.eats_separately then '[]'::jsonb else
                  coalesce((select c.nights from cooked c where c.member_id = p.id), '[]'::jsonb) end,
      'last_idea_on', (select max(a.day) from asked a where a.member_id = p.id and a.day <= to_date),
      'joined_on', (p.created_at at time zone household_zone)::date
    ) order by p.created_at, p.id), '[]'::jsonb))
    from people p
  );
end;
$$;

revoke execute on function public.engagement(uuid, date, date) from public, anon;
grant execute on function public.engagement(uuid, date, date) to authenticated;
