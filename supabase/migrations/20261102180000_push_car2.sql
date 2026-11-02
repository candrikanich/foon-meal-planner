-- Server push, car 2 (#40 part 2): "Ben won't be home tonight." and "Ben will cook Thursday." reach the household's planners.
-- 1. Won't be home: someone says Not home on the day-of check-in (night_attendance goes to expected = false with
--    checked_in_at set, the same rows the This Week note reads). Planners with a device hear, except whoever said it (and
--    whoever tapped it, passing the phone). Only where the check-in exists (Balanced and Engaged), not on an away night, not
--    once dinner's logged, and at most once a person a night, ever: a no, back home, and no again doesn't send twice.
--    It's news until dinner: a row not sent by the night's dinner time is given up as stale. Taking the no back, or a
--    planner's later write to that attendance (which wipes checked_in_at), calls off a row not sent yet.
-- 2. Will cook: a claim made on a night still ahead, not an away night, on Balanced or Engaged. Planners with a device hear,
--    except whoever entered it (and the cook). Once a claim. Taken back before it's sent, it's called off, and the cook
--    saying Not home calls it off too. It goes only if it still stands when it's due (not taken back, the cook can cook,
--    not a quick pick, dinner not logged); otherwise it waits, and goes if the claim stands again before dinner.
--    It's news until that night's dinner too. The words say the weekday, never "tonight" or "tomorrow", since quiet hours
--    can hold it.
-- 3. args holds the first name and nothing else; the words are built in send-push from the kind and the name. Never a dish.
-- 4. push_outbox gains expires_at (general: past it, a row not sent is stale), about_member_id (who the news is about, so
--    once-only and call-off can find it) and claim_id. claim_push_outbox also hands over the night and its date, and args.
--    Rows about a night are also given up once that night's dinner time has passed as it is now, so moving dinner earlier
--    after a row is queued still ends it at dinner.

-- Kinds -----------------------------------------------------------------------------------------------------------------------

alter table public.push_outbox drop constraint push_outbox_kind_check;
alter table public.push_outbox add constraint push_outbox_kind_check check (kind in (
  'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
  'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store',
  'not_home'));

alter table public.notification_log drop constraint notification_log_type_check;
alter table public.notification_log add constraint notification_log_type_check check (type in (
  'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
  'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store',
  'not_home'));

-- Outbox columns --------------------------------------------------------------------------------------------------------------

alter table public.push_outbox
  add column expires_at timestamptz,
  add column about_member_id uuid,
  add column claim_id uuid references public.night_claims (id) on delete cascade,
  add constraint push_outbox_about_member_fkey foreign key (about_member_id, household_id)
    references public.members (id, household_id) on delete cascade;

create index push_outbox_about_idx on public.push_outbox (night_id, about_member_id, kind);
create index push_outbox_claim_idx on public.push_outbox (claim_id);
create index push_outbox_about_member_idx on public.push_outbox (about_member_id);

-- Someone removed, leaving, or unlinked also takes along what was waiting about them, so their name doesn't go out after.
create or replace function public.members_drop_push_devices()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.push_devices where member_id = new.id;
  delete from public.push_outbox where member_id = new.id or about_member_id = new.id;
  return null;
end;
$$;

-- Helpers ---------------------------------------------------------------------------------------------------------------------

-- The household's preset, as the app reads it: missing or unknown is Balanced.
create function public.household_notification_preset(target_household uuid)
returns text
language sql stable set search_path = ''
as $$
  select case when settings ->> 'notification_preset' in ('light', 'balanced', 'engaged')
              then settings ->> 'notification_preset' else 'balanced' end
  from public.households where id = target_household;
$$;

