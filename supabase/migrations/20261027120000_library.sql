-- Library screen (#18).
-- 1. add_catalog_meal copies a starter dish into the household's library in one transaction:
--    the meal, its items (reusing ones the household already has), and its ingredient lines.
--    Onboarding (#17) adds tapped dishes the same way. Adding a dish already in the library
--    returns that copy (whatever its status), so a double tap never makes two and a dish the
--    dislike rule retired can't come back with its ratings wiped.
-- 2. meal_history gives each meal's times made and last made for the library's sorts and the
--    meal detail. Until dinners are confirmed (meal_logs, M2), a meal counts as made on each past
--    night of an approved plan. M2 redefines the view over meal_logs; readers don't change.

create function public.add_catalog_meal(target_household uuid, catalog_meal uuid)
returns public.meals
language plpgsql security invoker set search_path = ''
as $$
declare
  dish public.catalog_meals;
  copy public.meals;
begin
  -- Row-level security would refuse the inserts below anyway; checking first keeps a member's
  -- call from succeeding just because the dish is already in the library.
  if not public.is_household_planner(target_household) then
    raise exception 'only planners add dishes to the library' using errcode = '42501';
  end if;

  -- Two planners adding the same dish at once take turns, so the second finds the first's copy.
  perform pg_advisory_xact_lock(hashtextextended(target_household::text || catalog_meal::text, 0));

  select * into copy from public.meals
  where household_id = target_household and catalog_meal_id = catalog_meal
  order by created_at
  limit 1;
  if found then
    return copy;
  end if;

  select * into dish from public.catalog_meals where id = catalog_meal;
  if not found then
    raise exception 'no catalog dish %', catalog_meal using errcode = 'P0002';
  end if;

  insert into public.meals (household_id, catalog_meal_id, name, servings, tags, prep_steps)
  values (target_household, dish.id, dish.name, dish.servings, dish.tags, dish.prep_steps)
  returning * into copy;

  insert into public.meal_ingredients (household_id, meal_id, item_id, quantity_text, position)
  select target_household, copy.id, (public.ensure_item(target_household, ci.name, ci.category)).id,
         ci.quantity_text, ci.position
  from public.catalog_ingredients ci
  where ci.catalog_meal_id = dish.id
  order by ci.position;

  return copy;
end;
$$;

revoke execute on function public.add_catalog_meal(uuid, uuid) from public, anon;
grant execute on function public.add_catalog_meal(uuid, uuid) to authenticated;

create view public.meal_history
with (security_invoker = true)
as
  select n.household_id, n.meal_id, count(*)::int as times_made, max(n.date) as last_made
  from public.plan_nights n
  join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
  where n.meal_id is not null and p.approved_at is not null and n.date < current_date
  group by n.household_id, n.meal_id;

revoke all on public.meal_history from anon, authenticated;
grant select on public.meal_history to authenticated;
