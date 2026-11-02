-- Real cook times for starter dishes (#146), so the start-cooking nudge covers them. Only dishes with no fair guess get one:
-- quick and slow cooker dishes keep their estimates. The seed runs after migrations, so a fresh database gets the times from
-- there (supabase/seed/catalog.sql, the same list) and a hosted one from here, before the backfill needs them.
alter table public.catalog_meals
  add column cook_minutes smallint check (cook_minutes between 1 and 1440);

update public.catalog_meals dish
set cook_minutes = times.minutes::smallint
from (values
  ('pasta-with-sauce-and-meatballs', 45),
  ('homemade-mac-and-cheese', 40),
  ('baked-ziti', 60),
  ('lasagna', 90),
  ('enchiladas', 50),
  ('burgers', 30),
  ('grilled-chicken', 40),
  ('kebabs', 45),
  ('steak-night', 35),
  ('potato-soup', 45),
  ('sheet-pan-chicken-and-veggies', 45),
  ('baked-chicken-thighs-and-potatoes', 60),
  ('chicken-parmesan', 50),
  ('pork-chops-and-applesauce', 30),
  ('pork-tenderloin', 45),
  ('ham-and-scalloped-potatoes', 90),
  ('meatloaf-and-mashed-potatoes', 75),
  ('shepherds-pie', 75),
  ('crab-cakes', 30),
  ('fish-and-chips-night', 45),
  ('homemade-pizza-night', 60)
) as times (slug, minutes)
where dish.slug = times.slug;

-- A function so a test can reach it. A time someone set, on a copy they've since changed, is left alone.
create function public.backfill_catalog_cook_minutes()
returns void
language sql set search_path = ''
as $$
  update public.meals meal
  set cook_minutes = dish.cook_minutes
  from public.catalog_meals dish
  where meal.catalog_meal_id = dish.id
    and meal.cook_minutes is null
    and dish.cook_minutes is not null;
$$;

revoke execute on function public.backfill_catalog_cook_minutes() from public, anon, authenticated;

select public.backfill_catalog_cook_minutes();

create or replace function public.add_catalog_meal(target_household uuid, catalog_meal uuid)
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

  insert into public.meals (household_id, catalog_meal_id, name, servings, tags, prep_steps, cook_minutes)
  values (target_household, dish.id, dish.name, dish.servings, dish.tags, dish.prep_steps, dish.cook_minutes)
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
