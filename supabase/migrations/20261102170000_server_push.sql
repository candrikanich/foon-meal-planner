-- Server push, car 1 (#40 part 2): device tokens, an outbox, and Plan's set.
-- 1. push_devices: one row per APNs token, written only through register_push_device / unregister_push_device. A person
--    reads their own rows and nobody else's. A token follows whoever registered it last (a shared iPad changing hands).
--    Deleting an account, being removed, leaving, and a profile being unlinked all take the rows with them.
-- 2. push_outbox: what's waiting to go, written only by security definer code at the moment the event happens, read only
--    by the send-push Edge Function with the service role. No client sees it. `args` holds only what fixed words need.
-- 3. push_not_before: quiet hours on the household's clock, the same as on-device reminders: 9pm to 7am for everyone,
--    and 8am to 3pm on weekdays for kids. A push held by them goes when they end.
-- 4. Plan's set: the first time a week is approved, by approve_plan or an older app's direct write, everyone in the family
--    with a device hears about it, except whoever approved it. Not for a week that's over or all away, and only once a
--    plan, so un-approving and approving again can't send it twice.
-- 5. Every minute pg_cron pokes send-push through pg_net, but only when something's due and only when Vault holds both
--    push_function_url and push_cron_secret. Without them (local, a staging not set up yet) nothing is sent.

create extension if not exists pg_net with schema extensions;

-- Devices -----------------------------------------------------------------------------------------------------------------

create table public.push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  member_id uuid not null,
  household_id uuid not null,
  token text not null unique check (token ~ '^[0-9a-f]{64,200}$'),
  environment text not null check (environment in ('sandbox', 'production')),
  -- The sign-in that registered it. Once that's gone (signed out, "Sign out everywhere", revoked) the device is forgotten
  -- before anything is sent, whether or not the phone ever got to say so.
  session_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Cascade: erasing a household deletes its members, and a device is nothing without its person.
  constraint push_devices_member_fkey foreign key (member_id, household_id)
    references public.members (id, household_id) on delete cascade
);

create index push_devices_member_idx on public.push_devices (member_id);
create index push_devices_user_idx on public.push_devices (user_id, updated_at);

revoke all on public.push_devices from anon, authenticated;
grant select on public.push_devices to authenticated;

alter table public.push_devices enable row level security;

create policy "people read their own devices" on public.push_devices
  for select to authenticated
  using (user_id = (select auth.uid()) and public.session_is_active());

