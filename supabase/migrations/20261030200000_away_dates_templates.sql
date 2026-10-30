-- Vacation mode and attendance templates (#52).
-- 1. Away dates are households.settings.away_dates, [{"from": "yyyy-MM-dd", "to": "yyyy-MM-dd"}], both nights included.
--    Only set_away_dates writes them from the app, because the weeks already started have to follow: nights from today
--    on that the dates now cover have everyone out, and lose what was planned, so an app of any age sees "nobody's
--    home" and plans and lists nothing there. Nights the dates no longer cover go back to usual schedules. Past nights
--    and dinners already logged are history. household_away_on is the one question everything else asks; notifications
--    (M2 car 6) ask it before sending anything for a night.
-- 2. attendance_templates are named copies of everyone's usual schedule (members.attendance_defaults, whole, so a newer
--    key comes along). Saving under a name already used replaces it. Switching writes them back to the members;
--    someone added since keeps their own. Weeks already started don't change. Schedules are personal data, so they
--    leave with a deleted account, and with a removed kid at the end of retention.

-- Reads leniently: settings can also be written directly, and a bad value must never stop a week from starting.
create function public.away_dates_cover(dates jsonb, day date)
returns boolean
language sql stable set search_path = ''
as $$
  select exists (
    select 1
    from jsonb_array_elements(case when jsonb_typeof(dates) = 'array' then dates else '[]'::jsonb end) as stretch
    where case when pg_input_is_valid(stretch ->> 'from', 'date') and pg_input_is_valid(stretch ->> 'to', 'date')
               then day between (stretch ->> 'from')::date and (stretch ->> 'to')::date
               else false end
  );
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

