-- Vacation mode and attendance templates (#52).
-- 1. Away dates are households.settings.away_dates, [{"from": "yyyy-MM-dd", "to": "yyyy-MM-dd"}], both nights included.
--    Only add_away_dates and remove_away_dates write them from the app. They change the list on the server, under a lock
--    on the household, so a device with an old copy can't undo another planner's dates; and they bring the weeks already
--    started into line. Nights the dates now cover have everyone out and lose what was planned, from tomorrow on: tonight
--    keeps a dinner it already has (it may already be eaten), and past nights and dinners logged are history. Nights the
--    dates no longer cover go back to usual schedules. The list isn't touched: a line can belong to another week, be a
--    staple, or have someone's own note merged in, so it waits for Update the list.
--    household_away_on is the one question everything else asks; notifications (M2 car 6) ask it before sending
--    anything for a night. A trigger refuses a new dinner on an away night, for a device that doesn't know yet.
-- 2. attendance_templates are named copies of everyone's usual schedule (members.attendance_defaults, whole, so a newer
--    key comes along). Parents save, switch and delete them, since a person's usual schedule is theirs or a parent's to
--    change. Saving under a name already used replaces it. Switching writes them back to the members; someone added
--    since keeps their own. Weeks already started don't change. Schedules are personal data, so a person's leaves every
--    template when they're removed from the family, which deleting an account and retention both go through.

-- Reads leniently: settings can also be written directly, and a bad value must never stop a week from starting.
create function public.away_date_stretches(dates jsonb)
returns table (first_night date, last_night date)
language sql stable set search_path = ''
as $$
  select parsed.first_night, parsed.last_night
  from (
    select case when pg_input_is_valid(stretch ->> 'from', 'date') and pg_input_is_valid(stretch ->> 'to', 'date')
                then (stretch ->> 'from')::date end as first_night,
           case when pg_input_is_valid(stretch ->> 'from', 'date') and pg_input_is_valid(stretch ->> 'to', 'date')
                then (stretch ->> 'to')::date end as last_night
    from jsonb_array_elements(case when jsonb_typeof(dates) = 'array' then dates else '[]'::jsonb end) as stretch
  ) parsed
  where isfinite(parsed.first_night) and isfinite(parsed.last_night) and parsed.first_night <= parsed.last_night
  order by parsed.first_night;
$$;

create function public.away_dates_cover(dates jsonb, day date)
returns boolean
language sql stable set search_path = ''
as $$
  select exists (select 1 from public.away_date_stretches(dates) s where day between s.first_night and s.last_night);
$$;

create function public.household_away_on(target_household uuid, day date)
returns boolean
language sql stable security invoker set search_path = ''
as $$
  select coalesce(
    (select public.away_dates_cover(settings -> 'away_dates', day) from public.households where id = target_household),
    false);
$$;

-- Home that night by their usual schedule and away status, before anyone changes the night by hand.
create function public.member_usually_home(person public.members, day date)
returns boolean
language sql stable set search_path = ''
as $$
  select not (
    coalesce(person.attendance_defaults -> 'usually_away', '[]'::jsonb) @> to_jsonb(extract(isodow from day)::int)
    or (person.status = 'away' and (person.away_until is null or day < person.away_until))
  );
$$;

revoke execute on function public.away_date_stretches(jsonb) from public, anon;
grant execute on function public.away_date_stretches(jsonb) to authenticated;
revoke execute on function public.away_dates_cover(jsonb, date) from public, anon;
grant execute on function public.away_dates_cover(jsonb, date) to authenticated;
revoke execute on function public.household_away_on(uuid, date) from public, anon;
grant execute on function public.household_away_on(uuid, date) to authenticated, service_role;
revoke execute on function public.member_usually_home(public.members, date) from public, anon;
grant execute on function public.member_usually_home(public.members, date) to authenticated;

