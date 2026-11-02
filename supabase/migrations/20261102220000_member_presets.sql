-- Per-member notification presets (#47, car 6 part A): each person can have their own Light, Balanced or Engaged, or follow
-- the household's (the default). Both delivery paths read it: the device's ReminderRules for whoever's on the phone, and
-- every server push through member_preset.
-- 1. Stored where it always was meant to be, members.notification_prefs ->> 'preset'. Members already read their household's
--    rows; nobody else can. Written only through set_member_preset now: the column grants that let a client write
--    notification_prefs directly are taken back (no app writes it).
-- 2. Who sets it: an adult sets their own. A guardian sets a kid's, and a profile nobody has claimed (no one else can speak
--    for it; once claimed, it's theirs). Nobody else changes another adult's, guardians and planners included. A kid doesn't
--    set their own. A kid's can't be above the household's: set higher, it's refused, and if the household's later drops
--    below it, the household's wins (the device's rule).
-- 3. Plan's set and urgent list items go on every preset, so their triggers don't change. Won't be home and will cook need
--    the recipient on Balanced or Engaged; the tonight poll, "your idea made Friday", the new-ideas digest and heading to the
--    store need them on Engaged. Budgets follow their own preset. Kids' budget numbers and quiet hours are unchanged.
-- 4. Retention: every anonymize path already resets notification_prefs to '{}'.

-- Who it is ------------------------------------------------------------------------------------------------------------------

-- Their preset, as ReminderRules.preset: their own if set, else the household's; a kid's only ever lower than the household's.
create function public.member_preset(target_member uuid)
returns text
language sql stable set search_path = ''
as $$
  select case
    when own is null then household
    when m.age_group = 'kid' and array_position(array['light', 'balanced', 'engaged'], own)
                                 > array_position(array['light', 'balanced', 'engaged'], household) then household
    else own
  end
  from public.members m
  cross join lateral (select public.household_notification_preset(m.household_id) as household) h
  cross join lateral (
    select case when m.notification_prefs ->> 'preset' in ('light', 'balanced', 'engaged')
                then m.notification_prefs ->> 'preset' end as own) o
  where m.id = target_member;
$$;

revoke execute on function public.member_preset(uuid) from public, anon, authenticated;

revoke insert (notification_prefs), update (notification_prefs) on public.members from authenticated;

