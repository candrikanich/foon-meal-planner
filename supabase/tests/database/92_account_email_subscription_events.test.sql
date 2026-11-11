-- Account email, every subscription event (#48): renewals, billing problems, renewal turned back on, plan changes,
-- refunds and revocations, and a grace period running out each queue one email to the household's owner, once per
-- notification, with what the email needs in its payload. Ending, ended, refunded and billing_problem stay quiet while
-- another of the household's subscriptions still grants access. (91_account_email covers the earlier kinds, the
-- claim, the cap and deletion.)
begin;
select plan(15);

-- Applies one notification as the Edge Function does, signed hours_ago hours back, access running expires_in_days on.
create function pg_temp.notify(uuid_tail text, target uuid, type text, subtype text, product text, tx text,
                               status public.subscription_status, hours_ago int, expires_in_days int,
                               next_product text default null)
returns text language sql as $$
  select public.apply_subscription_notification(
    ('00000000-0000-0000-0000-' || lpad(uuid_tail, 12, '0'))::uuid, target, type, subtype, product, tx,
    'Sandbox', now() - make_interval(hours => hours_ago), status, now() + make_interval(days => expires_in_days),
    now() + make_interval(days => expires_in_days), true, next_product);
$$;

-- Alice owns the Andersons (Chicago), Carol the Carters, Dave the Dunns, who have two subscriptions.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-alice', 'a0000000-0000-0000-0000-00000000000a',
   '{"sub": "apple-alice", "email": "alice@example.com", "email_verified": true}', 'apple');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"time_zone": "America/Chicago"}'),
  ('00000000-0000-0000-0000-0000000000c0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}'),
  ('00000000-0000-0000-0000-0000000000d0', 'Dunns', 'd0000000-0000-0000-0000-00000000000d', '{}');
