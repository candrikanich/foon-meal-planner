-- Server push, car 3 (#40 part 2): urgent list items, the tonight poll, and "Your idea made Friday".
-- 1. Urgent list item: a quick-list line becoming "for tonight" (added that way, or marked so since; a pivot for tonight's
--    dish counts) goes to the family's adults with a device, except whoever marked it, on every preset. Ordinary staple taps
--    and Out-adds are "whenever", so they notify no one. list_items.urgent_by keeps who marked it, set by the database.
--    Coalesced per recipient: nothing more while one is waiting, or within 15 minutes of the last one sent. News until
--    tonight's dinner. Once the person who marked it has no open urgent quick line left (bought, removed, moved or no longer
--    urgent), whatever hasn't gone about them is called off.
-- 2. Tonight poll: whoever can vote (home tonight by attendance, not someone who eats separately), except whoever started it,
--    on Engaged only. News until the poll closes; ending it early calls off what hasn't gone.
-- 3. Your idea made Friday: on a plan's first approval, as Plan's set, each request planned on a night of that week still
--    ahead goes to whoever asked, if they have a device and didn't approve it, on Engaged only. Once a request, ever. News
--    until that night's dinner.
-- All: first names only in args (none for an idea), never an item or a dish; not about an away night; quiet hours per
-- recipient, and nothing queued that quiet hours would hold past when it stops being news. The kinds are already allowed.

-- Columns -----------------------------------------------------------------------------------------------------------------------

-- No foreign key: a member is never hard-deleted while their household's lines exist.
alter table public.list_items add column urgent_by uuid;

alter table public.push_outbox
  add column request_id uuid references public.requests (id) on delete cascade;

create index push_outbox_request_idx on public.push_outbox (request_id);
create index list_items_urgent_by_idx on public.list_items (household_id, urgent_by)
  where urgency = 'tonight' and checked_at is null;

-- Helpers ---------------------------------------------------------------------------------------------------------------------

