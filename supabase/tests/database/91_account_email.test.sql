-- Adult account email (#48): the outbox is the server's alone; a new household's owner is welcomed (not a sample
-- family's); subscription notices queue once per notification; the claim sends only while email is on, only to adults
-- with a verified Apple email, under 200 an hour; and deleting a household or an account takes its rows.
begin;
select plan(52);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true), set_config('role', 'anon', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role": "service_role"}', true), set_config('role', 'service_role', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;

-- Applies one notification as the Edge Function does, signed hours_ago hours back.
create function pg_temp.notify(uuid_tail text, target uuid, type text, subtype text, tx text,
                               status public.subscription_status, hours_ago int, expires_in_days int)
returns text language sql as $$
  select public.apply_subscription_notification(
    ('00000000-0000-0000-0000-' || lpad(uuid_tail, 12, '0'))::uuid, target, type, subtype, 'foon.family.monthly', tx,
    'Sandbox', now() - make_interval(hours => hours_ago), status, now() + make_interval(days => expires_in_days),
    now() + make_interval(days => expires_in_days), true);
$$;

-- Alice owns the Andersons, with Bob (an adult with no verified email) and Kit (a kid with an account). Carol owns the
-- Carters. Sam's family is a sample. Dave and Erin make theirs through create_household. Frank has no household.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('50000000-0000-0000-0000-000000000005', 'sam@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e1000000-0000-0000-0000-0000000000e1', 'erin@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'frank@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-alice', 'a0000000-0000-0000-0000-00000000000a', '{"sub": "apple-alice", "email": "alice@example.com", "email_verified": true}', 'apple'),
  ('apple-bob', 'b0000000-0000-0000-0000-00000000000b', '{"sub": "apple-bob", "email": "bob@example.com", "email_verified": false}', 'apple'),
  ('apple-kit', 'e0000000-0000-0000-0000-00000000000e', '{"sub": "apple-kit", "email": "kit@example.com"}', 'apple'),
  ('apple-carol', 'c0000000-0000-0000-0000-00000000000c', '{"sub": "apple-carol", "email": "carol@example.com"}', 'apple'),
  ('apple-dave', 'd0000000-0000-0000-0000-00000000000d', '{"sub": "apple-dave", "email": "dave@example.com"}', 'apple'),
  ('apple-frank', 'f0000000-0000-0000-0000-00000000000f', '{"sub": "apple-frank", "email": "frank@example.com"}', 'apple');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a', '{}'),
  ('00000000-0000-0000-0000-0000000000c0', 'Carters', 'c0000000-0000-0000-0000-00000000000c',
   '{"time_zone": "America/Chicago"}'),
  ('00000000-0000-0000-0000-000000000050', 'Sample Family', '50000000-0000-0000-0000-000000000005',
   '{"sample": true, "sample_pending": true}');
insert into public.members (household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a0', 'Bob', 'planner', true, 'adult', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', false, 'kid', 'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c0', 'Carol', 'planner', true, 'adult', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-000000000050', 'Sam', 'planner', true, 'adult', '50000000-0000-0000-0000-000000000005');

-- Nobody but the server ------------------------------------------------------------------------------------------------

select ok((select relrowsecurity from pg_class where oid = 'public.email_outbox'::regclass), 'the outbox has RLS on');
select ok(not has_table_privilege('anon', 'public.email_outbox', 'select, insert, update, delete'),
  'anon has no grant on the outbox');
select ok(not has_table_privilege('authenticated', 'public.email_outbox', 'select, insert, update, delete'),
  'nor does a signed-in user');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from public.email_outbox $$, '42501', null, 'an owner can''t read their own household''s outbox');
select throws_ok($$ select * from public.claim_account_emails(10) $$, '42501', null, 'or claim from it');
select throws_ok($$ select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0',
  'a0000000-0000-0000-0000-00000000000a', 'welcome', 'mine', '{}') $$, '42501', null, 'or queue an email');
select throws_ok($$ select public.account_email_release(gen_random_uuid(), 'x') $$, '42501', null, 'or settle one');
select throws_ok($$ select public.deletion_receipt_address('a0000000-0000-0000-0000-00000000000a') $$, '42501', null,
  'or look up a receipt address');
select throws_ok($$ select public.kick_account_email() $$, '42501', null, 'or poke the function');
select pg_temp.as_anon();
select throws_ok($$ select * from public.email_outbox $$, '42501', null, 'anon can''t read the outbox');
select pg_temp.as_service();
select lives_ok($$ select * from public.claim_account_emails(0) $$, 'the service role can claim');

