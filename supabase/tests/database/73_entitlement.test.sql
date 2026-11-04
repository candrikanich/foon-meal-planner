-- Household entitlement (#66): only the app-store-notifications Edge Function (service role) writes it; clients read
-- their own household's status but can't write it or see the events behind it.
begin;
select plan(49);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

-- The service role, as the Edge Function calls in: no signed-in user.
create function pg_temp.as_server() returns void language sql as $$
  select set_config('request.jwt.claims', '', true);
$$;

-- Applies one notification the way the Edge Function does, signed hours_ago hours back, expiring in expires_in hours,
-- for a transaction whose period ends in period_in hours (by default, when it expires).
create function pg_temp.notify(uuid_tail text, type text, tx text, status public.subscription_status,
                               hours_ago int, expires_in int, target uuid default '00000000-0000-0000-0000-0000000000a0',
                               period_in int default null)
returns text language sql as $$
  select public.apply_subscription_notification(
    ('00000000-0000-0000-0000-' || lpad(uuid_tail, 12, '0'))::uuid, target, type, null, 'foon.family.monthly', tx,
    'Sandbox', now() - make_interval(hours => hours_ago), status, now() + make_interval(hours => expires_in),
    now() + make_interval(hours => coalesce(period_in, expires_in)), true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000c0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (household_id, first_name, role, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a0', 'Bob', 'planner', true, 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c0', 'Carol', 'planner', true, 'c0000000-0000-0000-0000-00000000000c');

select ok((select relrowsecurity from pg_class where oid = 'public.subscription_events'::regclass),
  'subscription_events has row-level security');
select ok((select relrowsecurity from pg_class where oid = 'public.household_subscriptions'::regclass),
  'and so does household_subscriptions');
select ok((select bool_and(prosecdef and proconfig @> array['search_path=""']) from pg_proc
           where proname in ('apply_subscription_notification', 'household_entitled', 'prune_subscription_events')),
  'its functions run as definer with an empty search_path');

-- The free beta ----------------------------------------------------------------------------------------------------------

select is((select billing_enforced from public.app_config), false, 'billing isn''t enforced during the beta');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), true,
  'so a household with no subscription is entitled');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000c0'), null,
  'a signed-in caller learns nothing about another household');

-- Clients can't write it ---------------------------------------------------------------------------------------------------

select throws_ok($$ update public.households set subscription_status = 'active' where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'the owner can''t set the status');
select throws_ok($$ update public.households set subscription_expires_at = now() + interval '1 year' $$,
  '42501', null, 'or the expiry');
select throws_ok($$ update public.households set subscription_product_id = 'foon.family.annual' $$, '42501', null,
  'or the product');
select throws_ok($$ update public.households set subscription_original_transaction_id = '1' $$, '42501', null,
  'or the subscription it follows');
select throws_ok($$ update public.households set subscription_environment = 'Production', subscription_auto_renew = true,
  subscription_notified_at = now() $$, '42501', null, 'or the rest');
select throws_ok($$ insert into public.households (name, subscription_status) values ('Sneaky', 'active') $$, '42501', null,
  'or create a household that''s already paid');
select throws_ok($$ select public.apply_subscription_notification(gen_random_uuid(), '00000000-0000-0000-0000-0000000000a0',
  'SUBSCRIBED', null, 'foon.family.monthly', '1', 'Sandbox', now(), 'active', now() + interval '1 year',
  now() + interval '1 year', true) $$,
  '42501', null, 'or apply a notification');
select lives_ok($$ update public.households set name = 'The Andersons' where id = '00000000-0000-0000-0000-0000000000a0' $$,
  'the name is still theirs to change');
select is((select subscription_status::text from public.households where id = '00000000-0000-0000-0000-0000000000a0'), 'none',
  'and they can read the status');

-- Nobody but the server sees the events ---------------------------------------------------------------------------------

reset role;
select pg_temp.as_server();
select is(pg_temp.notify('1', 'SUBSCRIBED', 'tx-alice', 'trial', 10, 720), 'applied', 'a trial starts');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select 1 from public.subscription_events $$, '42501', null, 'the household can''t read its events');
select throws_ok($$ insert into public.subscription_events (household_id, notification_uuid, notification_type, environment,
  signed_at, outcome) values ('00000000-0000-0000-0000-0000000000a0', gen_random_uuid(), 'SUBSCRIBED', 'Sandbox', now(),
  'applied') $$, '42501', null, 'or write one');
select throws_ok($$ select 1 from public.household_subscriptions $$, '42501', null, 'or its subscriptions');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select 1 from public.subscription_events $$, '42501', null, 'and neither can another household');
reset role;
set local role anon;
select throws_ok($$ select 1 from public.subscription_events $$, '42501', null, 'or anyone signed out');
reset role;
select pg_temp.as_server();
set local role service_role;
select is((select count(*)::int from public.subscription_events), 1, 'the server reads them');
reset role;

