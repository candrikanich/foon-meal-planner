-- Opt-in account email (#48, PR C): the weekly plan email and founding-family updates. Plan:
-- planning/m4-48-email-plan.md, with Chris's answers of 2026-11-11.
--
-- 1. email_preferences: one row per account, both off by default. Personal: only that account reads it (not the rest of
--    the household), and it's written only through set_email_preference. Adults only: a kid, or an account in no
--    household, can't turn one on. Turning one on logs an agreement to its wording (weekly-plan-email-v1,
--    founding-updates-v1) in account_agreements, and the row keeps which wording and when; turning one off needs no
--    agreement. While account_email_enabled is off, nothing can be turned on (the app doesn't show the switches).
-- 2. The row goes when the account does (cascade), and when the account stops being an adult in its household: removed,
--    unlinked (Delete my account unlinks first), turned into a kid, or the household erased (erase_household and
--    delete_kid delete members). Keyed by account only, so no household_id and nothing for erase_household to list.
-- 3. Turning one off (in the app, or with an email's unsubscribe link through the account-email function) drops that
--    kind's rows still waiting in the outbox (opted_out), so nothing goes after someone said stop.
-- 4. Weekly plan email: the first time a week is approved (approve_plan, or an older app's direct write), each adult in
--    the household who opted in gets one, 10 minutes later so a quick swap after approving makes it in. Once per plan per
--    person (dedupe plan:user): un-approving and approving the same week again doesn't send it again. Not for a week
--    that's over. The row holds ids only; the function reads the dinners when it sends (account_email_weekly_plan).
-- 5. Founding-family updates: Chris writes one (subject and body), and the account-email function, called by the
--    "Founding update" GitHub Action with its own secret, queues it for every adult who opted in
--    (queue_founding_update). The same text queued twice queues nothing new. The outbox's 200-an-hour cap paces them.
--    The confirmed waitlist isn't included: its signup said "tell you when Foon opens", not news (see the PR).
-- 6. email_outbox.kind gains weekly_plan and founding_update (the full list, with the subscription kinds of
--    20261123000000), and account_agreements takes the two new kinds and the opt_in context.

-- Kinds -----------------------------------------------------------------------------------------------------------------

alter table public.email_outbox drop constraint if exists email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check check (kind in (
  'welcome', 'subscription_started', 'subscription_ending', 'subscription_ended', 'subscription_renewed',
  'subscription_billing_problem', 'subscription_renewal_on', 'subscription_plan_changed', 'subscription_refunded',
  'weekly_plan', 'founding_update'));

-- The wordings ----------------------------------------------------------------------------------------------------------

-- Not in force (effective_at null), like a wording waiting for its turn-on: an opt-in may name any registered version of
-- its kind, as accept_agreements does, and #48 PR D puts them in force with the privacy policy that lists these emails.
insert into public.agreement_versions (version, kind, ordinal, summary) values
  ('weekly-plan-email-v1', 'weekly_plan_email', 1,
   'Foon emails you the week''s dinners when a week is approved, at the email Apple gave for your account, until you turn it off in Foon or with the link in any of them.'),
  ('founding-updates-v1', 'founding_updates', 1,
   'Foon emails you news for founding families now and then, at the email Apple gave for your account, until you turn it off in Foon or unsubscribe with the link in any of them.');

alter table public.account_agreements drop constraint if exists account_agreements_kind_check;
alter table public.account_agreements add constraint account_agreements_kind_check
  check (kind in ('terms', 'privacy', 'weekly_plan_email', 'founding_updates'));
alter table public.account_agreements drop constraint if exists account_agreements_context_check;
alter table public.account_agreements add constraint account_agreements_context_check
  check (context in ('create_household', 'join', 'next_launch', 'changed', 'opt_in'));

-- Preferences -----------------------------------------------------------------------------------------------------------

create table public.email_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  weekly_plan boolean not null default false,
  -- The wording agreed to when it was last turned on, and when; cleared when it's turned off.
  weekly_plan_version text,
  weekly_plan_agreed_at timestamptz,
  founding_updates boolean not null default false,
  founding_updates_version text,
  founding_updates_agreed_at timestamptz,
  updated_at timestamptz not null default now(),
  check (weekly_plan = (weekly_plan_version is not null)),
  check (founding_updates = (founding_updates_version is not null))
);

alter table public.email_preferences enable row level security;
revoke all on table public.email_preferences from public, anon, authenticated;
grant select on public.email_preferences to authenticated;

-- Account-level and personal: nobody else in the household reads it.
create policy "people read their own email preferences" on public.email_preferences
  for select to authenticated
  using (user_id = (select auth.uid()) and public.session_is_active());

-- The household the account is an adult in, or null: a kid (anywhere), someone removed, or an account in no household.
create function public.email_opt_in_household(account uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select m.household_id from public.members m
   where m.user_id = account and m.age_group = 'adult' and m.status <> 'removed'
     and not exists (select 1 from public.members k where k.user_id = account and k.age_group = 'kid')
   limit 1;
$$;

revoke execute on function public.email_opt_in_household(uuid) from public, anon, authenticated;

-- What the app shows: both switches, whether this account may turn one on, and whether Foon sends email at all yet.
create function public.my_email_preferences()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  return jsonb_build_object(
    'weekly_plan', coalesce((select p.weekly_plan from public.email_preferences p where p.user_id = caller), false),
    'founding_updates', coalesce((select p.founding_updates from public.email_preferences p where p.user_id = caller),
                                 false),
    'can_opt_in', public.email_opt_in_household(caller) is not null,
    'available', coalesce((select c.account_email_enabled from public.app_config c), false));
end;
$$;

revoke execute on function public.my_email_preferences() from public, anon;
grant execute on function public.my_email_preferences() to authenticated;

-- Turns one of the caller's emails on or off, and answers as my_email_preferences. On needs the wording the app showed
-- (a registered version of that kind), and logs the agreement; off needs nothing, and works for anyone.
--   28000 not signed in; 22023 an unknown kind or wording; 42501 not an adult in a household (hint adults_only);
--   55000 email isn't on yet (hint email_off).
create function public.set_email_preference(email_kind text, enabled boolean, wording text default null,
                                            client text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  agreement public.agreement_kind;
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  agreement := case email_kind
    when 'weekly_plan' then 'weekly_plan_email'::public.agreement_kind
    when 'founding_updates' then 'founding_updates'::public.agreement_kind
  end;
  if agreement is null or enabled is null then
    raise exception 'email_kind is weekly_plan or founding_updates, and enabled is true or false' using errcode = '22023';
  end if;
  if char_length(client) > 40 then
    raise exception 'client is at most 40 characters' using errcode = '22023';
  end if;

  if enabled then
    if public.email_opt_in_household(caller) is null then
      raise exception 'only adults in a household get email' using errcode = '42501', hint = 'adults_only';
    end if;
    if not coalesce((select c.account_email_enabled from public.app_config c), false) then
      raise exception 'Foon doesn''t send email yet' using errcode = '55000', hint = 'email_off';
    end if;
    if wording is null
       or not exists (select 1 from public.agreement_versions v where v.version = wording and v.kind = agreement) then
      raise exception 'unknown wording' using errcode = '22023';
    end if;
    insert into public.account_agreements (user_id, kind, text_version, context, client)
    values (caller, agreement, wording, 'opt_in', client)
    on conflict (user_id, text_version) do nothing;
  end if;

  if enabled then
    insert into public.email_preferences (user_id) values (caller) on conflict (user_id) do nothing;
  end if;
  -- Turning one on again records the latest agreement; turning off what was never on writes nothing.
  if email_kind = 'weekly_plan' then
    update public.email_preferences
       set weekly_plan = enabled,
           weekly_plan_version = case when enabled then wording end,
           weekly_plan_agreed_at = case when enabled then now() end,
           updated_at = now()
     where user_id = caller;
  else
    update public.email_preferences
       set founding_updates = enabled,
           founding_updates_version = case when enabled then wording end,
           founding_updates_agreed_at = case when enabled then now() end,
           updated_at = now()
     where user_id = caller;
  end if;
  return public.my_email_preferences();
end;
$$;

revoke execute on function public.set_email_preference(text, boolean, text, text) from public, anon;
grant execute on function public.set_email_preference(text, boolean, text, text) to authenticated;

-- An email's unsubscribe link (the account-email function checks its signature first). Turning off what's already off,
-- or an account that's gone, does nothing: that's still what they asked for.
create function public.email_unsubscribe(account uuid, email_kind text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if email_kind = 'weekly_plan' then
    update public.email_preferences
       set weekly_plan = false, weekly_plan_version = null, weekly_plan_agreed_at = null, updated_at = now()
     where user_id = account and weekly_plan;
  elsif email_kind = 'founding_updates' then
    update public.email_preferences
       set founding_updates = false, founding_updates_version = null, founding_updates_agreed_at = null,
           updated_at = now()
     where user_id = account and founding_updates;
  else
    raise exception 'email_kind is weekly_plan or founding_updates' using errcode = '22023';
  end if;
end;
$$;

revoke execute on function public.email_unsubscribe(uuid, text) from public, anon, authenticated;
grant execute on function public.email_unsubscribe(uuid, text) to service_role;

-- Off means nothing more goes: that kind's waiting rows are dropped. A row already handed to the function (reserved) may
-- still go out in that run. A deleted row needs nothing here: the account's rows go with the account, and the claim drops
-- a row whose recipient isn't an adult in the household any more (not_adult).
create function public.email_preferences_drop_waiting()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  dropped text[] := array[]::text[];
begin
  if old.weekly_plan and not new.weekly_plan then
    dropped := array_append(dropped, 'weekly_plan');
  end if;
  if old.founding_updates and not new.founding_updates then
    dropped := array_append(dropped, 'founding_update');
  end if;
  if cardinality(dropped) > 0 then
    update public.email_outbox o set failed_at = now(), reserved_at = null, last_error_code = 'opted_out'
     where o.user_id = new.user_id and o.kind = any (dropped) and o.sent_at is null and o.failed_at is null;
  end if;
  return null;
end;
$$;

revoke execute on function public.email_preferences_drop_waiting() from public, anon, authenticated;

create trigger email_preferences_drop_waiting
  after update on public.email_preferences
  for each row execute function public.email_preferences_drop_waiting();

-- An account that stops being an adult in its household loses its preferences (and so its waiting opt-in rows).
create function public.members_forget_email_preferences()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.user_id is not null and (
       tg_op = 'DELETE' or new.user_id is distinct from old.user_id or new.status = 'removed'
       or new.age_group <> 'adult') then
    delete from public.email_preferences where user_id = old.user_id;
  end if;
  return null;
end;
$$;

revoke execute on function public.members_forget_email_preferences() from public, anon, authenticated;

create trigger members_forget_email_preferences
  after update of user_id, status, age_group or delete on public.members
  for each row execute function public.members_forget_email_preferences();

-- Weekly plan email ------------------------------------------------------------------------------------------------------

create function public.plans_queue_weekly_plan_email()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.week_start + 6 < (now() at time zone public.household_time_zone(new.household_id))::date then
    return null;
  end if;
  perform public.enqueue_account_email(new.household_id, m.user_id, 'weekly_plan',
            new.id::text || ':' || m.user_id::text,
            jsonb_build_object('plan_id', new.id, 'user_id', m.user_id),
            now() + interval '10 minutes')
     from public.members m
     join public.email_preferences p on p.user_id = m.user_id and p.weekly_plan
    where m.household_id = new.household_id and public.email_opt_in_household(m.user_id) = new.household_id;
  return null;
end;
$$;

revoke execute on function public.plans_queue_weekly_plan_email() from public, anon, authenticated;

create trigger plans_queue_weekly_plan_email after update of approved_at on public.plans
  for each row when (old.approved_at is null and new.approved_at is not null)
  execute function public.plans_queue_weekly_plan_email();

-- What the weekly plan email says, read when it's sent so a swap since approving shows: each night's date and its dish
-- (the household's own name for it), quick pick, or away. Null when the plan is gone or no longer approved (the email
-- is then given up). Never who's home, who cooks, or anyone's allergies.
create function public.account_email_weekly_plan(target_plan uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'week_start', p.week_start,
    'nights', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date', n.date, 'meal', m.name, 'quick_pick', n.quick_pick,
               'away', public.household_away_on(p.household_id, n.date))
             order by n.date)
        from public.plan_nights n
        left join public.meals m on m.id = n.meal_id and m.household_id = n.household_id
       where n.plan_id = p.id), '[]'::jsonb))
    from public.plans p
   where p.id = target_plan and p.approved_at is not null;
$$;

revoke execute on function public.account_email_weekly_plan(uuid) from public, anon, authenticated;
grant execute on function public.account_email_weekly_plan(uuid) to service_role;

-- Founding-family updates ------------------------------------------------------------------------------------------------

-- What Chris sent: no personal data, so kept as the record of what went out. Server only.
create table public.founding_updates (
  id uuid primary key default gen_random_uuid(),
  subject text not null check (char_length(btrim(subject)) between 1 and 150),
  body text not null check (char_length(btrim(body)) between 1 and 20000),
  -- The same update twice is one update: re-running the Action queues nothing new.
  content_hash text not null unique,
  created_at timestamptz not null default now()
);

alter table public.founding_updates enable row level security;
revoke all on table public.founding_updates from public, anon, authenticated;

-- How many adults would get an update now (the Action's preview says).
create function public.founding_update_audience()
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int from public.email_preferences p
   where p.founding_updates and public.email_opt_in_household(p.user_id) is not null;
$$;

revoke execute on function public.founding_update_audience() from public, anon, authenticated;
grant execute on function public.founding_update_audience() to service_role;

-- Queues an update for every adult who opted in. Returns {update_id, queued, repeat}: repeat when this exact text was
-- queued before (then nobody new is added, so the Action can't send it twice). 55000 while email is off, since rows
-- queued then would only go stale.
create function public.queue_founding_update(update_subject text, update_body text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  hash text := md5(btrim(coalesce(update_subject, '')) || E'\n' || btrim(coalesce(update_body, '')));
  update_id uuid;
  queued int;
begin
  if not coalesce((select c.account_email_enabled from public.app_config c), false) then
    raise exception 'account email is off' using errcode = '55000', hint = 'email_off';
  end if;
  select u.id into update_id from public.founding_updates u where u.content_hash = hash;
  if update_id is not null then
    return jsonb_build_object('update_id', update_id, 'queued', 0, 'repeat', true);
  end if;
  insert into public.founding_updates (subject, body, content_hash)
  values (btrim(update_subject), btrim(update_body), hash)
  returning id into update_id;

  with audience as (
    select p.user_id, public.email_opt_in_household(p.user_id) as household_id
      from public.email_preferences p
     where p.founding_updates
  ), inserted as (
    insert into public.email_outbox (household_id, user_id, kind, dedupe_key, payload)
    select a.household_id, a.user_id, 'founding_update', update_id::text || ':' || a.user_id::text,
           jsonb_build_object('update_id', update_id, 'user_id', a.user_id)
      from audience a
     where a.household_id is not null
    on conflict (kind, dedupe_key) do nothing
    returning 1
  )
  select count(*)::int into queued from inserted;
  return jsonb_build_object('update_id', update_id, 'queued', queued, 'repeat', false);
end;
$$;

revoke execute on function public.queue_founding_update(text, text) from public, anon, authenticated;
grant execute on function public.queue_founding_update(text, text) to service_role;

create function public.account_email_founding_update(target uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('subject', u.subject, 'body', u.body) from public.founding_updates u where u.id = target;
$$;

revoke execute on function public.account_email_founding_update(uuid) from public, anon, authenticated;
grant execute on function public.account_email_founding_update(uuid) to service_role;