create or replace function public.create_week(target_household uuid, start_date date)
returns public.plans
language plpgsql security invoker set search_path = ''
as $$
declare
  plan public.plans;
  dinner time;
  away jsonb;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners create weeks' using errcode = '42501';
  end if;
  if extract(isodow from start_date)::int <> public.household_week_start(target_household) then
    raise exception 'weeks start on the household''s shopping day' using errcode = '22023';
  end if;

  select case when settings ->> 'dinner_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              then (settings ->> 'dinner_time')::time else '18:00'::time end,
         settings -> 'away_dates'
  into dinner, away from public.households where id = target_household;

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
         public.member_usually_home(m, n.date) and not public.away_dates_cover(away, n.date)
  from public.plan_nights n
  cross join public.members m
  where n.plan_id = plan.id and m.household_id = target_household and m.status <> 'removed'
  on conflict (plan_night_id, member_id) do nothing;

  return plan;
end;
$$;

-- Saves the list and brings the weeks already started into line. The two functions below are its only callers: they
-- check the caller and hold the household's row. Security definer: a planner can't reopen a request directly.
create function public.write_away_dates(target_household uuid, before jsonb, dates jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  today date := public.household_today(target_household);
  newly_away uuid[];
begin
  if jsonb_array_length(dates) > 40 then
    raise exception 'too many away dates' using errcode = '22023';
  end if;
  update public.households
  set settings = settings || jsonb_build_object('away_dates', dates)
  where id = target_household;

  select coalesce(array_agg(n.id), '{}') into newly_away
  from public.plan_nights n
  where n.household_id = target_household and n.date >= today
    and public.away_dates_cover(dates, n.date) and not public.away_dates_cover(before, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id)
    -- Tonight's dinner may already be eaten; a planner who's leaving before it swaps it off.
    and not (n.date = today and (n.meal_id is not null or n.quick_pick is not null));

  update public.requests set status = 'open', planned_night_id = null where planned_night_id = any (newly_away);
  update public.plan_nights set meal_id = null, quick_pick = null, reason = null, locked = false
  where id = any (newly_away);
  update public.night_attendance set expected = false where plan_night_id = any (newly_away);

  -- A night still holding a dinner was never cleared, so whoever's home for it stands.
  update public.night_attendance a
  set expected = public.member_usually_home(m, n.date)
  from public.plan_nights n, public.members m
  where n.id = a.plan_night_id and m.id = a.member_id and m.status <> 'removed'
    and n.household_id = target_household and n.date >= today
    and n.meal_id is null and n.quick_pick is null
    and public.away_dates_cover(before, n.date) and not public.away_dates_cover(dates, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id);

  return dates;
end;
$$;

revoke execute on function public.write_away_dates(uuid, jsonb, jsonb) from public, anon, authenticated;

-- Adds a stretch to the list as it is now. Stretches that overlap or run on from each other become one, and ones
-- already over are dropped. Returns the list.
create function public.add_away_dates(target_household uuid, first_night date, last_night date)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  before jsonb;
  merged jsonb := '[]';
  today date;
  stretch record;
  run_first date;
  run_last date;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners set away dates' using errcode = '42501';
  end if;
  today := public.household_today(target_household);
  if first_night is null or last_night is null or not isfinite(first_night) or not isfinite(last_night)
     or last_night < first_night or last_night > first_night + 366 or last_night < today then
    raise exception 'away dates run forward from a first night to a last night, for a year at most, and aren''t over'
      using errcode = '22023';
  end if;

  select settings -> 'away_dates' into before from public.households where id = target_household for update;

  for stretch in
    select s.first_night as f, s.last_night as l from public.away_date_stretches(before) s where s.last_night >= today
    union all
    select first_night, last_night
    order by 1
  loop
    if run_first is not null and stretch.f <= run_last + 1 then
      run_last := greatest(run_last, stretch.l);
    else
      if run_first is not null then
        merged := merged || jsonb_build_object('from', run_first::text, 'to', run_last::text);
      end if;
      run_first := stretch.f;
      run_last := stretch.l;
    end if;
  end loop;
  merged := merged || jsonb_build_object('from', run_first::text, 'to', run_last::text);

  return public.write_away_dates(target_household, before, merged);
end;
$$;

-- Takes these nights out of the list as it is now, however it's been changed since this device last saw it: a whole
-- stretch, or part of one. Returns the list.
create function public.remove_away_dates(target_household uuid, first_night date, last_night date)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  before jsonb;
  kept jsonb := '[]';
  today date;
  stretch record;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners set away dates' using errcode = '42501';
  end if;
  if first_night is null or last_night is null or last_night < first_night then
    raise exception 'away dates run forward from a first night to a last night' using errcode = '22023';
  end if;
  today := public.household_today(target_household);

  select settings -> 'away_dates' into before from public.households where id = target_household for update;

  for stretch in
    select s.first_night as f, s.last_night as l from public.away_date_stretches(before) s where s.last_night >= today
  loop
    if stretch.l < first_night or stretch.f > last_night then
      kept := kept || jsonb_build_object('from', stretch.f::text, 'to', stretch.l::text);
    else
      if stretch.f < first_night then
        kept := kept || jsonb_build_object('from', stretch.f::text, 'to', (first_night - 1)::text);
      end if;
      if stretch.l > last_night then
        kept := kept || jsonb_build_object('from', (last_night + 1)::text, 'to', stretch.l::text);
      end if;
    end if;
  end loop;

  return public.write_away_dates(target_household, before, kept);
end;
$$;

revoke execute on function public.add_away_dates(uuid, date, date) from public, anon;
grant execute on function public.add_away_dates(uuid, date, date) to authenticated;
revoke execute on function public.remove_away_dates(uuid, date, date) from public, anon;
grant execute on function public.remove_away_dates(uuid, date, date) to authenticated;

-- A device that hasn't heard about the dates, or an older app's Swap, can't put dinner on an away night. Past nights can
-- still be corrected ("We had something else"), and so can tonight's dinner if it kept one.
create function public.plan_nights_refuse_away()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  today date;
begin
  if current_user <> 'authenticated' or (new.meal_id is null and new.quick_pick is null) then
    return new;
  end if;
  if tg_op = 'UPDATE' and (new.meal_id, new.quick_pick) is not distinct from (old.meal_id, old.quick_pick) then
    return new;
  end if;
  today := public.household_today(new.household_id);
  if new.date < today
     or (new.date = today and tg_op = 'UPDATE' and (old.meal_id is not null or old.quick_pick is not null)) then
    return new;
  end if;
  if public.household_away_on(new.household_id, new.date) then
    raise exception 'the family is away that night' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger plan_nights_refuse_away before insert or update of meal_id, quick_pick on public.plan_nights
  for each row execute function public.plan_nights_refuse_away();

-- Only add_away_dates and remove_away_dates change the list: a settings save, stale or from an older app, can't change it.
create or replace function public.update_household_settings(target_household uuid, patch jsonb)
returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  if jsonb_typeof(patch) is distinct from 'object' then
    raise exception 'settings must be an object' using errcode = '22023';
  end if;
  if not public.is_household_planner(target_household) then
    raise exception 'only planners change household settings' using errcode = '42501';
  end if;
  update public.households set settings = settings || (patch - 'away_dates') where id = target_household;
end;
$$;

create table public.attendance_templates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  name text not null check (char_length(name) between 1 and 40),
  -- Member id -> their attendance_defaults when it was saved.
  schedules jsonb not null default '{}' check (jsonb_typeof(schedules) = 'object'),
  created_at timestamptz not null default now()
);

