-- Week generation (#22).
-- create_week builds a plan's seven nights from its start day (the household's shopping day) and
-- pre-fills attendance, in one transaction, so every device gets the same week:
--   - every member not removed gets a row each night;
--   - members.attendance_defaults {"usually_away": [ISO weekdays, 1 = Monday]} marks their usual
--     nights out ("Owen works Mon to Thu");
--   - away members are out until their return date, or all week without one.
-- Nights start at normal effort with the household's dinner time (settings.dinner_time, else 18:00;
-- a value that isn't HH:MM falls back too, matching the app). Calling it for a week that exists
-- returns that week and adds nights for anyone who joined since, so it's safe to call again,
-- including from two devices at once.

-- settings.week_start as an ISO weekday, defaulting to Sunday like the app.
create function public.household_week_start(target_household uuid)
returns int
language sql stable security invoker set search_path = ''
as $$
  select case when settings ->> 'week_start' ~ '^[1-7]$' then (settings ->> 'week_start')::int else 7 end
  from public.households where id = target_household;
$$;

create function public.create_week(target_household uuid, start_date date)
returns public.plans
language plpgsql security invoker set search_path = ''
as $$
declare
  plan public.plans;
  dinner time;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners create weeks' using errcode = '42501';
  end if;
  if extract(isodow from start_date)::int <> public.household_week_start(target_household) then
    raise exception 'weeks start on the household''s shopping day' using errcode = '22023';
  end if;

  select case when settings ->> 'dinner_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              then (settings ->> 'dinner_time')::time else '18:00'::time end
  into dinner from public.households where id = target_household;

  insert into public.plans (household_id, week_start)
  values (target_household, start_date)
  on conflict (household_id, week_start) do nothing
  returning * into plan;

  if plan.id is null then
    select * into plan from public.plans where household_id = target_household and week_start = start_date;
  else
    insert into public.plan_nights (household_id, plan_id, date, dinner_time)
    select target_household, plan.id, start_date + offset_days, dinner
    from generate_series(0, 6) as offset_days;
  end if;

  insert into public.night_attendance (household_id, plan_night_id, member_id, expected)
  select target_household, n.id, m.id,
         not (
           coalesce(m.attendance_defaults -> 'usually_away', '[]'::jsonb) @> to_jsonb(extract(isodow from n.date)::int)
           or (m.status = 'away' and (m.away_until is null or n.date < m.away_until))
         )
  from public.plan_nights n
  cross join public.members m
  where n.plan_id = plan.id and m.household_id = target_household and m.status <> 'removed'
  on conflict (plan_night_id, member_id) do nothing;

  return plan;
end;
$$;

revoke execute on function public.household_week_start(uuid) from public, anon;
grant execute on function public.household_week_start(uuid) to authenticated;
revoke execute on function public.create_week(uuid, date) from public, anon;
grant execute on function public.create_week(uuid, date) to authenticated;
