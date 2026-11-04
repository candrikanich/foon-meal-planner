-- Picky-eater wins (#65, part 1): who tried a new dish (docs/spec.md → Success metrics: shown to families). It
-- celebrates trying, not liking, so every reaction counts, not for me included. Read-only and security invoker, so
-- row-level security decides what's read: another household's caller gets nothing.
--
-- Someone tried a dish when they reacted to a logged dinner of it and hadn't reacted to that dish on any earlier log.
-- The try is on that log's night, which is a household day, and counts when the night is in [from_date, to_date] on
-- an approved plan. Only dishes count, since quick picks aren't rated. A reaction is one row per person per log, so one
-- changed within its 24 hours is still one try. Removed members and people who eat separately never appear, as for
-- verdicts.
--
-- tried_new: one entry per person, {member_id, dishes}, in the order they first tried something in the range. The
-- recap names them without counts; a member's own profile shows their count.

create function public.tried_new(target_household uuid, from_date date, to_date date)
returns json
language sql stable security invoker set search_path = ''
as $$
  with reacted as (
    select r.member_id, l.meal_id, n.date, p.approved_at is not null as approved
    from public.reactions r
    join public.meal_logs l on l.id = r.meal_log_id and l.household_id = r.household_id
    join public.plan_nights n on n.id = l.night_id and n.household_id = l.household_id
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    join public.members m on m.id = r.member_id and m.household_id = r.household_id
    where r.household_id = target_household
      and l.meal_id is not null
      and m.status <> 'removed'
      and not m.eats_separately
  ),
  firsts as (
    select member_id, meal_id, min(date) as first_night
    from reacted
    group by member_id, meal_id
  ),
  tries as (
    select f.member_id, f.first_night
    from firsts f
    where f.first_night between from_date and to_date
      and exists (
        select 1 from reacted e
        where e.member_id = f.member_id and e.meal_id = f.meal_id and e.date = f.first_night and e.approved
      )
  )
  select coalesce(
    json_agg(json_build_object('member_id', t.member_id, 'dishes', t.dishes) order by t.first_night, t.member_id),
    '[]'::json
  )
  from (
    select member_id, count(*) as dishes, min(first_night) as first_night
    from tries
    group by member_id
  ) t;
$$;

revoke execute on function public.tried_new(uuid, date, date) from public, anon;
grant execute on function public.tried_new(uuid, date, date) to authenticated;

-- The weekly recap gains `tried`: who tried something new that week, in the order they first did, for "Tried
-- something new". Everything else is as 20261103100000_week_recap.sql made it.
create or replace function public.week_recap(target_household uuid, from_date date, to_date date)
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
    -- A dish retired by the dislike rule (or archived) since isn't celebrated, however well others liked it.
    join public.meals ml on ml.id = l.meal_id and ml.household_id = target_household
    where l.meal_id is not null
      and ml.status in ('active', 'trial')
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
    'tried', coalesce((
      select json_agg(t.entry -> 'member_id' order by t.ord)
      from json_array_elements(public.tried_new(target_household, from_date, to_date)) with ordinality
        as t(entry, ord)
    ), '[]'::json),
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