-- Replaces the household's away dates and brings the weeks already started into line. Security definer: a planner
-- can't reopen a request directly, and everything here is limited to the household they plan for.
create function public.set_away_dates(target_household uuid, dates jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  cleaned jsonb := '[]';
  before jsonb;
  today date;
  stretch jsonb;
  newly_away uuid[];
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners set away dates' using errcode = '42501';
  end if;
  if jsonb_typeof(dates) is distinct from 'array' then
    raise exception 'dates must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(dates) > 40 then
    raise exception 'too many away dates' using errcode = '22023';
  end if;
  for stretch in select * from jsonb_array_elements(dates) loop
    if not coalesce(pg_input_is_valid(stretch ->> 'from', 'date') and pg_input_is_valid(stretch ->> 'to', 'date'), false)
    then
      raise exception 'away dates need a first and last night' using errcode = '22023';
    end if;
    if (stretch ->> 'to')::date < (stretch ->> 'from')::date
       or (stretch ->> 'to')::date > (stretch ->> 'from')::date + 366 then
      raise exception 'away dates run forward, for a year at most' using errcode = '22023';
    end if;
    cleaned := cleaned || jsonb_build_object('from', ((stretch ->> 'from')::date)::text,
                                             'to', ((stretch ->> 'to')::date)::text);
  end loop;

  select settings -> 'away_dates' into before from public.households where id = target_household;
  update public.households
  set settings = settings || jsonb_build_object('away_dates', cleaned)
  where id = target_household;
  today := public.household_today(target_household);

  select coalesce(array_agg(n.id), '{}') into newly_away
  from public.plan_nights n
  where n.household_id = target_household and n.date >= today
    and public.away_dates_cover(cleaned, n.date) and not public.away_dates_cover(before, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id);

  update public.requests set status = 'open', planned_night_id = null where planned_night_id = any (newly_away);
  update public.plan_nights set meal_id = null, quick_pick = null, reason = null, locked = false
  where id = any (newly_away);
  update public.night_attendance set expected = false where plan_night_id = any (newly_away);

  -- A week with no dinner left to cook has nothing to shop for. One that still has some keeps its lines until a planner
  -- taps Update the list, as after any change to an approved week.
  delete from public.list_items l
  where l.checked_at is null
    and l.plan_id in (select n.plan_id from public.plan_nights n where n.id = any (newly_away))
    and not exists (select 1 from public.plan_nights n
                    where n.plan_id = l.plan_id and n.date >= today and n.meal_id is not null);

  update public.night_attendance a
  set expected = public.member_usually_home(m, n.date)
  from public.plan_nights n, public.members m
  where n.id = a.plan_night_id and m.id = a.member_id
    and n.household_id = target_household and n.date >= today
    and public.away_dates_cover(before, n.date) and not public.away_dates_cover(cleaned, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id);
end;
$$;

revoke execute on function public.set_away_dates(uuid, jsonb) from public, anon;
grant execute on function public.set_away_dates(uuid, jsonb) to authenticated;

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
create policy "planners delete templates" on public.attendance_templates
  for delete to authenticated using (public.is_household_planner(household_id));

-- Saves everyone's usual schedule as it is right now, so a stale phone can't save an old copy.
create function public.save_attendance_template(target_household uuid, template_name text)
returns public.attendance_templates
language plpgsql security definer set search_path = ''
as $$
declare
  saved public.attendance_templates;
  cleaned text := btrim(template_name);
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners save schedules' using errcode = '42501';
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

-- Security definer: planners own attendance, but members_guard_write leaves other people's usual schedules to parents.
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
  if not public.is_household_planner(template.household_id) then
    raise exception 'only planners switch schedules' using errcode = '42501';
  end if;
  update public.members m
  set attendance_defaults = template.schedules -> m.id::text
  where m.household_id = template.household_id and m.status <> 'removed' and template.schedules ? m.id::text;
end;
$$;

revoke execute on function public.apply_attendance_template(uuid) from public, anon;
grant execute on function public.apply_attendance_template(uuid) to authenticated;

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

create or replace function public.delete_account_data(target_user uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  owned uuid;
  profile public.members;
begin
  -- Rate-limit bookkeeping keyed by the account; nothing to keep once it's gone.
  delete from public.invite_redeem_attempts where user_id = target_user;

  select id into owned from public.households where owner = target_user;
  if owned is not null then
    perform public.erase_household(owned);
    return 'household_deleted';
  end if;

  select * into profile from public.members where user_id = target_user;
  if profile.id is null then
    return 'no_household';
  end if;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    return 'unlinked';
  end if;

  delete from public.member_allergies where member_id = profile.id;
  -- Notes about how someone likes their food are about them; they go with the name.
  delete from public.serving_notes where member_id = profile.id;
  -- So does their usual schedule, saved or not.
  update public.attendance_templates set schedules = schedules - profile.id::text
  where household_id = profile.household_id;
  -- Their requests stay (the family's history of what was wanted), without their own words.
  update public.requests set note = null where requested_by_member_id = profile.id;
  -- Their ratings stay as anonymous history; what they wrote in their own words doesn't.
  update public.reactions set comment = null where member_id = profile.id;
  update public.members
  set status = 'removed', removed_at = now(), first_name = 'Former member', avatar = null,
      attendance_defaults = '{}', notification_prefs = '{}', declared_age_band = null, anonymized_at = now()
  where id = profile.id;
  return 'profile_anonymized';
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

create or replace function public.anonymize_expired_profiles()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  removed uuid[];
  withdrawn uuid[];
begin
  select coalesce(array_agg(m.id), '{}') into removed
  from public.members m
  where m.age_group = 'kid' and m.anonymized_at is null and m.user_id is null
    and m.status = 'removed' and m.removed_at < now() - interval '12 months';

  select coalesce(array_agg(m.id), '{}') into withdrawn
  from public.members m
  where m.age_group = 'kid' and m.user_id is null and m.status <> 'removed'
    and not public.has_parental_consent(m.id)
    -- Measured from the latest withdrawal, so an older consent cycle can't shorten the 30 days;
    -- erased again only if a newer withdrawal came after the last erase.
    and (select max(c.revoked_at) from public.consents c where c.member_id = m.id and c.kind = 'parental')
        < now() - interval '30 days'
    and (m.own_data_erased_at is null
         or m.own_data_erased_at < (select max(c.revoked_at) from public.consents c
                                    where c.member_id = m.id and c.kind = 'parental'));

  delete from public.member_allergies where member_id = any (removed);
  delete from public.serving_notes where member_id = any (removed);
  update public.requests set note = null where requested_by_member_id = any (removed);
  -- A removed kid's ratings stay as anonymous history; their own words don't.
  update public.reactions set comment = null where member_id = any (removed);
  -- Their usual schedule goes with their name, saved copies too.
  update public.attendance_templates t set schedules = t.schedules - (select array_agg(r::text) from unnest(removed) r)
  where t.household_id in (select m.household_id from public.members m where m.id = any (removed));
  -- What a kid rated themselves (not what a parent entered for them by passing the phone) is theirs to lose.
  delete from public.reactions where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.reactions set comment = null where member_id = any (withdrawn);
  -- The thanks a kid sent from their own phone are theirs too.
  delete from public.chef_thanks where from_member_id = any (withdrawn);
  -- Notes a kid wrote themselves are theirs; ones a parent wrote for them stay.
  delete from public.serving_notes where member_id = any (withdrawn) and written_by_member_id = member_id;
  -- What a kid asked for themselves goes (the spec's "requests"), with their me-toos.
  delete from public.request_plus_ones where member_id = any (withdrawn) and entered_by_member_id = member_id;
  delete from public.request_plus_ones where request_id in
    (select id from public.requests where requested_by_member_id = any (withdrawn) and entered_by_member_id = requested_by_member_id);
  delete from public.requests where requested_by_member_id = any (withdrawn) and entered_by_member_id = requested_by_member_id;
  update public.members
  set first_name = 'Former member', avatar = null, attendance_defaults = '{}', notification_prefs = '{}',
      declared_age_band = null, anonymized_at = now()
  where id = any (removed);

  update public.members
  set declared_age_band = null, own_data_erased_at = now()
  where id = any (withdrawn);

  return cardinality(removed) + cardinality(withdrawn);
end;
$$;