-- Welcome ---------------------------------------------------------------------------------------------------------------

select pg_temp.as_admin();
select results_eq(
  $$ select household_id, user_id, kind, payload from public.email_outbox where kind = 'welcome' order by household_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a0'::uuid, 'a0000000-0000-0000-0000-00000000000a'::uuid, 'welcome', '{}'::jsonb),
            ('00000000-0000-0000-0000-0000000000c0'::uuid, 'c0000000-0000-0000-0000-00000000000c'::uuid, 'welcome', '{}'::jsonb) $$,
  'a new household''s owner is welcomed, with nothing but ids queued');
select is_empty($$ select 1 from public.email_outbox where household_id = '00000000-0000-0000-0000-000000000050' $$,
  'a sample family isn''t');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.create_household('Daltons', null, 'Dave', '{"onboarded": false}');
select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e1');
select public.create_household('Sample Family', null, 'Erin', '{"sample": true, "sample_pending": true}');
select pg_temp.as_admin();
select is((select count(*)::int from public.email_outbox where user_id = 'd0000000-0000-0000-0000-00000000000d'
            and kind = 'welcome'), 1, 'create_household queues the welcome');
select is_empty($$ select 1 from public.email_outbox where user_id = 'e1000000-0000-0000-0000-0000000000e1' $$,
  'but not for a sample family made through it');

select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0', 'a0000000-0000-0000-0000-00000000000a',
  'welcome', '00000000-0000-0000-0000-0000000000a0', '{}');
select is((select count(*)::int from public.email_outbox where kind = 'welcome'
            and household_id = '00000000-0000-0000-0000-0000000000a0'), 1, 'the same event can''t queue twice');
select throws_ok($$ select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0',
  'a0000000-0000-0000-0000-00000000000a', 'newsletter', 'x', '{}') $$, '23514', null, 'an unknown kind is refused');

-- Subscription notices --------------------------------------------------------------------------------------------------

select pg_temp.notify('101', '00000000-0000-0000-0000-0000000000a0', 'SUBSCRIBED', 'INITIAL_BUY', 'tx-a', 'trial', 10, 30);
select pg_temp.as_admin();
select results_eq(
  $$ select user_id, payload ->> 'product_id', (payload ->> 'trial')::boolean, (payload ->> 'ends_at')::timestamptz > now(),
            payload ->> 'time_zone', (payload ->> 'billing_enforced')::boolean
       from public.email_outbox where kind = 'subscription_started' $$,
  $$ values ('a0000000-0000-0000-0000-00000000000a'::uuid, 'foon.family.monthly', true, true, 'America/New_York', false) $$,
  'a trial starting queues subscription_started to the owner, with the trial''s end, the household''s time zone (the default without one) and whether billing is on');
select is((select dedupe_key from public.email_outbox where kind = 'subscription_started'),
  '00000000-0000-0000-0000-000000000101', 'keyed by Apple''s notification id');

select is(pg_temp.notify('101', '00000000-0000-0000-0000-0000000000a0', 'SUBSCRIBED', 'INITIAL_BUY', 'tx-a', 'trial', 10, 30),
  'duplicate', 'Apple retrying the same notification');
select pg_temp.notify('102', '00000000-0000-0000-0000-0000000000a0', 'DID_RENEW', null, 'tx-a', 'active', 9, 60);
select pg_temp.as_admin();
select is((select count(*)::int from public.email_outbox where kind = 'subscription_started'), 1,
  'queues no second start (a renewal has its own kind, 92_account_email_subscription_events)');

select pg_temp.notify('103', '00000000-0000-0000-0000-0000000000a0', 'DID_CHANGE_RENEWAL_STATUS', 'AUTO_RENEW_DISABLED',
  'tx-a', null, 8, 60);
select pg_temp.notify('104', '00000000-0000-0000-0000-0000000000a0', 'EXPIRED', 'VOLUNTARY', 'tx-a', 'cancelled', 7, 0);
select pg_temp.as_admin();
select results_eq(
  $$ select kind, user_id from public.email_outbox where kind in ('subscription_ending', 'subscription_ended') order by kind $$,
  $$ values ('subscription_ended', 'a0000000-0000-0000-0000-00000000000a'::uuid),
            ('subscription_ending', 'a0000000-0000-0000-0000-00000000000a'::uuid) $$,
  'turning off renewal queues subscription_ending, and expiry subscription_ended');
