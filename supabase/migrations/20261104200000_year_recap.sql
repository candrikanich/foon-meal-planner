-- The yearly recap (#65, part 2): "Your year in dinners" (docs/spec.md → Success metrics: shown to families).
-- Read-only and security invoker, so row-level security decides what's read: another household's caller gets nothing.
--
-- One calendar year by the household's day: a night's date is its household day, so a dinner late on December 31
-- counts in that year whenever it was logged. Only logs on nights of approved plans count, as on the stats card.
--   * logged: how many dinners were logged that year. None means no recap.
--   * stats: family_stats for the year: at the table, someone else's idea, new dishes, weeks planned. (Its
--     cooked_by_others measures the usual cook over the 90 days ending December 31, so the recap doesn't show it.)
--   * top_dishes: up to 3 dishes, most times logged first; a tie goes to the dish with more favorite and good reactions
--     that year (removed members and people who eat separately don't count, as for verdicts), then the name. Archived
--     and retired dishes still count: it's a memory, and it's about the food.
--   * cooks: who cooked a dish, in the order they first did that year, for a thank-you. Never counted or ranked; quick
--     picks aren't cooking, and someone since removed isn't thanked.
--   * tried: who tried a dish new to them that year, from tried_new, in the order they first did. No counts.

create function public.year_recap(target_household uuid, target_year int)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  with bounds as (
    select make_date(target_year, 1, 1) as from_date, make_date(target_year, 12, 31) as to_date
  ),
  logs as (
    select l.id, l.meal_id, l.cooked_by_member_id, n.date
    from public.meal_logs l
    join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    cross join bounds b
    where l.household_id = target_household
      and p.approved_at is not null
      and n.date between b.from_date and b.to_date
  ),
  cooks as (
    select l.cooked_by_member_id as member_id, min(l.date) as first_night
    from logs l
    join public.members m on m.id = l.cooked_by_member_id and m.household_id = target_household
    where l.meal_id is not null and m.status <> 'removed'
    group by l.cooked_by_member_id
  ),
  liked as (
    select l.meal_id, count(*) as fans
    from logs l
    join public.reactions r on r.meal_log_id = l.id
    join public.members m on m.id = r.member_id and m.household_id = target_household
    where l.meal_id is not null
      and r.reaction in ('favorite', 'good')
      and m.status <> 'removed'
      and not m.eats_separately
    group by l.meal_id
  ),
  top_dishes as (
    select ml.id, ml.name, count(*) as times, coalesce(max(k.fans), 0) as fans
    from logs l
    join public.meals ml on ml.id = l.meal_id and ml.household_id = target_household
    left join liked k on k.meal_id = l.meal_id
    group by ml.id, ml.name
    order by times desc, fans desc, ml.name, ml.id
    limit 3
  )
  select jsonb_build_object(
    'logged', (select count(*) from logs),
    'stats', (select public.family_stats(target_household, b.from_date, b.to_date)::jsonb from bounds b),
    'top_dishes', coalesce((
      select jsonb_agg(jsonb_build_object('meal_id', t.id, 'name', t.name, 'times', t.times)
                       order by t.times desc, t.fans desc, t.name, t.id)
      from top_dishes t
    ), '[]'::jsonb),
    'cooks', coalesce((select jsonb_agg(member_id order by first_night, member_id) from cooks), '[]'::jsonb),
    'tried', coalesce((
      select jsonb_agg((t.entry ->> 'member_id')::uuid order by t.ord)
      from bounds b,
        json_array_elements(public.tried_new(target_household, b.from_date, b.to_date)) with ordinality as t(entry, ord)
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.year_recap(uuid, int) from public, anon;
grant execute on function public.year_recap(uuid, int) to authenticated;