-- Applying notifications --------------------------------------------------------------------------------------------------

select is(pg_temp.notify('1', 'SUBSCRIBED', 'tx-alice', 'trial', 10, 720), 'duplicate', 'Apple''s retry is recorded once');
select is(pg_temp.notify('2', 'DID_RENEW', 'tx-alice', 'active', 1, 720, '00000000-0000-0000-0000-0000000000f0'),
  'no_household', 'a token that isn''t a household changes nothing');
update public.app_config set billing_enforced = true;
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), true, 'billing on: a trial is entitled');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000c0'), false, 'a household that never subscribed isn''t');

select is(pg_temp.notify('3', 'DID_FAIL_TO_RENEW', 'tx-alice', 'lapsed', 5, 48), 'applied', 'a failed renewal with grace');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), true, 'stays entitled through the grace period');
select is(pg_temp.notify('4', 'DID_RENEW', 'tx-alice', 'active', 8, 720), 'stale',
  'a late retry of an older notification doesn''t undo a newer one');
select is(pg_temp.notify('5', 'GRACE_PERIOD_EXPIRED', 'tx-alice', 'lapsed', 4, -1), 'applied', 'the grace period ends');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), false, 'and with it, the entitlement');

-- Active more than 3 days past its expiry: the EXPIRED that should have come was lost, and access ends anyway.
select is(pg_temp.notify('6', 'DID_RENEW', 'tx-old', 'active', 3, -100), 'applied', 'an active period long over');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), false, 'doesn''t keep the household unlocked');
select is(pg_temp.notify('7', 'DID_RENEW', 'tx-alice', 'active', 2, 8760), 'applied', 'Alice renews for a year');

-- Refunds: last month's refund doesn't cancel the year that's paid for, and a reversed old refund doesn't shorten it.
select is(pg_temp.notify('12', 'REFUND', 'tx-alice', 'cancelled', 1, 0, period_in => -720), 'older_period',
  'a refund of an earlier period is recorded and changes nothing');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), true, 'so the household stays entitled');
select is(pg_temp.notify('13', 'REFUND_REVERSED', 'tx-alice', 'active', 1, -720), 'applied', 'an old refund is reversed');
select ok((select expires_at > now() + interval '8000 hours' from public.household_subscriptions
           where original_transaction_id = 'tx-alice'), 'and the year''s expiry doesn''t move back');

-- Ownership transfer: Alice's annual subscription stays on the household, and Bob, the new owner, subscribes monthly.
update public.households set owner = 'b0000000-0000-0000-0000-00000000000b' where id = '00000000-0000-0000-0000-0000000000a0';
select is(pg_temp.notify('8', 'SUBSCRIBED', 'tx-bob', 'active', 1, 720), 'applied', 'the new owner subscribes');
select results_eq(
  $$ select subscription_status::text, subscription_original_transaction_id
     from public.households where id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values ('active', 'tx-alice') $$,
  'the household shows the subscription that runs longest');
select is(pg_temp.notify('9', 'EXPIRED', 'tx-alice', 'cancelled', 0, -1), 'applied', 'Alice cancels and hers expires');
select results_eq(
  $$ select subscription_status::text, subscription_original_transaction_id, public.household_entitled(id)
     from public.households where id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values ('active', 'tx-bob', true) $$,
  'the old owner''s lapse doesn''t lock out the new owner''s subscription');
select is(pg_temp.notify('10', 'REFUND', 'tx-bob', 'cancelled', 0, 0, period_in => 720), 'applied',
  'Bob''s current month is refunded');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000a0'), false, 'with nothing granting access, it ends');
select is(pg_temp.notify('11', 'DID_RENEW', 'tx-alice', 'active', 5, 8760), 'stale',
  'and an older notification for Alice''s can''t bring it back');

-- In a grace period, access runs past the paid period. Refunding that current period still ends it.
select is(pg_temp.notify('14', 'DID_FAIL_TO_RENEW', 'tx-carol', 'lapsed', 3, 48, '00000000-0000-0000-0000-0000000000c0',
  period_in => 1), 'applied', 'the Carters'' renewal fails into a grace period');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000c0'), true, 'they''re entitled through the grace');
select is(pg_temp.notify('15', 'REFUND', 'tx-carol', 'cancelled', 1, 0, '00000000-0000-0000-0000-0000000000c0',
  period_in => 1), 'applied', 'a refund of the current period isn''t mistaken for an earlier one');
select is(public.household_entitled('00000000-0000-0000-0000-0000000000c0'), false, 'and it ends access');

select * from finish();
rollback;