-- Tonight's dinner on the household's clock: tonight's night if there is one, else the household's dinner time, else 6pm.
create function public.household_dinner_tonight(target_household uuid)
returns timestamptz
language sql stable set search_path = ''
as $$
  select coalesce(
    (select public.night_dinner_at(n.id) from public.plan_nights n
     where n.household_id = target_household
       and n.date = (now() at time zone public.household_time_zone(target_household))::date
     limit 1),
    (select ((now() at time zone public.household_time_zone(h.id))::date
             + coalesce(case when h.settings ->> 'dinner_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                             then (h.settings ->> 'dinner_time')::time end, time '18:00'))
            at time zone public.household_time_zone(h.id)
     from public.households h where h.id = target_household));
$$;

revoke execute on function public.household_dinner_tonight(uuid) from public, anon, authenticated;

-- Urgent list item ---------------------------------------------------------------------------------------------------------------

-- Who marked a line for tonight, from the session: never from the client, which has no grant on the column. Nobody (a job,
-- the service role) leaves it empty. Otherwise an update leaves it alone, so retention can clear it.
create function public.list_items_stamp_urgent_by()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.urgency = 'tonight' and (tg_op = 'INSERT' or old.urgency is distinct from 'tonight') then
    new.urgent_by := public.my_member_id(new.household_id);
  elsif tg_op = 'INSERT' then
    new.urgent_by := null;
  end if;
  return new;
end;
$$;

revoke execute on function public.list_items_stamp_urgent_by() from public, anon, authenticated;

create trigger list_items_stamp_urgent_by before insert or update on public.list_items
  for each row execute function public.list_items_stamp_urgent_by();

create function public.list_items_enqueue_urgent()
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
  select m.household_id, m.id, 'urgent_item', tonight, adder.id, jsonb_build_object('name', adder.first_name),
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

-- Bought, removed, moved off the quick list, or no longer for tonight: once the person who marked it has nothing left for
-- tonight, it isn't news.
create function public.list_items_call_off_urgent()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.list_items l
                 where l.household_id = old.household_id and l.urgent_by = old.urgent_by
                   and l.list = 'quick' and l.urgency = 'tonight' and l.checked_at is null) then
    delete from public.push_outbox
    where household_id = old.household_id and kind = 'urgent_item' and about_member_id = old.urgent_by
      and sent_at is null and failed is null;
  end if;
  return null;
end;
$$;

revoke execute on function public.list_items_enqueue_urgent() from public, anon, authenticated;
revoke execute on function public.list_items_call_off_urgent() from public, anon, authenticated;

create trigger list_items_enqueue_urgent_insert after insert on public.list_items
  for each row when (new.list = 'quick' and new.urgency = 'tonight' and new.checked_at is null
                     and new.urgent_by is not null)
  execute function public.list_items_enqueue_urgent();

-- Becoming urgent on the quick list, not add_to_list merging "for tonight" into a line that already was.
create trigger list_items_enqueue_urgent_update after update of urgency, list on public.list_items
  for each row when (new.list = 'quick' and new.urgency = 'tonight' and new.checked_at is null
                     and new.urgent_by is not null and (old.list <> 'quick' or old.urgency <> 'tonight'))
  execute function public.list_items_enqueue_urgent();

-- Split so each WHEN can read old.urgency on an update: the line was open, urgent and on the quick list, and now isn't.
create trigger list_items_call_off_urgent_update after update of urgency, list, checked_at on public.list_items
  for each row when (old.list = 'quick' and old.urgency = 'tonight' and old.checked_at is null and old.urgent_by is not null
                     and not (new.list = 'quick' and new.urgency = 'tonight' and new.checked_at is null))
  execute function public.list_items_call_off_urgent();

create trigger list_items_call_off_urgent_delete after delete on public.list_items
  for each row when (old.list = 'quick' and old.urgency = 'tonight' and old.checked_at is null and old.urgent_by is not null)
  execute function public.list_items_call_off_urgent();

-- Tonight poll -----------------------------------------------------------------------------------------------------------------

create function public.polls_enqueue_tonight_poll()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  tz text := public.household_time_zone(new.household_id);
  starter public.members;
  tapped_by uuid := public.my_member_id(new.household_id);
begin
  if public.household_notification_preset(new.household_id) <> 'engaged' then
    return null;
  end if;
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
    and not exists (select 1 from public.night_attendance a
                    where a.plan_night_id = night.id and a.member_id = m.id and not a.expected)
    and held.not_before < new.closes_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

create function public.polls_call_off_tonight_poll()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.push_outbox
  where kind = 'tonight_poll' and night_id = new.night_id and sent_at is null and failed is null;
  return null;
end;
$$;

revoke execute on function public.polls_enqueue_tonight_poll() from public, anon, authenticated;
revoke execute on function public.polls_call_off_tonight_poll() from public, anon, authenticated;

create trigger polls_enqueue_tonight_poll after insert on public.polls
  for each row execute function public.polls_enqueue_tonight_poll();

create trigger polls_call_off_tonight_poll after update of closes_at on public.polls
  for each row when (new.closes_at < old.closes_at)
  execute function public.polls_call_off_tonight_poll();

-- Your idea made the plan --------------------------------------------------------------------------------------------------------

create function public.plans_enqueue_request_planned()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.household_time_zone(new.household_id);
  approver uuid := public.my_member_id(new.household_id);
begin
  if public.household_notification_preset(new.household_id) <> 'engaged' then
    return null;
  end if;

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

revoke execute on function public.plans_enqueue_request_planned() from public, anon, authenticated;

create trigger plans_enqueue_request_planned after update of approved_at on public.plans
  for each row when (old.approved_at is null and new.approved_at is not null)
  execute function public.plans_enqueue_request_planned();

-- Retention -----------------------------------------------------------------------------------------------------------------------

-- As in 20261102110000_tonight_poll.sql, plus: a kid whose consent was withdrawn takes along the pushes about what they did
-- themselves (a poll they started, something they marked for tonight), sent ones too, and stops being named on a line.
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
  -- The pushes about a poll they started or something they marked for tonight were about what they did themselves, sent
  -- ones too; and a line stops saying they marked it.
  delete from public.push_outbox
  where kind in ('tonight_poll', 'urgent_item') and about_member_id = any (withdrawn);
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

-- Sending -----------------------------------------------------------------------------------------------------------------------

-- As car 2's, plus: "Your idea made Friday" stands only while the idea is still planned on that night, so one sent back to
-- Someday or moved to another night before it goes waits, and the dinner-time check ends it.
create function public.push_outbox_stands(row_kind text, row_claim uuid, row_request uuid, row_night uuid)
returns boolean
language sql stable set search_path = ''
as $$
  select case row_kind
    when 'claim' then exists (
      select 1 from public.night_claims c join public.plan_nights n on n.id = c.night_id
      where c.id = row_claim and c.released_at is null and n.quick_pick is null
        and public.can_cook_night(c.member_id, c.night_id)
        and not exists (select 1 from public.meal_logs l where l.night_id = n.id))
    when 'request_planned' then exists (
      select 1 from public.requests r
      where r.id = row_request and r.status = 'planned' and r.planned_night_id = row_night)
    else true
  end;
$$;

revoke execute on function public.push_outbox_stands(text, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.kick_push_sender()
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  function_url text;
  cron_secret text;
begin
  if not exists (
    select 1 from public.push_outbox o
    where o.sent_at is null and o.failed is null and o.not_before <= now() and o.attempts < 5
      and (o.claimed_until is null or o.claimed_until < now())
      and public.push_outbox_stands(o.kind, o.claim_id, o.request_id, o.night_id)
  ) then
    return false;
  end if;

  select decrypted_secret into function_url from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name = 'push_cron_secret';
  if coalesce(function_url, '') = '' or coalesce(cron_secret, '') = '' then
    return false;
  end if;

  perform net.http_post(
    url := function_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cron_secret),
    timeout_milliseconds := 55000
  );
  return true;
end;
$$;

-- As car 2's, with an idea's night following its dinner time too, and an urgent item following tonight's.
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

  return query
  with due as (
    select o.id from public.push_outbox o
    where o.sent_at is null and o.failed is null and o.not_before <= now() and o.attempts < 5
      and (o.claimed_until is null or o.claimed_until < now())
      and public.push_outbox_stands(o.kind, o.claim_id, o.request_id, o.night_id)
    order by o.not_before
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

-- Nothing calls car 2's two-argument version any more.
drop function public.push_outbox_stands(text, uuid);