insert into public.members (household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult', 'a0000000-0000-0000-0000-00000000000a');

-- One household, every event ------------------------------------------------------------------------------------------

select pg_temp.notify('101', '00000000-0000-0000-0000-0000000000a0', 'SUBSCRIBED', 'INITIAL_BUY',
  'foon.family.monthly', 'tx-a', 'active', 40, 30);
select pg_temp.notify('102', '00000000-0000-0000-0000-0000000000a0', 'DID_RENEW', null,
  'foon.family.monthly', 'tx-a', 'active', 39, 60);
select pg_temp.notify('103', '00000000-0000-0000-0000-0000000000a0', 'DID_FAIL_TO_RENEW', 'GRACE_PERIOD',
  'foon.family.monthly', 'tx-a', 'lapsed', 38, 5);
select pg_temp.notify('104', '00000000-0000-0000-0000-0000000000a0', 'DID_FAIL_TO_RENEW', null,
  'foon.family.monthly', 'tx-a', 'lapsed', 37, 1);
select pg_temp.notify('105', '00000000-0000-0000-0000-0000000000a0', 'DID_CHANGE_RENEWAL_STATUS', 'AUTO_RENEW_ENABLED',
  'foon.family.monthly', 'tx-a', null, 36, 60);
-- A downgrade waits for the period's end: the subscription is still the monthly plan, renewing as the annual one.
select pg_temp.notify('106', '00000000-0000-0000-0000-0000000000a0', 'DID_CHANGE_RENEWAL_PREF', 'DOWNGRADE',
  'foon.family.monthly', 'tx-a', null, 35, 60, 'foon.family.annual');
select pg_temp.notify('107', '00000000-0000-0000-0000-0000000000a0', 'DID_CHANGE_RENEWAL_PREF', 'UPGRADE',
  'foon.family.annual', 'tx-a', 'active', 34, 60, 'foon.family.annual');
-- Taking a downgrade back, and a change that doesn't say what to: nothing to tell.
select pg_temp.notify('108', '00000000-0000-0000-0000-0000000000a0', 'DID_CHANGE_RENEWAL_PREF', null,
  'foon.family.annual', 'tx-a', null, 33, 60, 'foon.family.annual');
select pg_temp.notify('109', '00000000-0000-0000-0000-0000000000a0', 'DID_CHANGE_RENEWAL_PREF', 'DOWNGRADE',
  'foon.family.annual', 'tx-a', null, 32, 60);
select pg_temp.notify('110', '00000000-0000-0000-0000-0000000000a0', 'GRACE_PERIOD_EXPIRED', null,
  'foon.family.annual', 'tx-a', 'lapsed', 31, 0);
select pg_temp.notify('111', '00000000-0000-0000-0000-0000000000a0', 'REFUND', null,
  'foon.family.annual', 'tx-a', 'cancelled', 30, 60);

select results_eq(
  $$ select dedupe_key, kind from public.email_outbox
      where household_id = '00000000-0000-0000-0000-0000000000a0' and kind like 'subscription%' order by dedupe_key $$,
  $$ values ('00000000-0000-0000-0000-000000000101', 'subscription_started'),
            ('00000000-0000-0000-0000-000000000102', 'subscription_renewed'),
            ('00000000-0000-0000-0000-000000000103', 'subscription_billing_problem'),
            ('00000000-0000-0000-0000-000000000104', 'subscription_billing_problem'),
            ('00000000-0000-0000-0000-000000000105', 'subscription_renewal_on'),
            ('00000000-0000-0000-0000-000000000106', 'subscription_plan_changed'),
            ('00000000-0000-0000-0000-000000000107', 'subscription_plan_changed'),
            ('00000000-0000-0000-0000-000000000110', 'subscription_ended'),
            ('00000000-0000-0000-0000-000000000111', 'subscription_refunded') $$,
  'each event queues its own kind, once per notification, keyed by Apple''s id (a plan change with no new plan to name queues none)');

select results_eq(
  $$ select payload ->> 'product_id', payload ->> 'time_zone', (payload ->> 'ends_at')::timestamptz > now() + interval '59 days'
       from public.email_outbox where kind = 'subscription_renewed' $$,
  $$ values ('foon.family.monthly', 'America/Chicago', true) $$,
  'a renewal carries the plan, the household''s time zone and the next renewal date');

select results_eq(
  $$ select dedupe_key, (payload ->> 'grace')::boolean from public.email_outbox
      where kind = 'subscription_billing_problem' order by dedupe_key $$,
  $$ values ('00000000-0000-0000-0000-000000000103', true), ('00000000-0000-0000-0000-000000000104', false) $$,
  'a billing problem says whether Apple has given a grace period');
select ok((select (payload ->> 'ends_at')::timestamptz between now() + interval '4 days' and now() + interval '6 days'
             from public.email_outbox where dedupe_key = '00000000-0000-0000-0000-000000000103'),
  'and in a grace period, when access continues until');

select results_eq(
  $$ select dedupe_key, payload ->> 'product_id', (payload ->> 'immediate')::boolean from public.email_outbox
      where kind = 'subscription_plan_changed' order by dedupe_key $$,
  $$ values ('00000000-0000-0000-0000-000000000106', 'foon.family.annual', false),
            ('00000000-0000-0000-0000-000000000107', 'foon.family.annual', true) $$,
  'a plan change names the plan it renews as, and whether it took effect at once');
select is((select next_product_id from public.subscription_events
            where notification_uuid = '00000000-0000-0000-0000-000000000106'), 'foon.family.annual',
  'the notification keeps the plan Apple said it renews as');

select results_eq(
  $$ select payload ->> 'product_id', (payload ->> 'revoked')::boolean from public.email_outbox
      where kind = 'subscription_refunded' and household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values ('foon.family.annual', false) $$,
  'a refund queues subscription_refunded, not marked as a Family Sharing revocation');

select is(pg_temp.notify('102', '00000000-0000-0000-0000-0000000000a0', 'DID_RENEW', null,
  'foon.family.monthly', 'tx-a', 'active', 39, 60), 'duplicate', 'Apple retrying a renewal');
select is((select count(*)::int from public.email_outbox where kind = 'subscription_renewed'), 1,
  'queues no second email');
select is_empty($$ select 1 from public.email_outbox where household_id = '00000000-0000-0000-0000-0000000000a0'
                     and user_id <> 'a0000000-0000-0000-0000-00000000000a' $$,
  'they all go to the household''s owner');

-- A refund of an earlier period isn't news; a revocation of this one is -------------------------------------------------

select pg_temp.notify('201', '00000000-0000-0000-0000-0000000000c0', 'SUBSCRIBED', 'INITIAL_BUY',
  'foon.family.monthly', 'tx-c', 'active', 30, 30);
select is(pg_temp.notify('202', '00000000-0000-0000-0000-0000000000c0', 'REFUND', null,
  'foon.family.monthly', 'tx-c', 'cancelled', 29, 0), 'older_period', 'a refund of an earlier period leaves the subscription');
select pg_temp.notify('203', '00000000-0000-0000-0000-0000000000c0', 'REVOKE', null,
  'foon.family.monthly', 'tx-c', 'cancelled', 28, 30);
select results_eq(
  $$ select (payload ->> 'revoked')::boolean from public.email_outbox
      where kind = 'subscription_refunded' and household_id = '00000000-0000-0000-0000-0000000000c0' $$,
  $$ values (true) $$,
  'so only the revocation queues subscription_refunded, marked as Family Sharing ending');

-- Another subscription still covers the household -----------------------------------------------------------------------

select pg_temp.notify('301', '00000000-0000-0000-0000-0000000000d0', 'SUBSCRIBED', 'INITIAL_BUY',
  'foon.family.monthly', 'tx-d1', 'active', 30, 30);
select pg_temp.notify('302', '00000000-0000-0000-0000-0000000000d0', 'SUBSCRIBED', 'INITIAL_BUY',
  'foon.family.monthly', 'tx-d2', 'active', 29, 30);
select pg_temp.notify('303', '00000000-0000-0000-0000-0000000000d0', 'DID_FAIL_TO_RENEW', 'GRACE_PERIOD',
  'foon.family.monthly', 'tx-d2', 'lapsed', 28, 5);
select pg_temp.notify('304', '00000000-0000-0000-0000-0000000000d0', 'DID_CHANGE_RENEWAL_STATUS', 'AUTO_RENEW_DISABLED',
  'foon.family.monthly', 'tx-d2', null, 27, 30);
select pg_temp.notify('305', '00000000-0000-0000-0000-0000000000d0', 'DID_RENEW', null,
  'foon.family.monthly', 'tx-d2', 'active', 26, 30);
select pg_temp.notify('306', '00000000-0000-0000-0000-0000000000d0', 'DID_CHANGE_RENEWAL_STATUS', 'AUTO_RENEW_ENABLED',
  'foon.family.monthly', 'tx-d2', null, 25, 30);
select pg_temp.notify('307', '00000000-0000-0000-0000-0000000000d0', 'REVOKE', null,
  'foon.family.monthly', 'tx-d2', 'cancelled', 24, 30);
select pg_temp.notify('308', '00000000-0000-0000-0000-0000000000d0', 'DID_CHANGE_RENEWAL_PREF', 'UPGRADE',
  'foon.family.annual', 'tx-d2', 'active', 23, 30, 'foon.family.annual');
select results_eq(
  $$ select kind, count(*)::int from public.email_outbox
      where household_id = '00000000-0000-0000-0000-0000000000d0' and kind like 'subscription%'
      group by kind order by kind $$,
  $$ values ('subscription_plan_changed', 1), ('subscription_renewal_on', 1), ('subscription_renewed', 1),
            ('subscription_started', 2) $$,
  'a billing problem, renewal turned off and a revocation aren''t announced while the other subscription covers them; a renewal, renewal back on and a plan change are');

-- Sending ------------------------------------------------------------------------------------------------------------------

update public.app_config set account_email_enabled = true;
create temp table claimed as select * from public.claim_account_emails(100);
select is((select count(*)::int from claimed where email = 'alice@example.com' and kind like 'subscription%'), 9,
  'the claim hands the owner all nine, with her verified Apple email');
select throws_ok($$ select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0',
  'a0000000-0000-0000-0000-00000000000a', 'newsletter', 'x', '{}') $$, '23514', null,
  'a kind outside the list is still refused');

select * from finish();
rollback;
