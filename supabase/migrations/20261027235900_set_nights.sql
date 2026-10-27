-- This Week (#23).
-- 1. plan_nights.reason: the chip Build my week gives a pick ("Haven't had it in 3 weeks"), kept with the
--    night so the whole family sees why it's there. Written in the planner's language.
-- 2. set_nights writes a draft's picks for several nights in one transaction, so a built week never lands
--    half-saved. Each entry is {"id", "meal_id"?, "quick_pick"?, "reason"?}; a missing pick clears the night.
--    A locked night is refused, and the whole write with it: another planner may have locked it since this
--    device last loaded the week. (Planners still change a locked night directly, e.g. with Swap.)

alter table public.plan_nights
  add column reason text check (char_length(reason) <= 80);

grant update (reason) on public.plan_nights to authenticated;

create function public.set_nights(target_plan uuid, nights jsonb)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
  night jsonb;
begin
  -- Under the caller's row-level security another household's plan is simply not found.
  select household_id into household from public.plans where id = target_plan;
  if household is null then
    raise exception 'no plan %', target_plan using errcode = 'P0002';
  end if;
  if not public.is_household_planner(household) then
    raise exception 'only planners plan nights' using errcode = '42501';
  end if;
  if jsonb_typeof(nights) is distinct from 'array' then
    raise exception 'nights must be a JSON array' using errcode = '22023';
  end if;

  for night in select * from jsonb_array_elements(nights) loop
    update public.plan_nights
    set meal_id = (night ->> 'meal_id')::uuid,
        quick_pick = (night ->> 'quick_pick')::public.quick_pick,
        reason = nullif(btrim(night ->> 'reason'), '')
    where id = (night ->> 'id')::uuid and plan_id = target_plan and not locked;
    if not found then
      raise exception 'night % is locked or not in plan %', night ->> 'id', target_plan using errcode = 'P0002';
    end if;
  end loop;
end;
$$;

revoke execute on function public.set_nights(uuid, jsonb) from public, anon;
grant execute on function public.set_nights(uuid, jsonb) to authenticated;