select ok((select (payload ->> 'ends_at') is not null from public.email_outbox where kind = 'subscription_ending'),
  'with the date access ends');

-- The Carters have two subscriptions; one lapsing while the other still covers them isn't news.
select pg_temp.notify('201', '00000000-0000-0000-0000-0000000000c0', 'SUBSCRIBED', 'INITIAL_BUY', 'tx-c1', 'active', 6, 30);
select pg_temp.notify('202', '00000000-0000-0000-0000-0000000000c0', 'SUBSCRIBED', 'INITIAL_BUY', 'tx-c2', 'active', 5, 30);
select pg_temp.notify('203', '00000000-0000-0000-0000-0000000000c0', 'EXPIRED', 'VOLUNTARY', 'tx-c2', 'cancelled', 4, 0);
select pg_temp.as_admin();
select is_empty($$ select 1 from public.email_outbox where household_id = '00000000-0000-0000-0000-0000000000c0'
                     and kind = 'subscription_ended' $$,
  'an ended subscription isn''t announced while another still covers the household');
select is((select array_agg(distinct payload ->> 'time_zone') from public.email_outbox
            where household_id = '00000000-0000-0000-0000-0000000000c0' and kind = 'subscription_started'),
  array['America/Chicago'], 'a household''s own time zone goes in the payload');

-- Claiming --------------------------------------------------------------------------------------------------------------

-- Rows that mustn't go: Bob has no verified email, Kit is a kid, Carol isn't an Anderson, and one is 3 days old.
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0', 'b0000000-0000-0000-0000-00000000000b',
  'welcome', 'bob', '{}');
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0', 'e0000000-0000-0000-0000-00000000000e',
  'welcome', 'kit', '{}');
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0', 'c0000000-0000-0000-0000-00000000000c',
  'welcome', 'carol-in-andersons', '{}');
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0', 'a0000000-0000-0000-0000-00000000000a',
  'welcome', 'old', '{}');
update public.email_outbox set created_at = now() - interval '3 days' where dedupe_key = 'old';
-- And one not due yet.
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000c0', 'c0000000-0000-0000-0000-00000000000c',
  'welcome', 'later', '{}', now() + interval '1 hour');

select is_empty($$ select * from public.claim_account_emails(100) $$, 'with email off nothing is claimed');
select is(public.kick_account_email(), false, 'or poked');
select is((select count(*)::int from public.email_outbox where reserved_at is not null or failed_at is not null), 0,
  'and every row waits as it was');

update public.app_config set account_email_enabled = true;
select is(public.kick_account_email(), false, 'with email on, but without the Vault secrets, nothing is poked');
select vault.create_secret('https://example.test/functions/v1/account-email', 'account_email_function_url');
select vault.create_secret('test-secret', 'account_email_cron_secret');
select is(public.kick_account_email(), true, 'with them, something due pokes the function');

create temp table claimed as select * from public.claim_account_emails(100);
select results_eq(
  $$ select kind, email, attempts from claimed order by kind, email $$,
  $$ values ('subscription_ended', 'alice@example.com', 1),
            ('subscription_ending', 'alice@example.com', 1),
            ('subscription_renewed', 'alice@example.com', 1),
            ('subscription_started', 'alice@example.com', 1),
            ('subscription_started', 'carol@example.com', 1),
            ('subscription_started', 'carol@example.com', 1),
            ('welcome', 'alice@example.com', 1),
            ('welcome', 'carol@example.com', 1),
            ('welcome', 'dave@example.com', 1) $$,
  'the claim hands over due rows with each adult''s verified Apple email');
select results_eq(
  $$ select dedupe_key, last_error_code from public.email_outbox where failed_at is not null order by dedupe_key $$,
  $$ values ('bob', 'no_address'), ('carol-in-andersons', 'not_adult'), ('kit', 'not_adult'), ('old', 'stale') $$,
  'and drops the rest: no verified email, a kid, not in the household, more than 2 days old');
select ok((select reserved_at is null and failed_at is null from public.email_outbox where dedupe_key = 'later'),
  'a row not due yet waits');
select is_empty($$ select * from public.claim_account_emails(100) $$, 'what''s claimed is held, so a second run gets none');

-- Settling --------------------------------------------------------------------------------------------------------------

select public.account_email_mark_sent((select id from claimed where kind = 'welcome' and email = 'dave@example.com'));
select public.account_email_release((select id from claimed where kind = 'welcome' and email = 'alice@example.com'),
  'resend_500');
