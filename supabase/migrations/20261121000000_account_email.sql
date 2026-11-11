-- Adult account email (#48, PR A): the owner's welcome, subscription notices, and what the account-email Edge Function
-- needs to send them. Deletion receipts are sent by delete-account itself (no row here: the account is gone after).
--
-- 1. email_outbox: what's waiting to go, written only by triggers at the moment the event happens, read and settled only
--    by the account-email function (service role). No client grant at all. A row holds ids and dates, never an address
--    or free text: the address is read from the recipient's Apple identity when the row is claimed
--    (verified_account_email), so nothing here goes stale or leaks one.
-- 2. app_config.account_email_enabled (off): rows queue, but nothing is claimed or sent until it's turned on. A row older
--    than 2 days that hasn't gone is dropped (marked stale) instead of sent, so turning it on later doesn't send a
--    family a welcome for a household they made weeks ago.
-- 3. Adults only: a row is sent only while its recipient is an adult in that household; otherwise it's dropped
--    (not_adult). Kids never get email.
-- 4. 200 sends an hour overall (sent or in flight), a cost and abuse ceiling like the consent and waitlist ones.
-- 5. Deleting a household deletes its rows (on delete cascade from households, which erase_household deletes last);
--    deleting an account deletes the rows addressed to it (cascade from auth.users). Rows are pruned after 30 days.

alter table public.app_config add column account_email_enabled boolean not null default false;

-- The outbox ----------------------------------------------------------------------------------------------------------

create table public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- A new kind (weekly_plan) is a new migration that replaces this check.
  kind text not null check (kind in ('welcome', 'subscription_started', 'subscription_ending', 'subscription_ended')),
  -- What makes the event one event (the household for a welcome, Apple's notification id for a subscription notice), so
  -- the same event can't queue twice.
  dedupe_key text not null,
  -- Ids and dates only.
  payload jsonb not null default '{}' check (jsonb_typeof(payload) = 'object'),
  not_before timestamptz not null default now(),
  -- Set while the function holds the row; a hold older than 10 minutes (the function died) lapses.
  reserved_at timestamptz,
  sent_at timestamptz,
  -- Set when the row is given up for good, with why in last_error_code.
  failed_at timestamptz,
  attempts int not null default 0,
  last_error_code text check (char_length(last_error_code) <= 40),
  created_at timestamptz not null default now(),
  unique (kind, dedupe_key)
);

create index email_outbox_due_idx on public.email_outbox (not_before) where sent_at is null and failed_at is null;
create index email_outbox_sent_idx on public.email_outbox (sent_at) where sent_at is not null;
create index email_outbox_household_idx on public.email_outbox (household_id);
create index email_outbox_user_idx on public.email_outbox (user_id);
create index email_outbox_created_idx on public.email_outbox (created_at);

revoke all on public.email_outbox from public, anon, authenticated;
alter table public.email_outbox enable row level security;

-- Queues one email; a repeat of the same event does nothing.
create function public.enqueue_account_email(target_household uuid, recipient uuid, email_kind text, dedupe text,
                                             details jsonb default '{}', send_after timestamptz default now())
returns void
language sql security definer set search_path = ''
as $$
  insert into public.email_outbox (household_id, user_id, kind, dedupe_key, payload, not_before)
  values (target_household, recipient, email_kind, dedupe, coalesce(details, '{}'), coalesce(send_after, now()))
  on conflict (kind, dedupe_key) do nothing;
$$;

revoke execute on function public.enqueue_account_email(uuid, uuid, text, text, jsonb, timestamptz)
  from public, anon, authenticated;

-- Welcome ---------------------------------------------------------------------------------------------------------------

-- The owner of a new household gets a welcome, unless it's a sample family (settings.sample, set when it's made):
-- "Start your real family" makes the real one, which gets it. A trigger rather than a change to create_household, so a
-- household made any way is covered.
create function public.queue_welcome_email()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.owner is not null and coalesce(new.settings -> 'sample', 'false'::jsonb) <> 'true'::jsonb then
    perform public.enqueue_account_email(new.id, new.owner, 'welcome', new.id::text, '{}');
  end if;
  return null;
end;
$$;

revoke execute on function public.queue_welcome_email() from public, anon, authenticated;

create trigger households_queue_welcome_email
  after insert on public.households
  for each row execute function public.queue_welcome_email();

-- Subscription notices --------------------------------------------------------------------------------------------------