create unique index attendance_templates_name_key on public.attendance_templates (household_id, lower(name));

revoke all on public.attendance_templates from anon, authenticated;
grant select, delete on public.attendance_templates to authenticated;

alter table public.attendance_templates enable row level security;

create policy "members read templates" on public.attendance_templates
  for select to authenticated using (public.is_household_member(household_id));
create policy "parents delete templates" on public.attendance_templates
  for delete to authenticated using (public.is_household_manager(household_id));

-- Saves everyone's usual schedule as it is right now, so a stale phone can't save an old copy.
create function public.save_attendance_template(target_household uuid, template_name text)
returns public.attendance_templates
language plpgsql security definer set search_path = ''
as $$
declare
  saved public.attendance_templates;
  cleaned text := btrim(template_name);
begin
  if not public.is_household_manager(target_household) then
    raise exception 'only parents save schedules' using errcode = '42501';
  end if;
  if char_length(cleaned) not between 1 and 40 then
    raise exception 'a schedule needs a name of up to 40 characters' using errcode = '22023';
  end if;
  insert into public.attendance_templates (household_id, name, schedules)
  select target_household, cleaned, coalesce(jsonb_object_agg(m.id::text, m.attendance_defaults), '{}')
  from public.members m
  where m.household_id = target_household and m.status <> 'removed'
  on conflict (household_id, lower(name)) do update set name = excluded.name, schedules = excluded.schedules
  returning * into saved;
  return saved;
