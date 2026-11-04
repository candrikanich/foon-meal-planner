-- Household entitlement (#66, server half). One subscription covers the whole household, so the entitlement lives on
-- the household, written only by the app-store-notifications Edge Function from Apple's signed notifications. The
-- buyer's app sets appAccountToken to the household's id, which is how a notification finds its household.
--
-- 1. billing_enforced is off for the free beta: every household is entitled until a migration turns it on at launch.
-- 2. Clients read the subscription columns (Family shows status to the owner) but can't write them: households keeps its
--    column-level update grant (name, emoji, settings, owner), and these columns aren't in it.
-- 3. A household can have more than one Apple subscription: after an ownership transfer, the old owner's still carries
--    the household's id until it lapses, and the new owner can buy their own. Each is kept on its own row
--    (household_subscriptions), and the household is entitled while any of them grants access, so one lapsing can't
--    lock out another.

alter table public.app_config add column billing_enforced boolean not null default false;

-- What the household shows: the subscription that's doing the most for it (see household_subscription_summary).
alter table public.households
  add column subscription_product_id text,
  -- Past this, a lapsed household is no longer entitled. A grace period moves it to the grace period's end.
  add column subscription_expires_at timestamptz,
  add column subscription_original_transaction_id text,
  add column subscription_environment text check (subscription_environment in ('Sandbox', 'Production')),
  add column subscription_auto_renew boolean,
  -- Apple's signedDate of the last notification applied to that subscription.
  add column subscription_notified_at timestamptz;

-- Subscriptions ---------------------------------------------------------------------------------------------------------

-- Each Apple subscription that names the household, as its latest notification left it. Server only.
create table public.household_subscriptions (
  household_id uuid not null references public.households (id) on delete cascade,
  original_transaction_id text not null,
  product_id text,
  status public.subscription_status not null,
  expires_at timestamptz,
  environment text not null check (environment in ('Sandbox', 'Production')),
  auto_renew boolean,
  -- So a late retry of an older notification can't undo a newer one for the same subscription.
  notified_at timestamptz not null,
  primary key (household_id, original_transaction_id)
);

revoke all on public.household_subscriptions from anon, authenticated;
alter table public.household_subscriptions enable row level security;

-- Whether a subscription in this state grants access. Trial and active run to their expiry plus 3 days: a buffer we
-- chose for a late renewal notification, so a lost EXPIRED can't leave a household unlocked for good. (Apple's own
-- retries of one we failed to take run longer, about 6.5 days: after 1, 12, 24, 48 and 72 hours.)
-- Lapsed is billing retry: entitled through a grace period (its expiry), not after it.
create function public.subscription_grants(status public.subscription_status, expires_at timestamptz)
returns boolean
language sql stable set search_path = ''
as $$
  select case status
    when 'trial' then expires_at is null or expires_at > now() - interval '3 days'
    when 'active' then expires_at is null or expires_at > now() - interval '3 days'
    when 'lapsed' then coalesce(expires_at > now(), false)
    else false
  end;
$$;

revoke execute on function public.subscription_grants(public.subscription_status, timestamptz) from public, anon;
grant execute on function public.subscription_grants(public.subscription_status, timestamptz) to authenticated, service_role;

-- Events ----------------------------------------------------------------------------------------------------------------

-- What Apple told us, one row per notification: the audit trail behind the household's status. Server only.
create table public.subscription_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  -- Apple's id for the notification. Apple retries until it gets a 200, so a repeat is recorded once.
  notification_uuid uuid not null unique,
  notification_type text not null,
  subtype text,
  product_id text,
  original_transaction_id text not null,
  environment text not null check (environment in ('Sandbox', 'Production')),
  signed_at timestamptz not null,
  -- applied: its subscription took it. stale: older than one already applied to that subscription. older_period: a
  -- refund or revocation of a period before the current one, which leaves the subscription as it is.
  outcome text not null check (outcome in ('applied', 'stale', 'older_period')),
  created_at timestamptz not null default now()
);

create index subscription_events_household on public.subscription_events (household_id, signed_at);

revoke all on public.subscription_events from anon, authenticated;
alter table public.subscription_events enable row level security;

-- Applying a notification -----------------------------------------------------------------------------------------------

