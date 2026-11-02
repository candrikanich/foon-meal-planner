-- Server push, car 1 (#40 part 2): device tokens are their owner's alone, the outbox is the server's alone, Plan's set goes to
-- everyone with a device but the approver, once a plan, and quiet hours hold a push until they end.
begin;
select plan(42);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'eve@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Dan', 'member', false, 'adult',
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Eve', 'member', false, 'adult',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 6),
  ('00000000-0000-0000-0000-0000000003a3', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 14);

-- Devices -----------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.register_push_device(upper(repeat('ab', 32)), 'sandbox') $$, 'a member registers a device');
select results_eq($$ select token, environment, member_id from public.push_devices $$,
  $$ values (repeat('ab', 32), 'sandbox', '00000000-0000-0000-0000-0000000000a2'::uuid) $$,
  'the token is kept in lower case, for their own profile, and they can read it');
select throws_ok($$ select public.register_push_device('not-a-token', 'sandbox') $$, '22023', null,
  'a token that isn''t hex is refused');
select throws_ok($$ select public.register_push_device(repeat('a', 63), 'sandbox') $$, '22023', null,
  'a token too short is refused');
select throws_ok($$ select public.register_push_device(repeat('ab', 32), 'staging') $$, '22023', null,
  'an unknown environment is refused');
select throws_ok($$ insert into public.push_devices (user_id, member_id, household_id, token, environment) values
    ('b0000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0',
     repeat('cd', 32), 'sandbox') $$, '42501', null, 'a device can''t be written directly');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.push_devices), 0::bigint, 'another member, even a planner, can''t read it');
select lives_ok($$ select public.unregister_push_device(repeat('ab', 32)) $$, 'unregistering someone else''s token runs');
select public.register_push_device(repeat('a1', 32), 'production');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*) from public.push_devices), 0::bigint, 'another household can''t read it');
select public.register_push_device(repeat('ab', 32), 'production');
select results_eq($$ select member_id, environment from public.push_devices $$,
  $$ values ('00000000-0000-0000-0000-0000000000c1'::uuid, 'production') $$,
  'a token registered by another account moves to them');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*) from public.push_devices), 0::bigint, 'and the old owner no longer has it');
select public.register_push_device(repeat('ab', 32), 'sandbox');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select public.unregister_push_device(repeat('b2', 32));
select is((select count(*) from public.push_devices), 1::bigint, 'unregistering removes the caller''s own token');

select pg_temp.as_postgres();
select is((select count(*) from public.push_devices where token = repeat('ab', 32)), 1::bigint,
  'and someone else unregistering it didn''t');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.register_push_device(repeat('e5', 32), 'sandbox');

-- The outbox is the server's ------------------------------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select * from public.push_outbox $$, '42501', null, 'a client can''t read the outbox');
select throws_ok($$ insert into public.push_outbox (household_id, member_id, kind, not_before) values
    ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'plan_set', now()) $$,
  '42501', null, 'or write to it');
select throws_ok($$ select * from public.claim_push_outbox(10) $$, '42501', null, 'or claim from it');
select throws_ok($$ select * from public.push_provider_tokens $$, '42501', null, 'or read the provider token');

-- Plan's set ----------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);

select pg_temp.as_postgres();
select results_eq($$ select member_id from public.push_outbox where kind = 'plan_set' order by member_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid), ('00000000-0000-0000-0000-0000000000a4'::uuid) $$,
  'approving a week queues Plan''s set for everyone with a device, not the approver, not someone without one');
select is((select count(*) from public.push_outbox
           where not_before <> public.push_not_before('America/New_York', false, created_at)), 0::bigint,
  'held for quiet hours on the household''s clock');
select is((select args from public.push_outbox limit 1), '{}'::jsonb, 'with nothing in it but the kind');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 2::bigint, 'Update the list doesn''t send it again');

update public.plans set approved_at = null where id = '00000000-0000-0000-0000-0000000003a1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 2::bigint, 'nor does approving the same week again');

update public.households
set settings = settings || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
  'from', public.household_today('00000000-0000-0000-0000-0000000000a0') + 6,
  'to', public.household_today('00000000-0000-0000-0000-0000000000a0') + 12)))
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a3', '[]'::jsonb);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where plan_id <> '00000000-0000-0000-0000-0000000003a1'), 0::bigint,
  'not for a week that''s all away, or one that''s over');

-- Quiet hours ---------------------------------------------------------------------------------------------------------------