select public.account_email_release((select id from claimed where kind = 'subscription_ending'), 'no_words', true);
select pg_temp.as_admin();
select ok((select sent_at is not null and reserved_at is null from public.email_outbox
            where id = (select id from claimed where email = 'dave@example.com')), 'a sent row is marked sent');
select results_eq(
  $$ select last_error_code, failed_at is null, reserved_at is null, not_before > now() + interval '9 minutes'
       from public.email_outbox where id = (select id from claimed where kind = 'welcome' and email = 'alice@example.com') $$,
  $$ values ('resend_500', true, true, true) $$,
  'a failed send is released with its code and backs off before another try');
select ok((select failed_at is not null from public.email_outbox
            where id = (select id from claimed where kind = 'subscription_ending')), 'give_up ends a row for good');

update public.email_outbox set not_before = now() - interval '1 minute'
 where id = (select id from claimed where kind = 'welcome' and email = 'alice@example.com');
select results_eq(
  $$ select kind, attempts from public.claim_account_emails(100) $$,
  $$ values ('welcome', 2) $$,
  'once the backoff is over it''s claimed again');
update public.email_outbox set attempts = 5 where id = (select id from claimed where kind = 'welcome' and email = 'alice@example.com');
select public.account_email_release((select id from claimed where kind = 'welcome' and email = 'alice@example.com'),
  'resend_500');
select is((select last_error_code from public.email_outbox where failed_at is not null
            and id = (select id from claimed where kind = 'welcome' and email = 'alice@example.com')), 'resend_500',
  'after five tries it''s given up');

-- The hourly cap ---------------------------------------------------------------------------------------------------------

insert into public.email_outbox (household_id, user_id, kind, dedupe_key, sent_at)
select '00000000-0000-0000-0000-0000000000c0', 'c0000000-0000-0000-0000-00000000000c', 'welcome', 'cap-' || i,
       now() - interval '30 minutes'
from generate_series(1, 194) i;
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000c0', 'c0000000-0000-0000-0000-00000000000c',
  'welcome', 'over-cap', '{}');
select is_empty($$ select * from public.claim_account_emails(100) $$,
  '200 sent or in flight in the last hour: nothing more is claimed');
update public.email_outbox set sent_at = now() - interval '2 hours' where dedupe_key like 'cap-%';
select is((select count(*)::int from public.claim_account_emails(100)), 1, 'an hour on, it is');

-- Deletion receipts -----------------------------------------------------------------------------------------------------

select is(public.deletion_receipt_address('a0000000-0000-0000-0000-00000000000a'), 'alice@example.com',
  'a deletion receipt goes to an adult''s verified Apple email');
select is(public.deletion_receipt_address('e0000000-0000-0000-0000-00000000000e'), null, 'never to a kid');
select is(public.deletion_receipt_address('b0000000-0000-0000-0000-00000000000b'), null, 'nor without a verified email');
select is(public.deletion_receipt_address('f0000000-0000-0000-0000-00000000000f'), null,
  'nor to an account in no household, whose age Foon doesn''t know');
update public.app_config set account_email_enabled = false;
select is(public.deletion_receipt_address('a0000000-0000-0000-0000-00000000000a'), null, 'nor while email is off');

-- Pruning and deleting --------------------------------------------------------------------------------------------------

update public.email_outbox set created_at = now() - interval '31 days' where dedupe_key like 'cap-%';
select public.prune_email_outbox();
select is((select count(*)::int from public.email_outbox where dedupe_key like 'cap-%'), 0,
  'rows go after 30 days');
select ok((select count(*) from public.email_outbox) > 0, 'newer ones stay');

select is(public.delete_household_data('c0000000-0000-0000-0000-00000000000c'), 'household_deleted', 'Carol deletes the Carters');
select is_empty($$ select 1 from public.email_outbox where household_id = '00000000-0000-0000-0000-0000000000c0' $$,
  'and their rows go with them');
select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0', 'f0000000-0000-0000-0000-00000000000f',
  'welcome', 'frank', '{}');
delete from auth.users where id = 'f0000000-0000-0000-0000-00000000000f';
select is_empty($$ select 1 from public.email_outbox where user_id = 'f0000000-0000-0000-0000-00000000000f' $$,
  'a deleted account''s rows go with it');

select isnt_empty($$ select 1 from cron.job where jobname = 'kick-account-email' and schedule = '*/5 * * * *' $$,
  'the function is poked every 5 minutes');

select * from finish();
rollback;
