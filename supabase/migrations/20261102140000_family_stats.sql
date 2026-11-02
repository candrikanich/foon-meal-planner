-- Family stats (#56, part 1): the counts behind "This month" on the Family tab (docs/spec.md → Success metrics: shown to
-- families). Read-only and security invoker, so row-level security decides what's counted: another household's caller
-- sees nothing and gets zeros.
--
-- Only nights in approved plans with a date in [from_date, to_date] count, so a draft week isn't "planned together".
--   * dinners: those nights with a dish or a quick pick. dishes: those with a dish.
--   * ideas: nights with a dish that a request landed on, asked by someone whose role is member (not a planner or the
--     owner). One night with two such requests is one idea.
--   * cooked_by_others: logged dishes cooked by someone other than the usual cook. The usual cook is whoever cooked the
--     most logged dishes on approved nights in the 90 days ending to_date; a tie makes everyone tied usual. Quick picks
--     aren't cooking, as for cook credit.
--   * at_table: logged dinners eaten at home: a dish, leftovers, takeout, or a freezer raid. Eating out and fending for
--     yourselves don't count.
--   * new_dishes: dishes logged on those nights whose first log in the household, on any plan, falls in the range.
--   * weeks_planned: approved plans whose week overlaps the range.

create function public.family_stats(target_household uuid, from_date date, to_date date)
returns json
language sql stable security invoker set search_path = ''
as $$
  with nights as (
    select n.id, n.meal_id, n.quick_pick
    from public.plan_nights n
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    where n.household_id = target_household
      and p.approved_at is not null
      and n.date between from_date and to_date
  ),
  logs as (
    select l.meal_id, l.quick_pick, l.cooked_by_member_id
    from public.meal_logs l
    join nights n on n.id = l.night_id
  ),
  cooked as (
    select l.cooked_by_member_id as cook, count(*) as dinners
    from public.meal_logs l
    join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    where l.household_id = target_household
      and p.approved_at is not null
      and l.meal_id is not null
      and l.cooked_by_member_id is not null
      and n.date between to_date - 89 and to_date
    group by l.cooked_by_member_id
  ),
  usual_cooks as (
    select cook from cooked where dinners = (select max(dinners) from cooked)
  ),
  first_logged as (
    select l.meal_id, min(n.date) as first_night
    from public.meal_logs l
    join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
    where l.household_id = target_household and l.meal_id is not null
    group by l.meal_id
  )
  select json_build_object(
    'dinners', (select count(*) from nights where meal_id is not null or quick_pick is not null),
    'dishes', (select count(*) from nights where meal_id is not null),
    'ideas', (
      select count(*) from nights n
      where n.meal_id is not null
        and exists (
          select 1 from public.requests r
          join public.members m on m.id = r.requested_by_member_id and m.household_id = r.household_id
          where r.planned_night_id = n.id and m.role = 'member'
        )
    ),
    'cooked_by_others', (
      select count(*) from logs
      where meal_id is not null
        and cooked_by_member_id is not null
        and cooked_by_member_id not in (select cook from usual_cooks)
    ),
    'at_table', (
      select count(*) from logs
      where meal_id is not null or quick_pick in ('leftovers', 'takeout', 'freezer_raid')
    ),
    'new_dishes', (
      select count(distinct l.meal_id) from logs l
      join first_logged f on f.meal_id = l.meal_id
      where f.first_night between from_date and to_date
    ),
    'weeks_planned', (
      select count(*) from public.plans p
      where p.household_id = target_household
        and p.approved_at is not null
        and p.week_start <= to_date
        and p.week_start + 6 >= from_date
    )
  );
$$;

revoke execute on function public.family_stats(uuid, date, date) from public, anon;
grant execute on function public.family_stats(uuid, date, date) to authenticated;
