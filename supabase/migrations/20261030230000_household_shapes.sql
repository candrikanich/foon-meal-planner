-- Household shapes (#49). No new table: each of these lives on what it describes.
-- 1. A recurring away pattern is attendance_defaults.away_pattern: {"every_weeks": 2, "from": "yyyy-MM-dd", "days": [ISO
--    weekdays]}, away for those weekdays (all, without days) in the first of every N seven-day stretches from "from".
--    create_week reads it through member_usually_home, and saved schedules snapshot attendance_defaults whole, so it comes
--    along. Older apps write attendance_defaults whole, without the key, so from the app that column now merges by key:
--    a key left out stays, and null takes one away. Functions that replace the whole thing (a saved schedule, retention)
--    run as their owner and aren't touched by that.
-- 2. members.eats_separately (babies and toddlers): parents set it. Their ratings stop counting, and new ones are refused.
--    They stay on attendance, so allergy flags and serving notes still go by who's home. The tonight poll (#43) isn't built;
--    when it is, it reads this column to leave them out of the votes.
-- 3. households.settings.food_rules: [{"avoid": "meat", "when": "lent_fridays"}], at most one per food. Build my week's
--    filters read it on the device (BuildMyWeek.fits); only set_food_rule writes it, under a lock on the household.
--    A settings save leaves it alone: update_household_settings merges keys. It says nothing about why a household has it.
-- 4. Two seatings, the model only: plan_nights.second_seating_time and night_attendance.seating. Nothing writes or reads
--    them yet (no grant, no planning, no UI), so create_week, attendance and older apps are as they were.
-- 5. reactions.comment_hidden_at: a planner hides a comment without deleting it. meal_comments is what the app reads.
--    reactions stays readable by the family because older apps select its comment column, and row-level security can't
--    hide one column of one row; they never show it. Retention clears the text as before, hidden or not.

-- 1. Recurring away patterns ----------------------------------------------------------------------------------------

-- Reads leniently: attendance_defaults can be written directly, and a bad value must never stop a week from starting, nor
-- put anyone away.
create function public.away_pattern_covers(pattern jsonb, day date)
returns boolean
language sql immutable set search_path = ''
as $$
  select coalesce((
    select day >= parsed.first_night
           and (day - parsed.first_night) / 7 % parsed.every_weeks = 0
           and (jsonb_array_length(parsed.days) = 0 or parsed.days @> to_jsonb(extract(isodow from day)::int))
    from (
      select case when pg_input_is_valid(pattern ->> 'from', 'date') then (pattern ->> 'from')::date end as first_night,
             case when pattern ->> 'every_weeks' ~ '^[2-4]$' then (pattern ->> 'every_weeks')::int end as every_weeks,
             case when jsonb_typeof(pattern -> 'days') = 'array' then pattern -> 'days' else '[]'::jsonb end as days
    ) parsed
    where isfinite(parsed.first_night) and parsed.every_weeks is not null
  ), false);
$$;

revoke execute on function public.away_pattern_covers(jsonb, date) from public, anon;
grant execute on function public.away_pattern_covers(jsonb, date) to authenticated;

create or replace function public.member_usually_home(person public.members, day date)
returns boolean
language sql stable set search_path = ''
as $$
  select not (
    coalesce(person.attendance_defaults -> 'usually_away', '[]'::jsonb) @> to_jsonb(extract(isodow from day)::int)
    or public.away_pattern_covers(person.attendance_defaults -> 'away_pattern', day)
    or (person.status = 'away' and (person.away_until is null or day < person.away_until))
  );
$$;

-- 2. Eats separately --------------------------------------------------------------------------------------------------

alter table public.members add column eats_separately boolean not null default false;

grant insert (eats_separately) on public.members to authenticated;
grant update (eats_separately) on public.members to authenticated;

create or replace function public.members_guard_write()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  household_owner uuid;
begin
  if tg_op = 'UPDATE' and new.status = 'removed' and old.status <> 'removed' then
    new.user_id := null;
    new.away_until := null;
    -- A removed profile could be re-claimed later (#9); it must not carry guardian rights.
    new.guardian := false;
  end if;

  if caller is null or current_user <> 'authenticated' then
    return new;
  end if;

  select owner into household_owner from public.households where id = new.household_id;

  if tg_op = 'INSERT' then
    -- Only the owner's own first profile is linked at insert; everyone else claims via the server (#9).
    if new.user_id is not null and new.user_id <> caller then
      raise exception 'profiles are claimed through an invite' using errcode = '42501';
    end if;
    if new.user_id = household_owner then
      new.guardian := true;
    end if;
    return new;
  end if;

  if new.household_id <> old.household_id then
    raise exception 'members cannot move between households' using errcode = '42501';
  end if;
  if new.user_id is distinct from old.user_id and new.status <> 'removed' then
    raise exception 'profiles are claimed through an invite' using errcode = '42501';
  end if;

  if old.user_id = household_owner
     and (new.role, new.age_group, new.status, new.guardian, new.eats_separately)
         is distinct from (old.role, old.age_group, old.status, old.guardian, old.eats_separately) then
    if caller <> household_owner then
      raise exception 'only the owner changes the owner''s profile' using errcode = '42501';
    end if;
    if not new.guardian or new.status = 'removed' then
      raise exception 'the owner stays a guardian; transfer ownership first' using errcode = '42501';
    end if;
  end if;

  if not public.is_household_manager(old.household_id) then
    if old.user_id is distinct from caller then
      raise exception 'only guardians manage other members' using errcode = '42501';
    end if;
    if (new.first_name, new.role, new.age_group, new.status, new.away_until, new.guardian, new.eats_separately)
       is distinct from (old.first_name, old.role, old.age_group, old.status, old.away_until, old.guardian, old.eats_separately) then
      raise exception 'members can edit only their avatar, schedule, and notification settings'
        using errcode = '42501';
    end if;
  end if;

  -- A schedule saved from the app changes the keys it sends: an older app or a stale phone doesn't know them all.
  if new.attendance_defaults is distinct from old.attendance_defaults then
    new.attendance_defaults := old.attendance_defaults || new.attendance_defaults;
    if new.attendance_defaults -> 'away_pattern' = 'null'::jsonb then
      new.attendance_defaults := new.attendance_defaults - 'away_pattern';
    end if;
  end if;

  return new;
end;
$$;

-- Their verdicts stop counting, like a removed member's: no dislike, favorite or vote to retire a dish, and the view is
-- what reactions_retire_disliked counts. A dish already retired stays retired.
create or replace view public.meal_verdicts
with (security_invoker = true)
as
  select distinct on (r.household_id, r.member_id, l.meal_id)
         r.household_id, l.meal_id, r.member_id, r.reaction, n.date as reacted_on
  from public.reactions r
  join public.meal_logs l on l.id = r.meal_log_id
  join public.plan_nights n on n.id = l.night_id
  join public.members m on m.id = r.member_id
  where l.meal_id is not null and m.status <> 'removed' and not m.eats_separately
  order by r.household_id, r.member_id, l.meal_id, n.date desc, r.updated_at desc;

create or replace view public.meal_likes
with (security_invoker = true)
as
  select r.household_id, l.meal_id, count(*)::int as likes
  from public.reactions r
  join public.meal_logs l on l.id = r.meal_log_id
  join public.members m on m.id = r.member_id
  where l.meal_id is not null and r.reaction in ('favorite', 'good') and not m.eats_separately
  group by r.household_id, l.meal_id;

-- FD004: an app that hasn't heard about the flag gets its own words, not "Check your connection".
create or replace function public.reactions_guard()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if (select eats_separately from public.members where id = new.member_id) then
    raise exception 'they eat separately, so they don''t rate dinners' using errcode = 'FD004';
  end if;
  if tg_op = 'UPDATE' then
    if old.created_at < now() - interval '24 hours' then
      raise exception 'reactions lock after 24 hours' using errcode = '42501';
    end if;
    -- The last writer, so a rating a parent entered and a kid later changed counts as the kid's.
    new.entered_by_member_id := public.my_member_id(new.household_id);
    return new;
  end if;
  if not public.is_household_member(new.household_id) then
    raise exception 'not your household' using errcode = '42501';
  end if;
  -- The card's reach: a new rating is for a dinner in the last week, not one from months ago.
  if (select n.date from public.meal_logs l join public.plan_nights n on n.id = l.night_id where l.id = new.meal_log_id)
     < public.household_today(new.household_id) - 7 then
    raise exception 'that dinner was too long ago to rate' using errcode = '22023';
  end if;
  if (select meal_id from public.meal_logs where id = new.meal_log_id) is null then
    raise exception 'only dishes are rated, not quick picks' using errcode = '22023';
  end if;
  new.entered_by_member_id := public.my_member_id(new.household_id);
  return new;
end;
$$;

-- 3. Food rules -------------------------------------------------------------------------------------------------------

-- Changes one food's rule in the list as it is now, so a device with an old copy can't undo another planner's. A rule from
-- a newer app is left as it is. Null takes the rule away. Returns the list.
create function public.set_food_rule(target_household uuid, avoid text, on_nights text)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  rules jsonb;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners set food rules' using errcode = '42501';
  end if;
  if avoid is null or avoid not in ('meat', 'pork', 'shellfish')
     or (on_nights is not null and on_nights not in ('lent_fridays', 'fridays', 'every_night')) then
    raise exception 'not a food rule Foon can recognize' using errcode = '22023';
  end if;

  select settings -> 'food_rules' into rules from public.households where id = target_household for update;

  select coalesce(jsonb_agg(rule order by position), '[]'::jsonb) into rules
  from jsonb_array_elements(case when jsonb_typeof(rules) = 'array' then rules else '[]'::jsonb end)
       with ordinality as entries (rule, position)
  where rule ->> 'avoid' is distinct from avoid;

  if on_nights is not null then
    rules := rules || jsonb_build_object('avoid', avoid, 'when', on_nights);
  end if;

  update public.households set settings = settings || jsonb_build_object('food_rules', rules)
  where id = target_household;
  return rules;
end;
$$;

revoke execute on function public.set_food_rule(uuid, text, text) from public, anon;
grant execute on function public.set_food_rule(uuid, text, text) to authenticated;

-- 4. Two seatings, the model only ---------------------------------------------------------------------------------------

alter table public.plan_nights add column second_seating_time time;
alter table public.night_attendance add column seating smallint not null default 1 check (seating in (1, 2));

-- 5. Hiding a comment -------------------------------------------------------------------------------------------------

-- Not granted to anyone: only set_comment_hidden writes it, so the person who wrote a comment can't bring it back.
alter table public.reactions add column comment_hidden_at timestamptz;

-- Comments as the family sees them: a hidden one only for planners, marked, so they can bring it back. Like verdicts,
-- a removed member's or someone who eats separately doesn't show.
create view public.meal_comments
with (security_invoker = true)
as
  select r.id, r.household_id, l.meal_id, r.member_id, r.comment, n.date as dinner_on,
         r.comment_hidden_at is not null as hidden
  from public.reactions r
  join public.meal_logs l on l.id = r.meal_log_id
  join public.plan_nights n on n.id = l.night_id
  join public.members m on m.id = r.member_id
  where r.comment is not null and l.meal_id is not null and m.status <> 'removed' and not m.eats_separately
    and (r.comment_hidden_at is null or public.is_household_planner(r.household_id));

revoke all on public.meal_comments from anon, authenticated;
grant select on public.meal_comments to authenticated;

-- Security definer: the author's columns are the only ones the table lets a person write, and this leaves them alone
-- (reactions_guard would otherwise record the planner as whoever entered the rating).
create function public.set_comment_hidden(target_reaction uuid, hide boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  household uuid;
begin
  select household_id into household from public.reactions
  where id = target_reaction and public.is_household_member(household_id);
  if household is null then
    raise exception 'no comment %', target_reaction using errcode = 'P0002';
  end if;
  if not public.is_household_planner(household) then
    raise exception 'only planners hide comments' using errcode = '42501';
  end if;
  update public.reactions
  set comment_hidden_at = case when hide then coalesce(comment_hidden_at, now()) end
  where id = target_reaction;
end;
$$;

revoke execute on function public.set_comment_hidden(uuid, boolean) from public, anon;
grant execute on function public.set_comment_hidden(uuid, boolean) to authenticated;
