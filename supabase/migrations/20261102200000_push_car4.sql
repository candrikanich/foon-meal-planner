-- Server push, car 4 (#40 part 2): budgets for server pushes, and the new-ideas digest for planners.
-- 1. Budgets: server pushes count against the device's per-person, per-household-week budget (kids 2 / 5 / 6, adults
--    8 / 12 / 16 on Light / Balanced / Engaged), counted from notification_log: what's gone out that week, either channel.
--    At claim time, due rows are ranked per person (Plan's set and urgent items first) and whatever would take them past
--    what's left ends as failed = 'over_budget': never sent, retried or logged. Nothing is reserved.
-- 2. Digest: once a day at 7:30pm on the household's clock, Engaged planners hear about ideas added since their last digest
--    (at most a day back), still open, and not their own. "Ben has 2 new dinner ideas." / "2 new dinner ideas." Never a dish.
--    A pg_cron job every 15 minutes queues it between 7:30 and 9pm, once a planner a day. Not on an away day. Not for ideas
--    from someone removed; a kid whose consent is withdrawn takes along the digests naming them.

-- Budgets -------------------------------------------------------------------------------------------------------------------------

-- The household week holding `instant`, as instants on its clock: settings.week_start (ISO weekday, default Sunday).
create function public.household_week_bounds(target_household uuid, instant timestamptz, out starts timestamptz,
                                             out ends timestamptz)
language sql stable set search_path = ''
as $$
  select (first_day + time '00:00') at time zone tz, (first_day + 7 + time '00:00') at time zone tz
  from (select tz, day - ((extract(isodow from day)::int - start_day + 7) % 7) as first_day
        from (select public.household_time_zone(h.id) as tz,
                     (instant at time zone public.household_time_zone(h.id))::date as day,
                     case when h.settings ->> 'week_start' ~ '^[1-7]$' then (h.settings ->> 'week_start')::int else 7 end
                       as start_day
              from public.households h where h.id = target_household) clock) week;
$$;

-- The device's numbers (ReminderRules): by the household's preset and whether they're a kid.
create function public.push_weekly_budget(target_member uuid)
returns int
language sql stable set search_path = ''
as $$
  select case public.household_notification_preset(m.household_id)
           when 'light' then case when m.age_group = 'kid' then 2 else 8 end
           when 'engaged' then case when m.age_group = 'kid' then 6 else 16 end
           else case when m.age_group = 'kid' then 5 else 12 end
         end
  from public.members m where m.id = target_member;
$$;

-- What's left of their budget for the week holding `instant`: what's gone out that week, on either channel, is used.
create function public.push_budget_left(target_member uuid, instant timestamptz)
returns int
language sql stable set search_path = ''
as $$
  select public.push_weekly_budget(m.id) - (
    select count(*)::int from public.notification_log l, public.household_week_bounds(m.household_id, instant) w
    where l.member_id = m.id and l.household_id = m.household_id
      and l.sent_at >= w.starts and l.sent_at < w.ends)
  from public.members m where m.id = target_member;
$$;

-- Who goes first when a budget runs short: what someone needs to act on now, then what others are counting on, then news.
create function public.push_kind_rank(row_kind text)
returns int
language sql immutable set search_path = ''
as $$
  select case row_kind
    when 'plan_set' then 0 when 'urgent_item' then 0
    when 'not_home' then 1 when 'claim' then 1
    when 'tonight_poll' then 2
    else 3
  end;
$$;

revoke execute on function public.household_week_bounds(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.push_weekly_budget(uuid) from public, anon, authenticated;
revoke execute on function public.push_budget_left(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.push_kind_rank(text) from public, anon, authenticated;

-- Sending -------------------------------------------------------------------------------------------------------------------------

-- As car 3's, plus the budget: due rows past what each person has left this week end as over_budget before any is handed out.
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
  ), room as (
    select d.member_id, public.push_budget_left(d.member_id, now()) as left_over
    from (select distinct member_id from due) d
  )
  update public.push_outbox o set failed = 'over_budget'
  from due join room on room.member_id = due.member_id
  where o.id = due.id and due.place > room.left_over;

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
  select c.id, c.kind, p.week_start, c.night_id, n.date, c.args, c.attempts,
         coalesce((select jsonb_agg(jsonb_build_object('token', d.token, 'environment', d.environment))
                   from public.push_devices d where d.member_id = c.member_id), '[]'::jsonb)
  from claimed c
  left join public.plans p on p.id = c.plan_id
  left join public.plan_nights n on n.id = c.night_id;
end;
$$;

-- Retention -------------------------------------------------------------------------------------------------------------------------

-- As in 20261102190000_push_car3.sql, plus: a withdrawn kid's name goes out of the ideas digests that named them, sent ones too.
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
  -- Offers to cook a kid made themselves go; ones a parent entered for them stay, and a removed kid's stay anonymous.
  delete from public.night_claims where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.night_claims set released_at = now() where member_id = any (removed) and released_at is null;
  -- A vote a kid cast themselves goes, and a poll stops saying they started it. One a parent tapped in for them stays until it ages out.
  delete from public.poll_votes where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.polls set started_by = null where started_by = any (withdrawn);
  -- The pushes about a poll they started, something they marked for tonight, or ideas they added (a digest naming them)
  -- were about what they did themselves, sent ones too; and a line stops saying they marked it.
  delete from public.push_outbox
  where kind in ('tonight_poll', 'urgent_item', 'new_requests') and about_member_id = any (withdrawn);
  update public.list_items set urgent_by = null where urgent_by = any (withdrawn);
  -- A poll is about one dinner, so it ages out like the log, for everyone, and its votes go with it.
  delete from public.polls where created_at < now() - interval '8 weeks';
  -- A kid who plans: what they changed themselves goes. Entries about the plan itself age out below for everyone.
  delete from public.plan_changes where actor_member_id = any (withdrawn);
  delete from public.plan_changes where created_at < now() - interval '8 weeks';
  -- What was sent to a kid goes with them, and the log ages out for everyone.
  delete from public.notification_log where member_id = any (removed) or member_id = any (withdrawn);
  delete from public.notification_log where created_at < now() - interval '8 weeks';
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


-- New-ideas digest ------------------------------------------------------------------------------------------------------------------

-- Returns how many it queued, for tests. `at` is the moment it runs as (now, from pg_cron).
create function public.enqueue_request_digests(at timestamptz default now())
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
    where public.household_notification_preset(h.id) = 'engaged'
  loop
    if (at at time zone house.tz)::time < time '19:30' or (at at time zone house.tz)::time >= time '21:00'
       or public.household_away_on(house.id, (at at time zone house.tz)::date) then
      continue;
    end if;

    insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before, expires_at)
    select house.id, m.id, 'new_requests', news.only_one,
           jsonb_build_object('count', news.count)
             || case when news.only_one is not null then jsonb_build_object('name', who.first_name) else '{}' end,
           public.push_not_before(house.tz, m.age_group = 'kid', at),
           ((at at time zone house.tz)::date + time '21:00') at time zone house.tz
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
    left join public.members who on who.id = news.only_one
    where m.household_id = house.id and m.role = 'planner' and m.status <> 'removed'
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

revoke execute on function public.enqueue_request_digests(timestamptz) from public, anon, authenticated;

select cron.schedule('enqueue-request-digests', '*/15 * * * *', 'select public.enqueue_request_digests()');
