-- Server push: Plan's set and urgent items outside the budget, and no push names a kid whose consent is withdrawn.
-- 1. Budgets (Chris, 2026-11-02, Q2): plan_set and urgent_item never count toward the weekly budget and are never dropped
--    as over_budget. Neither counts as used, in the log or in flight, so they don't crowd out anything else either. The
--    device leaves them out of its count too (NotificationPlanner).
-- 2. Names (Q4): a kid whose parental consent was withdrawn (push_may_name) is never named. The pushes that can be about
--    someone else (won't be home, will cook, something for tonight, a poll, heading to the store) say "Someone" instead
--    of skipping: the news is still the family's, and the planner can see who in the app. "Your idea made Friday" names
--    nobody and goes to the requester, who has no device once withdrawn. Three layers: what's queued gets no name, what's
--    handed to send-push has a withdrawn kid's name taken out, and withdrawing consent takes the name out of what's
--    already queued or sent at once, not 30 days later with retention.

-- Budgets -------------------------------------------------------------------------------------------------------------------------

-- Outside the budget: what someone needs to act on, whatever else they've had this week.
create function public.push_outside_budget(row_kind text)
returns boolean
language sql immutable set search_path = ''
as $$
  select row_kind in ('plan_set', 'urgent_item');
$$;

revoke execute on function public.push_outside_budget(text) from public, anon, authenticated;

-- What's gone out this week, less what's outside the budget.
create or replace function public.push_budget_left(target_member uuid, instant timestamptz)
returns int
language sql stable set search_path = ''
as $$
  select public.push_weekly_budget(m.id) - (
    select count(*)::int from public.notification_log l, public.household_week_bounds(m.household_id, instant) w
    where l.member_id = m.id and l.household_id = m.household_id
      and l.sent_at >= w.starts and l.sent_at < w.ends and not public.push_outside_budget(l.type))
  from public.members m where m.id = target_member;
$$;
-- As car 4's, with Plan's set and urgent items left out of the budget, and a withdrawn kid's name taken out at the last step.
create or replace function public.claim_push_outbox(batch_size int)
returns table (id uuid, kind text, week_start date, night_id uuid, night_date date, args jsonb, attempts int,
               devices jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  -- auth.sessions has no row past a sign-out and a not_after past its timebox. Inactivity timeouts (off in config.toml)
  -- would leave the row: check refreshed_at here if they're ever turned on.
  delete from public.push_devices d
  where d.session_id is not null
    and not exists (select 1 from auth.sessions s
                    where s.id = d.session_id and (s.not_after is null or s.not_after > now()));

  update public.push_outbox o set failed = 'stale'
  where o.sent_at is null and o.failed is null
    and (o.not_before < now() - interval '1 day' or o.expires_at <= now()
         or (o.kind in ('not_home', 'claim', 'request_planned', 'urgent_item')
             and public.night_dinner_at(o.night_id) <= now()));

  -- Rows already handed out (a retry waiting) aren't ranked again: their first try already had the room.
  with due as (
    select o.id, o.member_id, o.attempts,
           row_number() over (partition by o.member_id
                              order by public.push_kind_rank(o.kind), o.not_before, o.created_at) as place
    from public.push_outbox o
    where o.sent_at is null and o.failed is null and o.not_before <= now() and o.attempts = 0
      and (o.claimed_until is null or o.claimed_until < now())
      and public.push_outbox_stands(o.kind, o.claim_id, o.request_id, o.night_id)
      and not public.push_outside_budget(o.kind)
  ), room as (
    -- A row handed out and not yet finished (a retry waiting, a run still sending, or one that crashed) holds its place,
    -- or a second row could take the same last slot and both would go.
    select d.member_id,
           public.push_budget_left(d.member_id, now())
             - (select count(*)::int from public.push_outbox f
                where f.member_id = d.member_id and f.sent_at is null and f.failed is null and f.attempts > 0
                  and public.push_outbox_stands(f.kind, f.claim_id, f.request_id, f.night_id)
                  and not public.push_outside_budget(f.kind)) as left_over
    from (select distinct member_id from due) d
  )
  -- Checked again on the row itself: another run may have claimed it since `due` was read.
  update public.push_outbox o set failed = 'over_budget'
  from due join room on room.member_id = due.member_id
  where o.id = due.id and due.place > room.left_over and o.failed is null and o.attempts = 0;

  return query
  with due as (
    select o.id from public.push_outbox o
    where o.sent_at is null and o.failed is null and o.not_before <= now() and o.attempts < 5
      and (o.claimed_until is null or o.claimed_until < now())
      and public.push_outbox_stands(o.kind, o.claim_id, o.request_id, o.night_id)
    order by public.push_kind_rank(o.kind), o.not_before
    limit greatest(batch_size, 0)
    for update skip locked
  ), claimed as (
    update public.push_outbox o
    set attempts = o.attempts + 1, claimed_until = now() + interval '2 minutes'
    from due where o.id = due.id
    returning o.*
  )
  select c.id, c.kind, p.week_start, c.night_id, n.date,
         case when c.about_member_id is not null and not public.push_may_name(c.about_member_id)
              then c.args - 'name' else c.args end,
         c.attempts,
         coalesce((select jsonb_agg(jsonb_build_object('token', d.token, 'environment', d.environment))
                   from public.push_devices d where d.member_id = c.member_id), '[]'::jsonb)
  from claimed c
  left join public.plans p on p.id = c.plan_id
  left join public.plan_nights n on n.id = c.night_id;
end;
$$;
-- Names ---------------------------------------------------------------------------------------------------------------------------

-- What a push about someone carries: their first name, unless they're a kid whose consent was withdrawn.
create function public.push_name_args(target_member uuid)
returns jsonb
language sql stable set search_path = ''
as $$
  select case when public.push_may_name(m.id) then jsonb_build_object('name', m.first_name) else '{}'::jsonb end
  from public.members m where m.id = target_member;
$$;

revoke execute on function public.push_name_args(uuid) from public, anon, authenticated;

-- Won't be home.
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
  select m.household_id, m.id, 'not_home', night.id, person.id, public.push_name_args(person.id),
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
-- Will cook.
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
  select m.household_id, m.id, 'claim', night.id, cook.id, new.id, public.push_name_args(cook.id),
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
-- Something for tonight.
create or replace function public.list_items_enqueue_urgent()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.household_time_zone(new.household_id);
  dinner_at timestamptz := public.household_dinner_tonight(new.household_id);
  tonight uuid;
  adder public.members;
begin
  select * into adder from public.members where id = new.urgent_by and status <> 'removed';
  if adder.id is null
     or public.household_away_on(new.household_id, (now() at time zone tz)::date)
     or dinner_at <= now() then
    return null;
  end if;
  select n.id into tonight from public.plan_nights n
  where n.household_id = new.household_id and n.date = (now() at time zone tz)::date limit 1;

  insert into public.push_outbox
    (household_id, member_id, kind, night_id, about_member_id, args, not_before, expires_at)
  select m.household_id, m.id, 'urgent_item', tonight, adder.id, public.push_name_args(adder.id),
         held.not_before, dinner_at
  from public.members m
  cross join lateral (select public.push_not_before(tz, false, now()) as not_before) held
  where m.household_id = new.household_id and m.age_group = 'adult' and m.status <> 'removed' and m.id <> adder.id
    -- Travelling (the rule create_week and member_usually_home use): they can't pick it up on the way home.
    and not (m.status = 'away' and (m.away_until is null or (now() at time zone tz)::date < m.away_until))
    and held.not_before < dinner_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id)
    and not exists (select 1 from public.push_outbox o
                    where o.member_id = m.id and o.kind = 'urgent_item'
                      and ((o.sent_at is null and o.failed is null) or o.sent_at > now() - interval '15 minutes'));
  return null;
end;
$$;
-- Tonight poll.
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
  select m.household_id, m.id, 'tonight_poll', night.id, starter.id, public.push_name_args(starter.id),
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
-- Heading to the store.
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
  select m.household_id, m.id, 'heading_to_store', starter.id, public.push_name_args(starter.id),
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
-- Withdrawing consent takes the name out of what's queued or sent about them at once. A digest also stops pointing at
-- them, as retention does; the other kinds keep about_member_id, which once-only and call-offs key on.
create function public.consents_unname_pushes()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.push_may_name(new.member_id) then
    update public.push_outbox set args = args - 'name', about_member_id = null
    where kind = 'new_requests' and about_member_id = new.member_id;
    update public.push_outbox set args = args - 'name'
    where about_member_id = new.member_id and args ? 'name';
  end if;
  return null;
end;
$$;

revoke execute on function public.consents_unname_pushes() from public, anon, authenticated;

create trigger consents_unname_pushes after update of revoked_at on public.consents
  for each row when (new.kind = 'parental' and old.revoked_at is null and new.revoked_at is not null
                     and new.member_id is not null)
  execute function public.consents_unname_pushes();
