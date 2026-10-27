-- Quick add (#20): a meal from a name and optional ingredient lines, in one transaction.
-- It inserts the meal, then hands the fields and lines to save_meal, so new and edited meals
-- follow the same rules (trimming, item reuse, the starter-pack category guess).

create function public.create_meal(
  target_household uuid,
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
  created public.meals;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners add meals' using errcode = '42501';
  end if;

  insert into public.meals (household_id, name, servings)
  values (target_household, btrim(meal_name), meal_servings)
  returning * into created;

  return public.save_meal(created.id, meal_name, meal_servings, meal_tags, meal_steps, meal_source_url, made_by,
                          lines);
end;
$$;

revoke execute on function public.create_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb)
  from public, anon;
grant execute on function public.create_meal(uuid, text, smallint, public.meal_tag[], text[], text, uuid, jsonb)
  to authenticated;
