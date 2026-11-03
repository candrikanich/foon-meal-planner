-- The weekly recap (#63, and #56's recap half): what This Week's card says about the week that just ended,
-- beyond the family_stats counts it also shows (docs/spec.md → Weekly recap). Read-only and security invoker, so
-- row-level security decides what's read: another household's caller gets nothing.
--
-- Only logs on nights of approved plans dated [from_date, to_date] count.
--   * logged: how many dinners were logged. None means no recap.
--   * cooks: who cooked a dish, in the order they first did that week, for a thank-you. Never counted or ranked;
--     quick picks aren't cooking, as for cook credit, and someone since removed isn't thanked.
--   * top_dish: the logged dish with the most favorite and good reactions that week; a tie goes to the dish's latest
--     night that week, then the meal id. None without a reaction. Removed members and people who eat separately don't
--     count, as for verdicts.
--   * forgotten_favorite: a dish someone's current verdict is favorite on, last made 42 or more days before to_date,
--     in rotation (not archived, or retired by the dislike rule). That also means not snoozed: tired of it is a
--     reaction to a dinner, and a snooze lasts 21 days from it. Most fans first, then the longest since, then the id.

create function public.week_recap(target_household uuid, from_date date, to_date date)
returns json
language sql stable security invoker set search_path = ''
as $$
  with logs as (
    select l.id, l.meal_id, l.cooked_by_member_id, n.date
    from public.meal_logs l
    join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    where l.household_id = target_household
      and p.approved_at is not null
      and n.date between from_date and to_date
  ),
  cooks as (
    select l.cooked_by_member_id as member_id, min(l.date) as first_night
    from logs l
    join public.members m on m.id = l.cooked_by_member_id and m.household_id = target_household
    where l.meal_id is not null and m.status <> 'removed'
    group by l.cooked_by_member_id
  ),
  top_dish as (
    select l.meal_id
    from logs l
    join public.reactions r on r.meal_log_id = l.id
    join public.members m on m.id = r.member_id and m.household_id = target_household
    where l.meal_id is not null
      and r.reaction in ('favorite', 'good')
      and m.status <> 'removed'
      and not m.eats_separately
    group by l.meal_id
    -- The dish's latest night that week, whether or not that night's dinner was the one rated.
    order by count(*) desc, (select max(e.date) from logs e where e.meal_id = l.meal_id) desc, l.meal_id
    limit 1
  ),
  forgotten as (
    select v.meal_id
    from public.meal_verdicts v
    join public.meals ml on ml.id = v.meal_id and ml.household_id = v.household_id
    join public.meal_history h on h.meal_id = v.meal_id and h.household_id = v.household_id
    where v.household_id = target_household
      and v.reaction = 'favorite'
      and ml.status in ('active', 'trial')
      and h.last_made <= to_date - 42
    group by v.meal_id, h.last_made
    order by count(*) desc, h.last_made, v.meal_id
    limit 1
  )
  select json_build_object(
    'logged', (select count(*) from logs),
    'cooks', coalesce((select json_agg(member_id order by first_night, member_id) from cooks), '[]'::json),
    'top_dish', (
      select json_build_object('meal_id', m.id, 'name', m.name)
      from top_dish t join public.meals m on m.id = t.meal_id
    ),
    'forgotten_favorite', (
      select json_build_object('meal_id', m.id, 'name', m.name)
      from forgotten f join public.meals m on m.id = f.meal_id
    )
  );
$$;

revoke execute on function public.week_recap(uuid, date, date) from public, anon;
grant execute on function public.week_recap(uuid, date, date) to authenticated;
