-- Meal detail (#19).
-- 1. Optional recipe steps on meals, one entry per step.
-- 2. save_meal writes the meal's fields and replaces its ingredient lines in one transaction, so an
--    edit never leaves a meal half-saved. New items take the starter pack's category for the same
--    name, else "other". The photo is set separately, after its upload.
-- 3. copy_meal makes "Copy and tweak": the recipe, prep, and ingredient lines, without the catalog
--    link (the copy is the family's own dish) or the photo (their version earns its own).
--    Retired meals aren't copied, so the dislike rule holds.

alter table public.meals
  add column steps text[] not null default '{}'
    check (cardinality(steps) <= 50 and array_position(steps, null) is null
           and char_length(array_to_string(steps, '')) <= 20000);

grant insert (steps) on public.meals to authenticated;
grant update (steps) on public.meals to authenticated;

-- The meal's household, if the caller can see the meal and plans for that household.
create function public.planner_meal_household(target_meal uuid)
returns uuid
language plpgsql stable security invoker set search_path = ''
as $$
declare
  found_household uuid;
begin
  -- Runs under the caller's row-level security: another household's meal is simply not found.
  select household_id into found_household from public.meals where id = target_meal;
  if found_household is null then
    raise exception 'no meal %', target_meal using errcode = 'P0002';
  end if;
  if not public.is_household_planner(found_household) then
    raise exception 'only planners change meals' using errcode = '42501';
  end if;
  return found_household;
end;
$$;

revoke execute on function public.planner_meal_household(uuid) from public, anon;
grant execute on function public.planner_meal_household(uuid) to authenticated;

create function public.save_meal(
  target_meal uuid,
  meal_name text,
  meal_servings smallint,
  meal_tags public.meal_tag[],
  meal_steps text[],
  meal_source_url text,
  made_by uuid,
  lines jsonb
)
returns public.meals
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid := public.planner_meal_household(target_meal);
  saved public.meals;
begin
  if jsonb_typeof(lines) is distinct from 'array' then
    raise exception 'lines must be a JSON array' using errcode = '22023';
  end if;

  update public.meals
  set name = btrim(meal_name), servings = meal_servings, tags = meal_tags, steps = meal_steps,
      source_url = nullif(btrim(meal_source_url), ''), made_by_member_id = made_by
  where id = target_meal
  returning * into saved;

  delete from public.meal_ingredients where meal_id = target_meal;

  insert into public.meal_ingredients (household_id, meal_id, item_id, quantity_text, position)
  select household, target_meal,
         (public.ensure_item(
            household, line.name,
            coalesce((select ci.category from public.catalog_ingredients ci
                      where lower(btrim(ci.name)) = lower(line.name) limit 1), 'other')
          )).id,
         line.quantity, row_number() over (order by line.ordinality)
  from (
    select btrim(element ->> 'name') as name, nullif(btrim(element ->> 'quantity'), '') as quantity, ordinality
    from jsonb_array_elements(lines) with ordinality as entries (element, ordinality)
    -- Only real names: a number or object is not an ingredient.
    where jsonb_typeof(element -> 'name') = 'string'
  ) as line
  where line.name <> '';

  return saved;
end;
$$;

revoke execute on function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb)
  from public, anon;
grant execute on function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb)
  to authenticated;

create function public.copy_meal(source_meal uuid, copy_name text)
returns public.meals
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid := public.planner_meal_household(source_meal);
  copy public.meals;
begin
  -- A copy of a retired meal would start its ratings over and undo the dislike rule.
  if (select status from public.meals where id = source_meal) = 'retired' then
    raise exception 'retired meals are not copied' using errcode = '42501';
  end if;

  insert into public.meals (household_id, name, servings, tags, prep_steps, steps, source_url, made_by_member_id)
  select household_id, btrim(copy_name), servings, tags, prep_steps, steps, source_url, made_by_member_id
  from public.meals where id = source_meal
  returning * into copy;

  insert into public.meal_ingredients (household_id, meal_id, item_id, quantity_text, position)
  select household, copy.id, item_id, quantity_text, position
  from public.meal_ingredients where meal_id = source_meal;

  return copy;
end;
$$;

revoke execute on function public.copy_meal(uuid, text) from public, anon;
grant execute on function public.copy_meal(uuid, text) to authenticated;