-- The Edge Function has verified the signature and mapped the notification type to new_status (null: no change, as
-- when auto-renew is turned off) and expires_at; period_ends_at is the transaction's own expiresDate. Returns
-- 'no_household', 'duplicate', 'stale', 'older_period' or 'applied'.
create function public.apply_subscription_notification(
  notification_uuid uuid,
  target_household uuid,
  notification_type text,
  subtype text,
  product_id text,
  original_transaction_id text,
  environment text,
  signed_at timestamptz,
  new_status public.subscription_status,
  expires_at timestamptz,
  period_ends_at timestamptz,
  auto_renew boolean
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  s public.household_subscriptions;
  best public.household_subscriptions;
  outcome text;
begin
  perform 1 from public.households where id = target_household for update;
  if not found then
    return 'no_household';
  end if;
  if exists (select 1 from public.subscription_events e
             where e.notification_uuid = apply_subscription_notification.notification_uuid) then
    return 'duplicate';
  end if;

  select * into s from public.household_subscriptions hs
  where hs.household_id = target_household
    and hs.original_transaction_id = apply_subscription_notification.original_transaction_id;
  outcome := case
    when s.notified_at > signed_at then 'stale'
    -- Refunding last month doesn't cancel the month that's paid for now: only the current period's refund ends it.
    when notification_type in ('REFUND', 'REVOKE') and period_ends_at < s.expires_at then 'older_period'
    else 'applied'
  end;

  insert into public.subscription_events (notification_uuid, household_id, notification_type, subtype, product_id,
                                          original_transaction_id, environment, signed_at, outcome)
  values (apply_subscription_notification.notification_uuid, target_household, notification_type, subtype, product_id,
          original_transaction_id, environment, signed_at, outcome);

  if outcome <> 'applied' then
    return outcome;
  end if;

  insert into public.household_subscriptions as hs (household_id, original_transaction_id, product_id, status, expires_at,
                                                    environment, auto_renew, notified_at)
  values (target_household, original_transaction_id, product_id,
          -- A subscription first heard of through a notification that doesn't say (auto-renew changed) is active.
          coalesce(new_status, 'active'), expires_at, environment, auto_renew, signed_at)
  on conflict on constraint household_subscriptions_pkey do update set
    product_id = coalesce(excluded.product_id, hs.product_id),
    status = coalesce(new_status, hs.status),
    -- Access that continues (a renewal, a reversed refund, an auto-renew change) never ends sooner than it did; one
    -- that stops (lapsed, cancelled) takes the date Apple gives.
    expires_at = case
      when coalesce(new_status, hs.status) in ('trial', 'active') or new_status is null
        then greatest(excluded.expires_at, hs.expires_at)
      else coalesce(excluded.expires_at, hs.expires_at)
    end,
    environment = excluded.environment,
    auto_renew = coalesce(excluded.auto_renew, hs.auto_renew),
    notified_at = excluded.notified_at;

  -- The household shows the subscription doing the most for it: one that grants access, the longest-running first;
  -- if none does, the one heard from last.
  select * into best from public.household_subscriptions hs
  where hs.household_id = target_household
  order by public.subscription_grants(hs.status, hs.expires_at) desc, hs.expires_at desc nulls first, hs.notified_at desc
  limit 1;

  update public.households set
    subscription_status = best.status,
    subscription_product_id = best.product_id,
    subscription_expires_at = best.expires_at,
    subscription_original_transaction_id = best.original_transaction_id,
    subscription_environment = best.environment,
    subscription_auto_renew = best.auto_renew,
    subscription_notified_at = best.notified_at
  where id = target_household;
  return outcome;
end;
$$;

revoke execute on function public.apply_subscription_notification(uuid, uuid, text, text, text, text, text, timestamptz,
  public.subscription_status, timestamptz, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.apply_subscription_notification(uuid, uuid, text, text, text, text, text, timestamptz,
  public.subscription_status, timestamptz, timestamptz, boolean) to service_role;

-- Entitlement -----------------------------------------------------------------------------------------------------------

-- Whether the household gets the full app: billing isn't enforced yet, or any of its subscriptions grants access.
-- A signed-in caller only learns about their own household.
create function public.household_entitled(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select case
    when (select auth.role()) = 'authenticated' and not public.is_household_member(target_household) then null
    when not coalesce((select billing_enforced from public.app_config), false) then true
    else exists (
      select 1 from public.household_subscriptions hs
      where hs.household_id = target_household and public.subscription_grants(hs.status, hs.expires_at)
    )
  end;
$$;

revoke execute on function public.household_entitled(uuid) from public, anon;
grant execute on function public.household_entitled(uuid) to authenticated, service_role;


-- Retention -------------------------------------------------------------------------------------------------------------

-- Two years of events is enough to answer a billing question; Apple keeps the full history.
create function public.prune_subscription_events()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.subscription_events where created_at < now() - interval '2 years';
$$;

revoke execute on function public.prune_subscription_events() from public, anon, authenticated;

select cron.schedule('prune-subscription-events', '41 3 * * *', 'select public.prune_subscription_events()');

-- Erase -----------------------------------------------------------------------------------------------------------------

-- The same erase as before (20261103210000_ai_jobs), now with the household's subscriptions and their events.
create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Before any row: a device's write holds this while it takes its own locks, so one in flight finishes first, and a later one
  -- waits and is then refused.
  perform pg_advisory_xact_lock(public.notification_log_lock(target));
  -- Holds the nights first, so a Swap in flight can't log a new entry after the log's been emptied and fail the erase.
  perform 1 from public.plan_nights where household_id = target for update;
  delete from public.subscription_events where household_id = target;
  delete from public.household_subscriptions where household_id = target;
  delete from public.ai_jobs where household_id = target;
  delete from public.poll_votes where household_id = target;
  delete from public.polls where household_id = target;
  delete from public.notification_log where household_id = target;
  delete from public.plan_changes where household_id = target;
  delete from public.night_claims where household_id = target;
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
  delete from public.freezer_stash where household_id = target;
  delete from public.plans where household_id = target;
  delete from public.traditions where household_id = target;
  delete from public.meal_sides where household_id = target;
  delete from public.meal_ingredients where household_id = target;
  delete from public.meals where household_id = target;
  delete from public.items where household_id = target;
  delete from public.member_allergies where household_id = target;
  delete from public.invites where household_id = target;
  delete from public.consent_agreements where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;
