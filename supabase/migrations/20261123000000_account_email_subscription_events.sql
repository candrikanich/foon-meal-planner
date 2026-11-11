-- Account email (#48), subscription events: the owner now hears about every important subscription event, not only
-- the start, the end of renewal and the end (20261121000000). New kinds:
--   DID_RENEW                                        subscription_renewed: renewed, and the next renewal date
--   DID_FAIL_TO_RENEW (a grace period or not)        subscription_billing_problem: Apple couldn't charge; how to fix it
--   DID_CHANGE_RENEWAL_STATUS / AUTO_RENEW_ENABLED   subscription_renewal_on: it will renew again
--   DID_CHANGE_RENEWAL_PREF                          subscription_plan_changed: the plan it renews as
--   REFUND / REVOKE                                  subscription_refunded: access ended by a refund or Family Sharing
--   GRACE_PERIOD_EXPIRED                             subscription_ended (as EXPIRED)
-- Ending, ended, refunded and billing_problem aren't sent while another of the household's subscriptions still grants
-- access (an ownership transfer: the old owner's lapsing or failing to bill isn't the family's loss). Started, renewed,
-- renewal_on and plan_changed are good news or the owner's own doing, and always go.
--
-- A plan change needs the plan Apple says it renews as, which the notification carries and nothing stored: a downgrade
-- waits for the period's end, so the subscription's row still shows the current product. subscription_events gets
-- next_product_id, and apply_subscription_notification a last argument for it (null for every other notification, and
-- left out by older callers).

alter table public.email_outbox drop constraint email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check check (kind in (
  'welcome', 'subscription_started', 'subscription_ending', 'subscription_ended', 'subscription_renewed',
  'subscription_billing_problem', 'subscription_renewal_on', 'subscription_plan_changed', 'subscription_refunded'));

-- Recording the plan ----------------------------------------------------------------------------------------------------

alter table public.subscription_events add column next_product_id text;

-- 20261107000000's function, with next_product_id added and nothing else changed. A new signature, so the old one goes.
drop function public.apply_subscription_notification(uuid, uuid, text, text, text, text, text, timestamptz,
  public.subscription_status, timestamptz, timestamptz, boolean);

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
  auto_renew boolean,
  next_product_id text default null
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
    when notification_type in ('REFUND', 'REVOKE') and period_ends_at < s.period_ends_at then 'older_period'
    else 'applied'
  end;

  insert into public.subscription_events (notification_uuid, household_id, notification_type, subtype, product_id,
                                          original_transaction_id, environment, signed_at, outcome, next_product_id)
  values (apply_subscription_notification.notification_uuid, target_household, notification_type, subtype, product_id,
          original_transaction_id, environment, signed_at, outcome, apply_subscription_notification.next_product_id);

  if outcome <> 'applied' then
    return outcome;
  end if;

  insert into public.household_subscriptions as hs (household_id, original_transaction_id, product_id, status, expires_at,
                                                    period_ends_at, environment, auto_renew, notified_at)
  values (target_household, original_transaction_id, product_id,
          -- A subscription first heard of through a notification that doesn't say (auto-renew changed) is active.
          coalesce(new_status, 'active'), expires_at, period_ends_at, environment, auto_renew, signed_at)
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
    period_ends_at = greatest(excluded.period_ends_at, hs.period_ends_at),
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
  public.subscription_status, timestamptz, timestamptz, boolean, text) from public, anon, authenticated;
grant execute on function public.apply_subscription_notification(uuid, uuid, text, text, text, text, text, timestamptz,
  public.subscription_status, timestamptz, timestamptz, boolean, text) to service_role;

-- The notices -----------------------------------------------------------------------------------------------------------

-- As in 20261121000000, with the new kinds. The payload keeps its keys (product_id, trial, ends_at, time_zone,
-- billing_enforced) and adds, by kind: grace (billing_problem: Apple is retrying and the family keeps access until
-- ends_at), revoked (refunded: Family Sharing ended, not a refund), and for plan_changed the plan it renews as in
-- product_id, and immediate (an upgrade, which took effect at once).
create or replace function public.queue_subscription_email()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  notice record;
  recipient uuid;
  zone text;
  email_kind text;
  details jsonb;
begin
  select e.notification_uuid, e.notification_type, e.subtype, e.next_product_id into notice
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
    when notice.notification_type = 'DID_RENEW' then 'subscription_renewed'
    when notice.notification_type = 'DID_FAIL_TO_RENEW' then 'subscription_billing_problem'
    when notice.notification_type = 'DID_CHANGE_RENEWAL_STATUS' and notice.subtype = 'AUTO_RENEW_DISABLED'
      then 'subscription_ending'
    when notice.notification_type = 'DID_CHANGE_RENEWAL_STATUS' and notice.subtype = 'AUTO_RENEW_ENABLED'
      then 'subscription_renewal_on'
    when notice.notification_type = 'DID_CHANGE_RENEWAL_PREF' then 'subscription_plan_changed'
    when notice.notification_type in ('REFUND', 'REVOKE') then 'subscription_refunded'
    when notice.notification_type in ('EXPIRED', 'GRACE_PERIOD_EXPIRED') then 'subscription_ended'
  end;
  if email_kind is null then
    return null;
  end if;

  -- A downgrade or crossgrade says what it renews as; with none, or the plan it already is (a downgrade taken back),
  -- there's nothing to tell. An upgrade is news whatever it says.
  if email_kind = 'subscription_plan_changed' and notice.subtype is distinct from 'UPGRADE'
     and (notice.next_product_id is null or notice.next_product_id = new.product_id) then
    return null;
  end if;

  if email_kind in ('subscription_ending', 'subscription_ended', 'subscription_refunded',
                    'subscription_billing_problem')
     and exists (
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

  details := jsonb_build_object('product_id', new.product_id, 'trial', new.status = 'trial', 'ends_at', new.expires_at,
                                'time_zone', zone,
                                'billing_enforced', coalesce((select c.billing_enforced from public.app_config c), false))
    || case email_kind
         when 'subscription_billing_problem'
           then jsonb_build_object('grace', coalesce(notice.subtype = 'GRACE_PERIOD', false))
         when 'subscription_refunded'
           then jsonb_build_object('revoked', notice.notification_type = 'REVOKE')
         when 'subscription_plan_changed'
           then jsonb_build_object('product_id', coalesce(notice.next_product_id, new.product_id),
                                   'immediate', coalesce(notice.subtype = 'UPGRADE', false))
         else '{}'::jsonb
       end;

  perform public.enqueue_account_email(new.household_id, recipient, email_kind, notice.notification_uuid::text, details);
  return null;
end;
$$;