select is(public.push_not_before('America/New_York', false, '2026-11-04 22:00 America/New_York'),
  '2026-11-05 07:00 America/New_York'::timestamptz, 'an adult at 10pm waits for 7am the next day');
select is(public.push_not_before('America/New_York', false, '2026-11-04 03:00 America/New_York'),
  '2026-11-04 07:00 America/New_York'::timestamptz, 'an adult at 3am waits for 7am');
select is(public.push_not_before('America/New_York', false, '2026-11-04 14:00 America/New_York'),
  '2026-11-04 14:00 America/New_York'::timestamptz, 'an adult at 2pm hears now');
select is(public.push_not_before('America/New_York', true, '2026-11-04 10:00 America/New_York'),
  '2026-11-04 15:00 America/New_York'::timestamptz, 'a kid on a weekday at 10am waits for 3pm');
select is(public.push_not_before('America/New_York', true, '2026-11-07 10:00 America/New_York'),
  '2026-11-07 10:00 America/New_York'::timestamptz, 'a kid on Saturday at 10am hears now');
select is(public.push_not_before('America/Los_Angeles', false, '2026-11-04 22:00 America/New_York'),
  '2026-11-04 19:00 America/Los_Angeles'::timestamptz, 'on the household''s own clock');

-- Sending -------------------------------------------------------------------------------------------------------------------

delete from public.push_outbox;
insert into public.push_outbox (id, household_id, member_id, kind, plan_id, not_before, attempts) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'plan_set', '00000000-0000-0000-0000-0000000003a1', now() - interval '1 minute', 0),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'plan_set', null, now() + interval '1 hour', 0),
  ('00000000-0000-0000-0000-0000000005a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'plan_set', null, now() - interval '1 minute', 5),
  ('00000000-0000-0000-0000-0000000005a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'plan_set', null, now() - interval '2 days', 0);

select is(public.kick_push_sender(), false, 'without the Vault secrets nothing is poked, even with something due');
select vault.create_secret('https://example.test/functions/v1/send-push', 'push_function_url');
select is(public.kick_push_sender(), false, 'nor with only one of them');
select vault.create_secret('test-secret', 'push_cron_secret');
select is(public.kick_push_sender(), true, 'with both, something due pokes send-push');
select results_eq($$ select url, headers ->> 'x-push-secret' from net.http_request_queue $$,
  $$ values ('https://example.test/functions/v1/send-push', 'test-secret') $$, 'at the URL, with the shared secret');

set local role service_role;
select results_eq($$ select id, kind, week_start, attempts, devices from public.claim_push_outbox(10) $$,
  $$ values ('00000000-0000-0000-0000-0000000005a1'::uuid, 'plan_set',
             public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, 1,
             jsonb_build_array(jsonb_build_object('token', repeat('ab', 32), 'environment', 'sandbox'))) $$,
  'claiming hands over only what''s due and not tried five times, with the person''s devices and the week');
select is((select count(*) from public.claim_push_outbox(10)), 0::bigint, 'a claimed row isn''t handed out twice');
select is((select failed from public.push_outbox where id = '00000000-0000-0000-0000-0000000005a4'), 'stale',
  'a row a day late is given up');

select public.complete_push_outbox('00000000-0000-0000-0000-0000000005a1', 'sent');
select ok((select sent_at is not null from public.push_outbox where id = '00000000-0000-0000-0000-0000000005a1'),
  'a delivered row is marked sent');
select results_eq($$ select member_id, type, channel from public.notification_log $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid, 'plan_set', 'push') $$, 'and logged as a push');

select public.complete_push_outbox('00000000-0000-0000-0000-0000000005a3', 'retry');
select is((select failed from public.push_outbox where id = '00000000-0000-0000-0000-0000000005a3'), 'gave_up',
  'a fifth failed try gives up');

select public.forget_push_devices(array[repeat('ab', 32)]);
select is((select count(*) from public.push_devices where token = repeat('ab', 32)), 0::bigint,
  'a token Apple says is dead is forgotten');

-- Leaving takes devices along ---------------------------------------------------------------------------------------------

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.register_push_device(repeat('d4', 32), 'sandbox');
select pg_temp.as_postgres();
update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a4';
select is((select count(*) from public.push_devices where token = repeat('e5', 32)), 0::bigint,
  'someone removed from the family loses their devices');
delete from auth.users where id = 'd0000000-0000-0000-0000-00000000000d';
select is((select count(*) from public.push_devices where token = repeat('d4', 32)), 0::bigint,
  'a deleted account loses its devices');

select * from finish();
rollback;