-- Null follows the household.
create function public.set_member_preset(target_member uuid, preset text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  person public.members;
begin
  if preset is not null and preset not in ('light', 'balanced', 'engaged') then
    raise exception 'a preset is light, balanced or engaged' using errcode = '22023';
  end if;
  select * into person from public.members where id = target_member for update;
  if person.id is null or not public.is_household_member(person.household_id) or person.status = 'removed' then
    raise exception 'no member %', target_member using errcode = 'P0002';
  end if;

  if person.user_id = (select auth.uid()) and public.session_is_active() then
    if person.age_group = 'kid' then
      raise exception 'a parent sets a kid''s notifications' using errcode = '42501';
    end if;
  elsif not (public.is_household_manager(person.household_id) and (person.age_group = 'kid' or person.user_id is null)) then
    raise exception 'people set their own; a parent sets a kid''s or an unclaimed profile''s' using errcode = '42501';
  end if;

  if person.age_group = 'kid' and preset is not null
     and array_position(array['light', 'balanced', 'engaged'], preset)
         > array_position(array['light', 'balanced', 'engaged'], public.household_notification_preset(person.household_id)) then
    raise exception 'a kid''s can''t be more than the family''s' using errcode = '22023';
  end if;

  update public.members
  set notification_prefs = case when preset is null then notification_prefs - 'preset'
                                else notification_prefs || jsonb_build_object('preset', preset) end
  where id = person.id;
end;
$$;

revoke execute on function public.set_member_preset(uuid, text) from public, anon;
grant execute on function public.set_member_preset(uuid, text) to authenticated;

-- Every push that depends on a preset reads the recipient's ------------------------------------------------------------------

-- Won't be home: planners whose own preset has the check-in (Balanced or Engaged).
create or replace function public.night_attendance_enqueue_not_home()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  tz text;
  dinner_at timestamptz;
  person public.members;
  tapped_by uuid;
begin
  if new.expected or new.checked_in_at is null then
    -- Back home, or a planner's write: whatever hasn't gone yet isn't news any more.
    if tg_op = 'UPDATE' then
      delete from public.push_outbox
      where kind = 'not_home' and night_id = new.plan_night_id and about_member_id = new.member_id
        and sent_at is null and failed is null;
    end if;
    return null;
  end if;

  -- Someone who won't be home isn't cooking: their claim is on hold, so "will cook" mustn't go out after "won't be home".
  delete from public.push_outbox
  where kind = 'claim' and night_id = new.plan_night_id and about_member_id = new.member_id
    and sent_at is null and failed is null;

  if exists (select 1 from public.push_outbox
             where kind = 'not_home' and night_id = new.plan_night_id and about_member_id = new.member_id) then
    return null;
  end if;

  select * into night from public.plan_nights where id = new.plan_night_id;
  tz := public.household_time_zone(night.household_id);
  dinner_at := public.night_dinner_at(night.id);
  if public.household_away_on(night.household_id, night.date)
     or exists (select 1 from public.meal_logs l where l.night_id = night.id)
     or dinner_at <= now() then
    return null;
  end if;

  select * into person from public.members where id = new.member_id;
  tapped_by := public.my_member_id(night.household_id);

  insert into public.push_outbox
    (household_id, member_id, kind, night_id, about_member_id, args, not_before, expires_at)
  select m.household_id, m.id, 'not_home', night.id, person.id, jsonb_build_object('name', person.first_name),
         held.not_before, dinner_at
  from public.members m
  cross join lateral (select public.push_not_before(tz, m.age_group = 'kid', now()) as not_before) held
  where m.household_id = night.household_id and m.role = 'planner' and m.status <> 'removed'
    and m.id <> person.id and m.id is distinct from tapped_by
    and public.member_preset(m.id) <> 'light'
    and held.not_before < dinner_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

-- Will cook: the same.
create or replace function public.night_claims_enqueue_claim()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  tz text := public.household_time_zone(new.household_id);
  dinner_at timestamptz;
  cook public.members;
begin
  select * into night from public.plan_nights where id = new.night_id;
  dinner_at := public.night_dinner_at(night.id);
  -- A night still ahead is in a week that isn't over.
  if night.date < (now() at time zone tz)::date
     or public.household_away_on(night.household_id, night.date)
     or dinner_at <= now() then
    return null;
  end if;

  select * into cook from public.members where id = new.member_id;

  insert into public.push_outbox
    (household_id, member_id, kind, night_id, about_member_id, claim_id, args, not_before, expires_at)
  select m.household_id, m.id, 'claim', night.id, cook.id, new.id, jsonb_build_object('name', cook.first_name),
         held.not_before, dinner_at
  from public.members m
  cross join lateral (select public.push_not_before(tz, m.age_group = 'kid', now()) as not_before) held
  where m.household_id = night.household_id and m.role = 'planner' and m.status <> 'removed'
    and m.id <> cook.id and m.id is distinct from new.entered_by_member_id
    and public.member_preset(m.id) <> 'light'
    and held.not_before < dinner_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

-- Tonight poll: whoever can vote and is on Engaged themselves.
create or replace function public.polls_enqueue_tonight_poll()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  tz text := public.household_time_zone(new.household_id);
  starter public.members;
  tapped_by uuid := public.my_member_id(new.household_id);
begin
  select * into night from public.plan_nights where id = new.night_id;
  select * into starter from public.members where id = new.started_by;
  if starter.id is null or public.household_away_on(night.household_id, night.date) or new.closes_at <= now() then
    return null;
  end if;

  -- The same people vote_in_poll lets vote: no attendance row means home, and someone who eats separately doesn't vote.
  insert into public.push_outbox
    (household_id, member_id, kind, night_id, about_member_id, args, not_before, expires_at)
  select m.household_id, m.id, 'tonight_poll', night.id, starter.id, jsonb_build_object('name', starter.first_name),
         held.not_before, new.closes_at
  from public.members m
  cross join lateral (select public.push_not_before(tz, m.age_group = 'kid', now()) as not_before) held
  where m.household_id = night.household_id and m.status <> 'removed' and not m.eats_separately
    and m.id <> starter.id and m.id is distinct from tapped_by
    and public.member_preset(m.id) = 'engaged'
    and not exists (select 1 from public.night_attendance a
                    where a.plan_night_id = night.id and a.member_id = m.id and not a.expected)
    and held.not_before < new.closes_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

-- Your idea made Friday: whoever asked, on Engaged themselves.
create or replace function public.plans_enqueue_request_planned()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.household_time_zone(new.household_id);
  approver uuid := public.my_member_id(new.household_id);
begin
  insert into public.push_outbox
    (household_id, member_id, kind, night_id, about_member_id, request_id, not_before, expires_at)
  select r.household_id, m.id, 'request_planned', n.id, m.id, r.id, held.not_before, dinner.at
  from public.requests r
  join public.plan_nights n on n.id = r.planned_night_id
  join public.members m on m.id = r.requested_by_member_id
  cross join lateral (select public.night_dinner_at(n.id) as at) dinner
  cross join lateral (select public.push_not_before(tz, m.age_group = 'kid', now()) as not_before) held
  where n.plan_id = new.id and r.status = 'planned'
    and m.status <> 'removed' and m.id is distinct from approver
    and public.member_preset(m.id) = 'engaged'
    -- Whoever asked, on their own phone: one a parent entered for a profile nobody had claimed isn't theirs to hear about.
    and coalesce(r.entered_by_member_id, r.requested_by_member_id) = r.requested_by_member_id
    and n.date >= (now() at time zone tz)::date and dinner.at > now()
    and not public.household_away_on(n.household_id, n.date)
    and held.not_before < dinner.at
    and exists (select 1 from public.push_devices d where d.member_id = m.id)
    and not exists (select 1 from public.push_outbox o where o.request_id = r.id and o.kind = 'request_planned');
  return null;
end;
$$;

-- Budgets: by their own preset, as the device's ReminderRules.
create or replace function public.push_weekly_budget(target_member uuid)
returns int
language sql stable set search_path = ''
as $$
  select case public.member_preset(m.id)
           when 'light' then case when m.age_group = 'kid' then 2 else 8 end
           when 'engaged' then case when m.age_group = 'kid' then 6 else 16 end
           else case when m.age_group = 'kid' then 5 else 12 end
         end
  from public.members m where m.id = target_member;
$$;

-- New-ideas digest: planners on Engaged themselves.
create or replace function public.enqueue_request_digests(at timestamptz default now())
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  queued int := 0;
  added int;
  house record;
begin
  for house in
    select h.id, public.household_time_zone(h.id) as tz from public.households h
    where exists (select 1 from public.members p
                  where p.household_id = h.id and p.role = 'planner' and p.status <> 'removed'
                    and public.member_preset(p.id) = 'engaged')
  loop
    if (at at time zone house.tz)::time < time '19:30' or (at at time zone house.tz)::time >= time '21:00'
       or public.household_away_on(house.id, (at at time zone house.tz)::date) then
      continue;
    end if;

    insert into public.push_outbox
      (household_id, member_id, kind, about_member_id, args, not_before, expires_at, created_at)
    select house.id, m.id, 'new_requests', named.id,
           jsonb_build_object('count', news.count)
             || case when named.id is not null then jsonb_build_object('name', named.first_name) else '{}' end,
           public.push_not_before(house.tz, m.age_group = 'kid', at),
           ((at at time zone house.tz)::date + time '21:00') at time zone house.tz,
           at
    from public.members m
    cross join lateral (
      select coalesce(max(o.created_at), at - interval '1 day') as since
      from public.push_outbox o where o.member_id = m.id and o.kind = 'new_requests'
    ) last_digest
    cross join lateral (
      select count(*)::int as count,
             case when count(distinct r.requested_by_member_id) = 1 then min(r.requested_by_member_id::text)::uuid end
               as only_one
      from public.requests r
      where r.household_id = house.id and r.status = 'open'
        and r.created_at > greatest(last_digest.since, at - interval '1 day') and r.created_at <= at
        and r.requested_by_member_id <> m.id and r.entered_by_member_id is distinct from m.id
        -- Someone removed isn't asking any more, and their name mustn't go out.
        and exists (select 1 from public.members asker
                    where asker.id = r.requested_by_member_id and asker.status <> 'removed')
    ) news
    left join public.members named on named.id = news.only_one and public.push_may_name(named.id)
    where m.household_id = house.id and m.role = 'planner' and m.status <> 'removed'
      and public.member_preset(m.id) = 'engaged'
      and news.count > 0
      and exists (select 1 from public.push_devices d where d.member_id = m.id)
      and not exists (select 1 from public.push_outbox o
                      where o.member_id = m.id and o.kind = 'new_requests'
                        and (o.created_at at time zone house.tz)::date = (at at time zone house.tz)::date);
    get diagnostics added = row_count;
    queued := queued + added;
  end loop;
  return queued;
end;
$$;

-- Heading to the store: everyone else on Engaged themselves.
create or replace function public.store_runs_enqueue_push()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.household_time_zone(new.household_id);
  starter public.members;
begin
  if public.household_away_on(new.household_id, (now() at time zone tz)::date) then
    return null;
  end if;
  select * into starter from public.members where id = new.started_by and status <> 'removed';
  if starter.id is null then
    return null;
  end if;

  insert into public.push_outbox
    (household_id, member_id, kind, about_member_id, args, not_before, expires_at)
  select m.household_id, m.id, 'heading_to_store', starter.id, jsonb_build_object('name', starter.first_name),
         held.not_before, new.ends_at
  from public.members m
  cross join lateral (select public.push_not_before(tz, m.age_group = 'kid', now()) as not_before) held
  where m.household_id = new.household_id and m.status <> 'removed' and m.id <> starter.id
    and public.member_preset(m.id) = 'engaged'
    -- Travelling (the rule urgent items use): nothing to add from away.
    and not (m.status = 'away' and (m.away_until is null or (now() at time zone tz)::date < m.away_until))
    and held.not_before < new.ends_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