-- When a night's dinner is, on the household's clock: the night's own time, else the household's, else 6pm.
create function public.night_dinner_at(target_night uuid)
returns timestamptz
language sql stable set search_path = ''
as $$
  select (n.date + coalesce(
            n.dinner_time,
            case when h.settings ->> 'dinner_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
                 then (h.settings ->> 'dinner_time')::time end,
            time '18:00'))
         at time zone public.household_time_zone(n.household_id)
  from public.plan_nights n join public.households h on h.id = n.household_id
  where n.id = target_night;
$$;

revoke execute on function public.household_notification_preset(uuid) from public, anon, authenticated;
revoke execute on function public.night_dinner_at(uuid) from public, anon, authenticated;

-- Won't be home ---------------------------------------------------------------------------------------------------------------

create function public.night_attendance_enqueue_not_home()
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
  if public.household_notification_preset(new.household_id) = 'light' then
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
    and held.not_before < dinner_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

revoke execute on function public.night_attendance_enqueue_not_home() from public, anon, authenticated;

create trigger night_attendance_enqueue_not_home after insert or update of expected, checked_in_at
  on public.night_attendance
  for each row execute function public.night_attendance_enqueue_not_home();

-- Will cook -------------------------------------------------------------------------------------------------------------------

create function public.night_claims_enqueue_claim()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  tz text := public.household_time_zone(new.household_id);
  dinner_at timestamptz;
  cook public.members;
begin
  if public.household_notification_preset(new.household_id) = 'light' then
    return null;
  end if;

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
    and held.not_before < dinner_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

create function public.night_claims_call_off_claim()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.push_outbox where claim_id = new.id and sent_at is null and failed is null;
  return null;
end;
$$;

revoke execute on function public.night_claims_enqueue_claim() from public, anon, authenticated;
revoke execute on function public.night_claims_call_off_claim() from public, anon, authenticated;

create trigger night_claims_enqueue_claim after insert on public.night_claims
  for each row when (new.released_at is null)
  execute function public.night_claims_enqueue_claim();

create trigger night_claims_call_off_claim after update of released_at on public.night_claims
  for each row when (old.released_at is null and new.released_at is not null)
  execute function public.night_claims_call_off_claim();

-- Sending (service role only) -------------------------------------------------------------------------------------------------

-- Whether a row's news is still true as things are now. A claim that doesn't stand (taken back, the cook out or gone, the
-- night a quick pick, or dinner logged) isn't sent, but it isn't given up either: it can stand again, and the dinner-time
-- stale check ends it otherwise.
create function public.push_outbox_stands(row_kind text, row_claim uuid)
returns boolean
language sql stable set search_path = ''
as $$
  select row_kind <> 'claim' or exists (
    select 1 from public.night_claims c join public.plan_nights n on n.id = c.night_id
    where c.id = row_claim and c.released_at is null and n.quick_pick is null
      and public.can_cook_night(c.member_id, c.night_id)
      and not exists (select 1 from public.meal_logs l where l.night_id = n.id));
$$;

revoke execute on function public.push_outbox_stands(text, uuid) from public, anon, authenticated;

-- As car 1's, but it only pokes for a row that still stands, so a claim waiting on a quick pick doesn't wake send-push
-- every minute until dinner.
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
      and public.push_outbox_stands(o.kind, o.claim_id)
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

-- As car 1's, plus: a row past its expires_at, or about a night whose dinner time has passed, is given up as stale too; a
-- row that doesn't stand waits; and each row comes with its night, the night's date, and its args, for the words and the
-- tap.
drop function public.claim_push_outbox(int);

create function public.claim_push_outbox(batch_size int)
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
         or (o.kind in ('not_home', 'claim') and public.night_dinner_at(o.night_id) <= now()));

  return query
  with due as (
    select o.id from public.push_outbox o
    where o.sent_at is null and o.failed is null and o.not_before <= now() and o.attempts < 5
      and (o.claimed_until is null or o.claimed_until < now())
      and public.push_outbox_stands(o.kind, o.claim_id)
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

revoke execute on function public.claim_push_outbox(int) from public, anon, authenticated;
grant execute on function public.claim_push_outbox(int) to service_role;
