-- Deleting a dish that's never been used (#168), the one exception to "never hard-delete": a mistaken import has no history
-- worth keeping. Anything the family has put on a dish keeps it: a plan night or plan change, a log (and through it a rating),
-- a tradition, a place as another dish's side, a serving note, a freezer item. Those dishes can only be archived.
-- Its own ingredient lines and side list go with it. An idea linked to it stays, with its name and link.
-- The photo can't be removed from SQL, so the function hands its path back and the app removes it.
-- Errors the app words itself: FD015 this dish is in use.

create function public.meal_is_unused(target uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select not exists (select 1 from public.plan_nights where meal_id = target)
     and not exists (select 1 from public.plan_changes where before_meal_id = target or after_meal_id = target)
     and not exists (select 1 from public.meal_logs where meal_id = target)
     and not exists (select 1 from public.traditions where meal_id = target)
     and not exists (select 1 from public.meal_sides where side_meal_id = target)
     and not exists (select 1 from public.serving_notes where meal_id = target)
     and not exists (select 1 from public.freezer_stash where meal_id = target);
$$;

revoke execute on function public.meal_is_unused(uuid) from public, anon, authenticated;

-- Which dishes to offer Delete on. Only a hint: delete_unused_meal checks again.
create function public.unused_meals(target_household uuid)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.meals
  where household_id = target_household
    and public.is_household_planner(target_household)
    and public.meal_is_unused(id);
$$;

revoke execute on function public.unused_meals(uuid) from public, anon;
grant execute on function public.unused_meals(uuid) to authenticated;

create function public.delete_unused_meal(target_meal uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  meal public.meals;
begin
  -- The lock makes anything pointing a new row at this dish wait, so nothing can land between the check and the delete.
  select * into meal from public.meals where id = target_meal for update;
  if meal.id is null or not public.is_household_member(meal.household_id) then
    raise exception 'no meal %', target_meal using errcode = 'P0002';
  end if;
  if not public.is_household_planner(meal.household_id) then
    raise exception 'only planners delete dishes' using errcode = '42501';
  end if;
  if not public.meal_is_unused(target_meal) then
    raise exception 'this dish is in use' using errcode = 'FD015';
  end if;
  update public.requests
  set meal_id = null,
      title = coalesce(title, left(btrim(meal.name), 80)),
      status = case when status = 'planned' then 'open'::public.request_status else status end,
      planned_night_id = null
  where meal_id = target_meal;
  delete from public.meal_sides where meal_id = target_meal;
  delete from public.meal_ingredients where meal_id = target_meal;
  delete from public.meals where id = target_meal;
  return meal.photo_path;
end;
$$;

revoke execute on function public.delete_unused_meal(uuid) from public, anon;
grant execute on function public.delete_unused_meal(uuid) to authenticated;