-- The caller's own profile, in whichever household they're in (an account is in at most one).
create function public.register_push_device(device_token text, device_environment text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me public.members;
  normalized text := lower(btrim(device_token));
begin
  if normalized is null or normalized !~ '^[0-9a-f]{64,200}$' then
    raise exception 'a device token is 64 to 200 hex characters' using errcode = '22023';
  end if;
  if device_environment is null or device_environment not in ('sandbox', 'production') then
    raise exception 'environment is sandbox or production' using errcode = '22023';
  end if;

  select * into me from public.members
  where user_id = (select auth.uid()) and status <> 'removed' and public.session_is_active();
  if me.id is null then
    raise exception 'not in a household' using errcode = '42501';
  end if;

  insert into public.push_devices (user_id, member_id, household_id, token, environment, session_id)
  values (me.user_id, me.id, me.household_id, normalized, device_environment,
          nullif((select auth.jwt()) ->> 'session_id', '')::uuid)
  on conflict (token) do update
    set user_id = excluded.user_id, member_id = excluded.member_id, household_id = excluded.household_id,
        environment = excluded.environment, session_id = excluded.session_id, updated_at = now();

  -- Reinstalls leave old tokens behind until Apple says they're gone. Ten is more phones, iPads and Macs than anyone has.
  delete from public.push_devices
  where user_id = me.user_id
    and id not in (select id from public.push_devices where user_id = me.user_id order by updated_at desc limit 10);
end;
$$;

-- Signing out and turning reminders off. By token alone: whoever holds a token can already take it over by registering it,
-- and the next person on a phone whose last sign-out had no signal needs to clear what was left under someone else.
create function public.unregister_push_device(device_token text)
returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_devices
  where token = lower(btrim(device_token));
$$;

revoke execute on function public.register_push_device(text, text) from public, anon;
grant execute on function public.register_push_device(text, text) to authenticated;
revoke execute on function public.unregister_push_device(text) from public, anon;
grant execute on function public.unregister_push_device(text) to authenticated;

-- Outbox ------------------------------------------------------------------------------------------------------------------

create table public.push_outbox (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  member_id uuid not null,
  -- The same list as notification_log's, so what's sent can be logged.
  kind text not null check (kind in (
    'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
    'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store')),
  night_id uuid references public.plan_nights (id) on delete set null,
  plan_id uuid references public.plans (id) on delete cascade,
  args jsonb not null default '{}' check (jsonb_typeof(args) = 'object'),
  not_before timestamptz not null,
  created_at timestamptz not null default now(),
  -- Set while send-push has a row, so a second run can't send it again before the first finishes.
  claimed_until timestamptz,
  attempts int not null default 0,
  sent_at timestamptz,
  failed text,
  constraint push_outbox_member_fkey foreign key (member_id, household_id)
    references public.members (id, household_id) on delete cascade
);

create index push_outbox_due_idx on public.push_outbox (not_before) where sent_at is null and failed is null;
create index push_outbox_member_idx on public.push_outbox (member_id);
create index push_outbox_plan_idx on public.push_outbox (plan_id, kind);
create index push_outbox_created_idx on public.push_outbox (created_at);

revoke all on public.push_outbox from anon, authenticated;
alter table public.push_outbox enable row level security;

-- The APNs provider token, shared between send-push runs: Apple refuses a new one more often than every 20 minutes.
create table public.push_provider_tokens (
  key_id text primary key,
  token text not null,
  issued_at timestamptz not null
);

revoke all on public.push_provider_tokens from anon, authenticated;
alter table public.push_provider_tokens enable row level security;

-- Someone removed, leaving, or unlinked from a profile takes their devices and their outbox rows along, sent ones too: a
-- sent row is as much a record of what they were sent as their notification_log rows, which go the same way.
create function public.members_drop_push_devices()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.push_devices where member_id = new.id;
  delete from public.push_outbox where member_id = new.id;
  return null;
end;
$$;

revoke execute on function public.members_drop_push_devices() from public, anon, authenticated;

create trigger members_drop_push_devices after update of status, user_id on public.members
  for each row when ((new.status = 'removed' and old.status <> 'removed') or new.user_id is distinct from old.user_id)
  execute function public.members_drop_push_devices();

-- Quiet hours ---------------------------------------------------------------------------------------------------------------

-- The first instant from `instant` on that isn't in someone's quiet hours, on the clock of `tz`. It doesn't know about school
-- holidays, like the device.
create function public.push_not_before(tz text, is_kid boolean, instant timestamptz)
returns timestamptz
language sql stable set search_path = ''
as $$
  select case
    when local_time::time >= time '21:00' then ((local_time::date + 1) + time '07:00') at time zone tz
    when local_time::time < time '07:00' then (local_time::date + time '07:00') at time zone tz
    when is_kid and extract(isodow from local_time) <= 5
         and local_time::time >= time '08:00' and local_time::time < time '15:00'
      then (local_time::date + time '15:00') at time zone tz
    else instant
  end
  from (select instant at time zone tz as local_time) as clock;
$$;

-- The household's clock: its saved zone, else the server's New York fallback, like the after-dinner card.
create function public.household_time_zone(target_household uuid)
returns text
language sql stable set search_path = ''
as $$
  select coalesce(
    (select public.valid_time_zone(settings ->> 'time_zone') from public.households where id = target_household),
    'America/New_York');
$$;

revoke execute on function public.push_not_before(text, boolean, timestamptz) from public, anon;
grant execute on function public.push_not_before(text, boolean, timestamptz) to authenticated, service_role;
revoke execute on function public.household_time_zone(uuid) from public, anon, authenticated;

-- Plan's set ----------------------------------------------------------------------------------------------------------------

create function public.plans_enqueue_plan_set()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.household_time_zone(new.household_id);
  approver uuid := public.my_member_id(new.household_id);
begin
  if new.week_start + 6 < (now() at time zone tz)::date then
    return null;
  end if;
  if not exists (
    select 1 from generate_series(new.week_start, new.week_start + 6, interval '1 day') as night
    where not public.household_away_on(new.household_id, night::date)
  ) then
    return null;
  end if;
  if exists (select 1 from public.push_outbox where plan_id = new.id and kind = 'plan_set') then
    return null;
  end if;

  insert into public.push_outbox (household_id, member_id, kind, plan_id, not_before)
  select m.household_id, m.id, 'plan_set', new.id, public.push_not_before(tz, m.age_group = 'kid', now())
  from public.members m
  where m.household_id = new.household_id and m.status <> 'removed' and m.id is distinct from approver
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

revoke execute on function public.plans_enqueue_plan_set() from public, anon, authenticated;

create trigger plans_enqueue_plan_set after update of approved_at on public.plans
  for each row when (old.approved_at is null and new.approved_at is not null)
  execute function public.plans_enqueue_plan_set();

-- Sending (service role only) -------------------------------------------------------------------------------------------------

-- Forgets devices whose sign-in has ended, then hands send-push up to `batch_size` due rows with their person's devices,
-- and holds them for two minutes. A row more than a
-- day late (the sender was down) isn't news any more and is given up.
create function public.claim_push_outbox(batch_size int)
returns table (id uuid, kind text, week_start date, attempts int, devices jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  delete from public.push_devices d
  where d.session_id is not null
    and not exists (select 1 from auth.sessions s
                    where s.id = d.session_id and (s.not_after is null or s.not_after > now()));

  update public.push_outbox o set failed = 'stale'
  where o.sent_at is null and o.failed is null and o.not_before < now() - interval '1 day';

  return query
  with due as (
    select o.id from public.push_outbox o
    where o.sent_at is null and o.failed is null and o.not_before <= now() and o.attempts < 5
      and (o.claimed_until is null or o.claimed_until < now())
    order by o.not_before
    limit greatest(batch_size, 0)
    for update skip locked
  ), claimed as (
    update public.push_outbox o
    set attempts = o.attempts + 1, claimed_until = now() + interval '2 minutes'
    from due where o.id = due.id
    returning o.*
  )
  select c.id, c.kind, p.week_start, c.attempts,
         coalesce((select jsonb_agg(jsonb_build_object('token', d.token, 'environment', d.environment))
                   from public.push_devices d where d.member_id = c.member_id), '[]'::jsonb)
  from claimed c left join public.plans p on p.id = c.plan_id;
end;
$$;

-- 'sent' marks it sent and logs it; 'retry' lets the next run have it, until it's had five goes; anything else is why it
-- failed for good.
create function public.complete_push_outbox(target uuid, outcome text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  pending public.push_outbox;
begin
  select * into pending from public.push_outbox where id = target;
  if pending.id is null or pending.sent_at is not null then
    return;
  end if;

  if outcome = 'sent' then
    -- The same lock record_notifications takes, so a household being erased finishes first and this finds no member.
    perform pg_advisory_xact_lock_shared(public.notification_log_lock(pending.household_id));
    update public.push_outbox set sent_at = now(), claimed_until = null, failed = null where id = target;
    insert into public.notification_log (id, household_id, member_id, type, channel, night_id, scheduled_for, sent_at)
    select gen_random_uuid(), pending.household_id, pending.member_id, pending.kind, 'push', pending.night_id,
           pending.not_before, now()
    from public.members m where m.id = pending.member_id and m.status <> 'removed';
  elsif outcome = 'retry' then
    update public.push_outbox
    -- Backs off (2, 4, 6, 8 minutes) so one bad stretch at Apple, or a full batch claimed again and again in one run,
    -- can't use up all five tries in seconds.
    set claimed_until = case when attempts < 5 then now() + attempts * interval '2 minutes' end,
        failed = case when attempts >= 5 then 'gave_up' end
    where id = target;
  else
    update public.push_outbox set claimed_until = null, failed = left(coalesce(outcome, 'unknown'), 40) where id = target;
  end if;
end;
$$;

-- Apple said these tokens are dead.
create function public.forget_push_devices(tokens text[])
returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_devices where token = any (tokens);
$$;

revoke execute on function public.claim_push_outbox(int) from public, anon, authenticated;
grant execute on function public.claim_push_outbox(int) to service_role;
revoke execute on function public.complete_push_outbox(uuid, text) from public, anon, authenticated;
grant execute on function public.complete_push_outbox(uuid, text) to service_role;
revoke execute on function public.forget_push_devices(text[]) from public, anon, authenticated;
grant execute on function public.forget_push_devices(text[]) to service_role;

-- Scheduling ------------------------------------------------------------------------------------------------------------------

-- Pokes send-push when something's due. Returns whether it did, for tests. Does nothing until Vault has both secrets.
create function public.kick_push_sender()
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

revoke execute on function public.kick_push_sender() from public, anon, authenticated;

-- Sent and failed rows are kept eight weeks, like the log.
create function public.prune_push_outbox()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_outbox where created_at < now() - interval '8 weeks';
$$;

revoke execute on function public.prune_push_outbox() from public, anon, authenticated;

select cron.schedule('send-push', '* * * * *', 'select public.kick_push_sender()');
select cron.schedule('prune-push-outbox', '29 3 * * *', 'select public.prune_push_outbox()');