end;
$$;

revoke execute on function public.save_attendance_template(uuid, text) from public, anon;
grant execute on function public.save_attendance_template(uuid, text) to authenticated;

-- Security definer: members_guard_write checks one change at a time; this is the same rule (parents) for everyone at once.
create function public.apply_attendance_template(target_template uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  template public.attendance_templates;
begin
  select * into template from public.attendance_templates t
  where t.id = target_template and public.is_household_member(t.household_id);
  if template.id is null then
    raise exception 'no schedule %', target_template using errcode = 'P0002';
  end if;
  if not public.is_household_manager(template.household_id) then
    raise exception 'only parents switch schedules' using errcode = '42501';
  end if;
  update public.members m
  set attendance_defaults = template.schedules -> m.id::text
  where m.household_id = template.household_id and m.status <> 'removed' and template.schedules ? m.id::text;
end;
$$;

revoke execute on function public.apply_attendance_template(uuid) from public, anon;
grant execute on function public.apply_attendance_template(uuid) to authenticated;

-- Removal is what deleting an account and retention both go through, so a person's saved schedules leave here. Security
-- definer: a parent removing someone has no write access to the table.
create function public.members_drop_saved_schedules()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.attendance_templates set schedules = schedules - new.id::text where household_id = new.household_id;
  return null;
end;
$$;

revoke execute on function public.members_drop_saved_schedules() from public, anon, authenticated;

create trigger members_drop_saved_schedules after update of status on public.members
  for each row when (new.status = 'removed' and old.status <> 'removed')
  execute function public.members_drop_saved_schedules();

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.attendance_templates where household_id = target;
  delete from public.request_plus_ones where household_id = target;
  delete from public.requests where household_id = target;
  delete from public.serving_notes where household_id = target;
  delete from public.chef_thanks where household_id = target;
  delete from public.reactions where household_id = target;
  delete from public.meal_logs where household_id = target;
  delete from public.night_attendance where household_id = target;
  delete from public.list_items where household_id = target;
  delete from public.plan_nights where household_id = target;
  delete from public.plans where household_id = target;
  delete from public.traditions where household_id = target;
  delete from public.meal_sides where household_id = target;
  delete from public.meal_ingredients where household_id = target;
  delete from public.meals where household_id = target;
  delete from public.items where household_id = target;
  delete from public.member_allergies where household_id = target;
  delete from public.invites where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;

create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners export the household' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'household', (select to_jsonb(h) - 'owner' from public.households h where id = target_household),
    'members', (select coalesce(jsonb_agg(to_jsonb(m) - 'user_id' - 'household_id' order by m.created_at), '[]')
                from public.members m where household_id = target_household),
    'allergies', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                  from public.member_allergies a where household_id = target_household),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' - 'granted_by' order by c.granted_at), '[]')
                 from public.consents c where household_id = target_household),
    'meals', (select coalesce(jsonb_agg(to_jsonb(m) - 'household_id' order by m.name), '[]')
              from public.meals m where household_id = target_household),
    'meal_ingredients', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id'), '[]')
                         from public.meal_ingredients i where household_id = target_household),
    'meal_sides', (select coalesce(jsonb_agg(to_jsonb(s) - 'household_id'), '[]')
                   from public.meal_sides s where household_id = target_household),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id' order by i.canonical_name), '[]')
              from public.items i where household_id = target_household),
    'traditions', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id'), '[]')
                   from public.traditions t where household_id = target_household),
    'plans', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.week_start), '[]')
              from public.plans p where household_id = target_household),
    'nights', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.date), '[]')
               from public.plan_nights n where household_id = target_household),
    'attendance', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                   from public.night_attendance a where household_id = target_household),
    'list_items', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id'), '[]')
                   from public.list_items l where household_id = target_household),
    'meal_logs', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                  from public.meal_logs l where household_id = target_household),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                  from public.reactions r where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household),
    'attendance_templates', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                             from public.attendance_templates t where household_id = target_household)
  );
end;
$$;
