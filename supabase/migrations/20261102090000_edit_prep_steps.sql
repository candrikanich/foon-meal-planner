-- Prep steps a planner can edit (#45). They've been readable since the catalog, and only ever set by copying a starter dish.
--
-- save_meal gains them. Null (the default) leaves them as they are, so older builds' saves don't wipe them; an empty array
-- clears them. The limits keep what reaches the reminder planner sensible: 10 steps, 120 characters, up to two weeks ahead.
-- A step with no lead time is allowed, since it shows on the dish and just has nothing to count back from.
--
-- The same check goes on the table, since planners can also write the column directly. `not valid`, so a row from before this
-- can't stop the migration: only what's written from now on has to pass. Every starter dish does.

create function public.prep_steps_are_valid(steps jsonb)
returns boolean
language sql immutable set search_path = ''
as $$
  select jsonb_typeof(steps) = 'array'
    and jsonb_array_length(steps) <= 10
    and not exists (
      select 1 from jsonb_array_elements(steps) as entries (element)
      where jsonb_typeof(element) is distinct from 'object'
         or jsonb_typeof(element -> 'step') is distinct from 'string'
         or element - 'step' - 'lead_hours' <> '{}'
         or (element ->> 'step') !~ '\S'
         or char_length(element ->> 'step') > 120
         or (jsonb_typeof(element -> 'lead_hours') is distinct from 'null'
             and element ? 'lead_hours'
             and (jsonb_typeof(element -> 'lead_hours') <> 'number'
                  or (element ->> 'lead_hours') !~ '^[0-9]+$'
                  or (element ->> 'lead_hours')::numeric not between 1 and 336))
    );
$$;

revoke execute on function public.prep_steps_are_valid(jsonb) from public, anon;
grant execute on function public.prep_steps_are_valid(jsonb) to authenticated;

alter table public.meals add constraint meals_prep_steps_valid check (public.prep_steps_are_valid(prep_steps)) not valid;

drop function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb, jsonb, smallint);

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
  meal_cook_minutes smallint default null,
  meal_prep_steps jsonb default null
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
  if meal_prep_steps is not null and not public.prep_steps_are_valid(meal_prep_steps) then
    raise exception 'prep steps need words and a lead time of 1 to 336 hours, at most 10 of them' using errcode = '22023';
  end if;

  update public.meals
  set name = btrim(meal_name), servings = meal_servings, tags = meal_tags, steps = meal_steps,
      source_url = nullif(btrim(meal_source_url), ''), made_by_member_id = made_by,
      cook_minutes = case when meal_cook_minutes is null then cook_minutes else nullif(meal_cook_minutes, 0) end,
      prep_steps = coalesce(meal_prep_steps, prep_steps)
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

revoke execute on function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb, jsonb, smallint, jsonb)
  from public, anon;
grant execute on function public.save_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb, jsonb, smallint, jsonb)
  to authenticated;
