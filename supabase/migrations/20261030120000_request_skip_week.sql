-- Me-too priority (#38, part 3) respects the planner. "Not this week", or swapping a priority dish off its night,
-- records the week it sits out (skipped_week, that week's start); Build my week leaves it out of that week's priority
-- and it comes back the week after ("carries forward"). update_request gains skip_week (planners only).

alter table public.requests add column skipped_week date;

drop function public.update_request(uuid, public.request_status, uuid, boolean, uuid, text, date);

create function public.update_request(
  target_request uuid, new_status public.request_status, night uuid, clear_date boolean, link_meal uuid,
  new_note text, new_date date, skip_week date default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  request public.requests;
  planner boolean;
  mine boolean;
begin
  select * into request from public.requests where id = target_request;
  if request.id is null or not public.is_household_member(request.household_id) then
    raise exception 'no request %', target_request using errcode = 'P0002';
  end if;
  planner := public.is_household_planner(request.household_id);
  -- Your own request, or one entered on your phone (passing it for someone without one). Passing the phone means
  -- asking as them at that moment, not owning everything they've ever asked for.
  mine := public.may_react_for(request.requested_by_member_id)
          and public.my_member_id(request.household_id) in (request.requested_by_member_id, request.entered_by_member_id);
  if not planner and not (mine and coalesce(new_status, 'archived') = 'archived' and night is null and link_meal is null) then
    raise exception 'planners decide what happens to a request; you can change or archive your own'
      using errcode = '42501';
  end if;
  if not planner and skip_week is not null then
    raise exception 'planners decide what waits for another week' using errcode = '42501';
  end if;
  if not planner and request.status = 'planned' and (clear_date or new_date is not null) then
    raise exception 'it''s already planned; ask a planner to move it' using errcode = '42501';
  end if;
  if coalesce(new_status, request.status) = 'planned' and coalesce(night, request.planned_night_id) is null then
    raise exception 'pick a night to plan it on' using errcode = '22023';
  end if;
  if night is not null and coalesce(new_status, request.status) <> 'planned' then
    raise exception 'a night is only for planning it' using errcode = '22023';
  end if;
  if night is not null and not exists (select 1 from public.plan_nights
                                       where id = night and household_id = request.household_id) then
    raise exception 'no night %', night using errcode = 'P0002';
  end if;
  if link_meal is not null and not exists (select 1 from public.meals
                                           where id = link_meal and household_id = request.household_id) then
    raise exception 'no meal %', link_meal using errcode = 'P0002';
  end if;
  if new_date is not null and new_date < public.household_today(request.household_id) then
    raise exception 'that night has passed' using errcode = '22023';
  end if;
  update public.requests
  set status = coalesce(new_status, status),
      planned_night_id = case
        when coalesce(new_status, status) = 'planned' then coalesce(night, planned_night_id)
        else null end,
      target_date = case when clear_date then null else coalesce(new_date, target_date) end,
      meal_id = coalesce(link_meal, meal_id),
      note = case when new_note is null then note else nullif(btrim(new_note), '') end,
      skipped_week = coalesce(skip_week, skipped_week)
  where id = target_request;
end;
$$;

revoke execute on function public.update_request(uuid, public.request_status, uuid, boolean, uuid, text, date, date)
  from public, anon;
grant execute on function public.update_request(uuid, public.request_status, uuid, boolean, uuid, text, date, date)
  to authenticated;
