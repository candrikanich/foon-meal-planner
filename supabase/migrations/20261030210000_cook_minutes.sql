-- Start-cooking nudge (#55). A dish can say how long it takes, in minutes before dinner; nothing else stored here does
-- (prep_steps.lead_hours is for things started ahead). The app estimates from tags without one. The list of equipment a
-- household doesn't have is households.settings.missing_equipment, which needs no schema.
alter table public.meals
  add column cook_minutes smallint check (cook_minutes between 1 and 1440);

grant insert (cook_minutes) on public.meals to authenticated;
grant update (cook_minutes) on public.meals to authenticated;

-- save_meal gains the time. Null (the default) leaves it as it is, so callers that don't know about it (create_meal,
-- older builds) never wipe it; 0 clears it.
drop function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb, jsonb);

create function public.save_meal(
  target_meal uuid,
  meal_name text,
  meal_servings smallint,
  meal_tags public.meal_tag[],
  meal_steps text[],
  meal_source_url text,
  made_by uuid,
  lines jsonb,
  sides jsonb default null,
  meal_cook_minutes smallint default null
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
  if sides is not null and jsonb_typeof(sides) <> 'array' then
    raise exception 'sides must be a JSON array' using errcode = '22023';
  end if;

  update public.meals
  set name = btrim(meal_name), servings = meal_servings, tags = meal_tags, steps = meal_steps,
      source_url = nullif(btrim(meal_source_url), ''), made_by_member_id = made_by,
      cook_minutes = case when meal_cook_minutes is null then cook_minutes else nullif(meal_cook_minutes, 0) end
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

  if sides is not null then
    -- A retired dish was voted out by the family; it doesn't come back as a side.
    if exists (
      select 1 from jsonb_array_elements(sides) as entries (element)
      join public.meals m on m.id = (element ->> 'meal_id')::uuid
      where jsonb_typeof(element) = 'object' and m.status = 'retired'
    ) then
      raise exception 'retired meals are not sides' using errcode = '42501';
    end if;

    delete from public.meal_sides where meal_id = target_meal;

    -- Each side is {"meal_id": …} or {"name": …}; a repeat keeps its first place.
    insert into public.meal_sides (household_id, meal_id, side_meal_id, item_id, position)
    select household, target_meal, side.side_meal_id, side.item_id, row_number() over (order by side.first_seen)
    from (
      select resolved.side_meal_id, resolved.item_id, min(resolved.ordinality) as first_seen
      from (
        select (element ->> 'meal_id')::uuid as side_meal_id,
               case when jsonb_typeof(element -> 'name') = 'string' and btrim(element ->> 'name') <> ''
                    then (public.ensure_item(
                            household, btrim(element ->> 'name'),
                            coalesce((select ci.category from public.catalog_ingredients ci
                                      where lower(btrim(ci.name)) = lower(btrim(element ->> 'name')) limit 1),
                                     'other'))).id
               end as item_id,
               ordinality
        from jsonb_array_elements(sides) with ordinality as entries (element, ordinality)
        where jsonb_typeof(element) = 'object'
      ) as resolved
      where resolved.side_meal_id is not null or resolved.item_id is not null
      group by resolved.side_meal_id, resolved.item_id
    ) as side;
  end if;

  return saved;
end;
$$;

revoke execute on function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb, jsonb, smallint)
  from public, anon;
grant execute on function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb, jsonb, smallint)
  to authenticated;

create or replace function public.copy_meal(source_meal uuid, copy_name text)
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

  insert into public.meals (household_id, name, servings, tags, prep_steps, steps, source_url, made_by_member_id,
                            cook_minutes)
  select household_id, btrim(copy_name), servings, tags, prep_steps, steps, source_url, made_by_member_id, cook_minutes
  from public.meals where id = source_meal
  returning * into copy;

  insert into public.meal_ingredients (household_id, meal_id, item_id, quantity_text, position)
  select household, copy.id, item_id, quantity_text, position
  from public.meal_ingredients where meal_id = source_meal;

  insert into public.meal_sides (household_id, meal_id, side_meal_id, item_id, position)
  select household, copy.id, side_meal_id, item_id, position
  from public.meal_sides where meal_id = source_meal;

  return copy;
end;
$$;