-- apply_subscription_notification (20261107000000) records the notification in subscription_events, then writes the
-- subscription's row; this runs on that write and reads the notification it came from. Only these go out, to the
-- household's owner (Apple sends its own receipts, so renewals don't):
--   SUBSCRIBED (a first buy or a resubscribe)        subscription_started: product, whether it's the trial, its end
--   DID_CHANGE_RENEWAL_STATUS / AUTO_RENEW_DISABLED  subscription_ending: when access ends
--   EXPIRED                                          subscription_ended: when it ended
-- Ending and ended aren't sent while another of the household's subscriptions still grants access (after an ownership
-- transfer, the old owner's lapsing doesn't end the family's). The payload carries the household's time zone, so the
-- email's dates are the family's own, and whether billing is enforced, so "ended" says what really changes.
create function public.queue_subscription_email()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  notice record;
  recipient uuid;
  zone text;
  email_kind text;
begin
  select e.notification_uuid, e.notification_type, e.subtype into notice
    from public.subscription_events e
   where e.household_id = new.household_id and e.original_transaction_id = new.original_transaction_id
     and e.signed_at = new.notified_at and e.outcome = 'applied'
     -- Recorded in this transaction: the notification being applied now, never an earlier one signed the same instant.
     and e.created_at = now()
   order by e.created_at desc
   limit 1;
  if not found then
    return null;
  end if;

  email_kind := case
    when notice.notification_type = 'SUBSCRIBED' then 'subscription_started'
    when notice.notification_type = 'DID_CHANGE_RENEWAL_STATUS' and notice.subtype = 'AUTO_RENEW_DISABLED'
      then 'subscription_ending'
    when notice.notification_type = 'EXPIRED' then 'subscription_ended'
  end;
  if email_kind is null then
    return null;
  end if;

  if email_kind <> 'subscription_started' and exists (
    select 1 from public.household_subscriptions hs
     where hs.household_id = new.household_id and hs.original_transaction_id <> new.original_transaction_id
       and public.subscription_grants(hs.status, hs.expires_at)
  ) then
    return null;
  end if;

  select h.owner, coalesce(public.valid_time_zone(h.settings ->> 'time_zone'), 'America/New_York')
    into recipient, zone
    from public.households h where h.id = new.household_id;
  if recipient is null then
    return null;
  end if;

  perform public.enqueue_account_email(new.household_id, recipient, email_kind, notice.notification_uuid::text,
    jsonb_build_object('product_id', new.product_id, 'trial', new.status = 'trial', 'ends_at', new.expires_at,
                       'time_zone', zone,
                       'billing_enforced', coalesce((select c.billing_enforced from public.app_config c), false)));
  return null;
end;
$$;

revoke execute on function public.queue_subscription_email() from public, anon, authenticated;

create trigger household_subscriptions_queue_email
  after insert or update on public.household_subscriptions
  for each row execute function public.queue_subscription_email();

-- Sending (service role only) -------------------------------------------------------------------------------------------

-- Whether the recipient is still an adult in the row's household (not removed).
create function public.account_email_adult(target_household uuid, account uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.members m
                  where m.household_id = target_household and m.user_id = account
                    and m.age_group = 'adult' and m.status <> 'removed');
$$;

revoke execute on function public.account_email_adult(uuid, uuid) from public, anon, authenticated;

-- Hands the function up to `batch_size` due emails with their addresses, and holds them for 10 minutes. Nothing while
-- account_email_enabled is off. First it gives up rows that can't or shouldn't go:
--   stale        more than 2 days old and not sent
--   gave_up      five tries used, the last hold lapsed
--   not_adult    the recipient isn't an adult in the household any more (or never was)
--   no_address   the recipient's account has no verified Apple email
-- Claims are taken one at a time (an advisory lock), so the hourly cap holds with two runs at once.
create function public.claim_account_emails(batch_size int)
returns table (id uuid, kind text, email text, payload jsonb, attempts int)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  budget int;
begin
  if not coalesce((select c.account_email_enabled from public.app_config c), false) then
    return;
  end if;
  perform pg_advisory_xact_lock(hashtext('public.claim_account_emails'));

  update public.email_outbox o set failed_at = now(), reserved_at = null, last_error_code = 'stale'
   where o.sent_at is null and o.failed_at is null and o.created_at < now() - interval '2 days';
  update public.email_outbox o set failed_at = now(), reserved_at = null, last_error_code = 'gave_up'
   where o.sent_at is null and o.failed_at is null and o.attempts >= 5
     and (o.reserved_at is null or o.reserved_at < now() - interval '10 minutes');
  update public.email_outbox o set failed_at = now(), reserved_at = null, last_error_code = 'not_adult'
   where o.sent_at is null and o.failed_at is null and o.not_before <= now()
     and not public.account_email_adult(o.household_id, o.user_id);
  update public.email_outbox o set failed_at = now(), reserved_at = null, last_error_code = 'no_address'
   where o.sent_at is null and o.failed_at is null and o.not_before <= now()
     and public.verified_account_email(o.user_id) is null;

  budget := 200 - (select count(*)::int from public.email_outbox o
                    where o.sent_at > now() - interval '1 hour'
                       or (o.sent_at is null and o.failed_at is null and o.reserved_at > now() - interval '10 minutes'));

  return query
  with due as (
    select o.id from public.email_outbox o
     where o.sent_at is null and o.failed_at is null and o.not_before <= now() and o.attempts < 5
       and (o.reserved_at is null or o.reserved_at < now() - interval '10 minutes')
     order by o.not_before
     limit greatest(least(batch_size, budget), 0)
     for update skip locked
  ), claimed as (
    update public.email_outbox o
       set attempts = o.attempts + 1, reserved_at = now()
      from due where o.id = due.id
    returning o.*
  )
  select c.id, c.kind, public.verified_account_email(c.user_id), c.payload, c.attempts from claimed c;
end;
$$;

revoke execute on function public.claim_account_emails(int) from public, anon, authenticated;
grant execute on function public.claim_account_emails(int) to service_role;

-- Resend took it.
create function public.account_email_mark_sent(target uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.email_outbox set sent_at = now(), reserved_at = null, last_error_code = null
   where id = target and sent_at is null and failed_at is null;
$$;

revoke execute on function public.account_email_mark_sent(uuid) from public, anon, authenticated;
grant execute on function public.account_email_mark_sent(uuid) to service_role;

-- It didn't go: back off (10, 20, 30, 40 minutes after tries 1 to 4) and try again, until five tries are used or
-- give_up says it never will (an unknown kind, say).
create function public.account_email_release(target uuid, error_code text, give_up boolean default false)
returns void
language sql security definer set search_path = ''
as $$
  update public.email_outbox
     set reserved_at = null,
         last_error_code = left(coalesce(nullif(btrim(error_code), ''), 'unknown'), 40),
         not_before = now() + attempts * interval '10 minutes',
         failed_at = case when give_up or attempts >= 5 then now() end
   where id = target and sent_at is null and failed_at is null;
$$;

revoke execute on function public.account_email_release(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.account_email_release(uuid, text, boolean) to service_role;

-- Deletion receipts: where delete-account sends "Your Foon account was deleted", read before anything is deleted. Null
-- while account_email_enabled is off, for anyone who isn't an adult in a household (a kid deleting their own account,
-- or an account with no household, whose age Foon doesn't know), and without a verified Apple email.
create function public.deletion_receipt_address(account uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when coalesce((select c.account_email_enabled from public.app_config c), false)
         and exists (select 1 from public.members m
                      where m.user_id = account and m.age_group = 'adult' and m.status <> 'removed')
         and not exists (select 1 from public.members m where m.user_id = account and m.age_group = 'kid')
      then public.verified_account_email(account)
  end;
$$;

revoke execute on function public.deletion_receipt_address(uuid) from public, anon, authenticated;
grant execute on function public.deletion_receipt_address(uuid) to service_role;

-- The cron ---------------------------------------------------------------------------------------------------------------

-- Pokes the account-email Edge Function when sending is on and something is due. Returns whether it did, for tests.
-- Does nothing until Vault has both account_email_function_url and account_email_cron_secret (as kick_consent_renewals).
create function public.kick_account_email()
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  function_url text;
  cron_secret text;
begin
  if not coalesce((select c.account_email_enabled from public.app_config c), false) then
    return false;
  end if;
  if not exists (
    select 1 from public.email_outbox o
     where o.sent_at is null and o.failed_at is null and o.not_before <= now()
       and (o.reserved_at is null or o.reserved_at < now() - interval '10 minutes')
  ) then
    return false;
  end if;

  select decrypted_secret into function_url from vault.decrypted_secrets where name = 'account_email_function_url';
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name = 'account_email_cron_secret';
  if coalesce(function_url, '') = '' or coalesce(cron_secret, '') = '' then
    return false;
  end if;

  perform net.http_post(
    url := function_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-account-email-secret', cron_secret),
    timeout_milliseconds := 55000
  );
  return true;
end;
$$;

revoke execute on function public.kick_account_email() from public, anon, authenticated;

-- Sent, dropped and failed rows are kept 30 days, to answer "did my email go?".
create function public.prune_email_outbox()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.email_outbox where created_at < now() - interval '30 days';
$$;

revoke execute on function public.prune_email_outbox() from public, anon, authenticated;

select cron.schedule('kick-account-email', '*/5 * * * *', 'select public.kick_account_email()');
select cron.schedule('prune-email-outbox', '47 3 * * *', 'select public.prune_email_outbox()');
