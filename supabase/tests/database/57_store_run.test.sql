-- Heading to the store (#51): any adult starts a 10-minute run, one at a time; the family hears on Engaged, by quiet hours,
-- within budgets; runs are their household's alone.
begin;
select plan(28);

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
  ('e0000000-0000-0000-0000-00000000000e', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('70000000-0000-0000-0000-000000000007', 'tom@example.com', 'authenticated', 'authenticated'),
  ('80000000-0000-0000-0000-000000000008', 'rex@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');

-- A clock where it's about 4pm now, whenever the tests run: after school on any day, before quiet hours, so kids hear too.
update public.households
set settings = settings || jsonb_build_object('time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select case when raw > 12 then raw - 24 else raw end as k
         from (select (extract(hour from now() at time zone 'UTC')::int - 16 + 24) % 24 as raw) wrapped) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Tom', 'member', false, 'adult',
   '70000000-0000-0000-0000-000000000007'),
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a0', 'Rex', 'member', false, 'adult',
   '80000000-0000-0000-0000-000000000008');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.register_push_device(repeat('e3', 32), 'sandbox');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.register_push_device(repeat('c1', 32), 'sandbox');
select pg_temp.as_user('70000000-0000-0000-0000-000000000007');
select public.register_push_device(repeat('a7', 32), 'sandbox');
select pg_temp.as_postgres();
-- Tom is travelling (no return date); Rex has been removed but still has his account.
update public.members set status = 'away' where id = '00000000-0000-0000-0000-0000000000a7';
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a8';

-- Who starts one ------------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'a kid can''t start a store run');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'nor someone from another family');
select throws_ok($$ insert into public.store_runs (household_id, ends_at) values ('00000000-0000-0000-0000-0000000000a0', now()) $$,
  '42501', null, 'and nobody writes one directly');
select pg_temp.as_user('80000000-0000-0000-0000-000000000008');
select throws_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'nor an adult who''s been removed from the family');
select pg_temp.as_postgres();
set local role anon;
select throws_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'and nobody signed out');
select pg_temp.as_postgres();

-- Balanced: a run, and no push.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$, 'any adult starts one, not just a planner');
select results_eq($$ select started_by, ends_at - started_at from public.store_runs $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid, interval '10 minutes') $$, 'for ten minutes, and the family can see it');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nobody hears on Balanced');

-- Engaged.
delete from public.store_runs;
update public.households set settings = settings || '{"notification_preset": "engaged"}';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.start_store_run('00000000-0000-0000-0000-0000000000a0');
select pg_temp.as_postgres();
select results_eq(
  $$ select m.first_name from public.push_outbox o join public.members m on m.id = o.member_id order by m.first_name $$,
  $$ values ('Alice'), ('Kim') $$,
  'on Engaged, everyone else in the family with a device hears, kids too: not whoever started it, not someone travelling, '
  'not another family');
select results_eq($$ select distinct o.kind, o.args, o.about_member_id, o.expires_at = r.ends_at
                     from public.push_outbox o, public.store_runs r $$,
  $$ values ('heading_to_store', '{"name": "Bob"}'::jsonb, '00000000-0000-0000-0000-0000000000a2'::uuid, true) $$,
  'with the first name only, and good until the run ends');
select is((select count(*) from public.push_outbox o join public.members m on m.id = o.member_id
           where o.not_before <> public.push_not_before(public.household_time_zone(o.household_id),
                                                        m.age_group = 'kid', o.created_at)), 0::bigint,
  'each by their own quiet hours');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select results_eq($$ select started_by from public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid) $$, 'starting again while one is open hands back that one');
select pg_temp.as_postgres();
select is((select count(*) from public.store_runs), 1::bigint, 'one run at a time');
select is((select count(*) from public.push_outbox), 2::bigint, 'and nobody hears twice');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*) from public.store_runs), 0::bigint, 'another family can''t see the run');
select throws_ok($$ select * from public.push_outbox $$, '42501', null, 'or the outbox');
select lives_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000b0') $$, 'and starts its own');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where household_id = '00000000-0000-0000-0000-0000000000b0'), 0::bigint,
  'nobody else in the Carters'' family to tell');

-- Away, ended, quiet hours --------------------------------------------------------------------------------------------------------

delete from public.push_outbox;
update public.store_runs set ends_at = now() - interval '1 second', started_at = now() - interval '11 minutes';
update public.households
set settings = settings || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
  'from', public.household_today('00000000-0000-0000-0000-0000000000a0'),
  'to', public.household_today('00000000-0000-0000-0000-0000000000a0'))))
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.start_store_run('00000000-0000-0000-0000-0000000000a0') $$,
  'once a run is over, another can start');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nobody hears on an away day');

insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before, expires_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'heading_to_store',
   '00000000-0000-0000-0000-0000000000a2', '{"name": "Bob"}', now() - interval '11 minutes', now() - interval '1 minute');
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10)), 0::bigint, 'one the run has ended for isn''t sent');
select pg_temp.as_postgres();
select is((select failed from public.push_outbox), 'stale', 'it''s given up');

-- Budgets -------------------------------------------------------------------------------------------------------------------------

delete from public.push_outbox;
insert into public.notification_log (id, household_id, member_id, type, channel, scheduled_for, sent_at)
select gen_random_uuid(), '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'prep_reminder',
       'device', now(), now()
from generate_series(1, 15);
insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before, expires_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'tonight_poll',
   '00000000-0000-0000-0000-0000000000a2', '{"name": "Bob"}', now() - interval '2 minutes', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'heading_to_store',
   '00000000-0000-0000-0000-0000000000a2', '{"name": "Bob"}', now() - interval '1 minute', now() + interval '9 minutes');
set local role service_role;
select results_eq($$ select kind from public.claim_push_outbox(10) $$, $$ values ('heading_to_store') $$,
  'with one left in the week, a store run goes before an older poll');
select pg_temp.as_postgres();

-- Leaving ------------------------------------------------------------------------------------------------------------------------

update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a2';
select is((select count(*) from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a2'), 0::bigint,
  'someone removed takes the store-run pushes about them along');
select is((select count(*) from public.store_runs where started_by = '00000000-0000-0000-0000-0000000000a2'), 2::bigint,
  'their runs stay until they''re pruned');
update public.store_runs set ends_at = now() - interval '2 days', started_at = now() - interval '2 days 10 minutes';
select public.prune_push_outbox();
select is((select count(*) from public.store_runs where household_id = '00000000-0000-0000-0000-0000000000a0'), 0::bigint,
  'a run is pruned the day after');

-- Quiet hours ---------------------------------------------------------------------------------------------------------------------

-- Households whose clock is at a given hour now, whenever the tests run.
create function pg_temp.clock_at(target_hour int) returns text language sql as $$
  select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
  from (select case when raw > 12 then raw - 24 else raw end as k
        from (select (extract(hour from now() at time zone 'UTC')::int - target_hour + 24) % 24 as raw) wrapped) offset_hours;
$$;

insert into auth.users (id, email, aud, role) values
  ('d1000000-0000-0000-0000-0000000000d1', 'gus@example.com', 'authenticated', 'authenticated'),
  ('d2000000-0000-0000-0000-0000000000d2', 'hal@example.com', 'authenticated', 'authenticated'),
  ('d3000000-0000-0000-0000-0000000000d3', 'ivy@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000d0', 'Grays', 'd1000000-0000-0000-0000-0000000000d1',
   jsonb_build_object('time_zone', pg_temp.clock_at(22), 'notification_preset', 'engaged'));
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d0', 'Gus', 'planner', true, 'adult',
   'd1000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d0', 'Hal', 'member', false, 'adult',
   'd2000000-0000-0000-0000-0000000000d2'),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d0', 'Ivy', 'member', false, 'kid',
   'd3000000-0000-0000-0000-0000000000d3');
select pg_temp.as_user('d2000000-0000-0000-0000-0000000000d2');
select public.register_push_device(repeat('d2', 32), 'sandbox');
select pg_temp.as_user('d3000000-0000-0000-0000-0000000000d3');
select public.register_push_device(repeat('d3', 32), 'sandbox');
select pg_temp.as_user('d1000000-0000-0000-0000-0000000000d1');
select public.start_store_run('00000000-0000-0000-0000-0000000000d0');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where household_id = '00000000-0000-0000-0000-0000000000d0'), 0::bigint,
  'at 10pm, quiet hours would hold everyone past the run''s end, so nothing is queued');

-- At 10am a kid is held for school hours on a weekday (until 3pm, past the run), and hears at once on a weekend.
delete from public.store_runs where household_id = '00000000-0000-0000-0000-0000000000d0';
update public.households set settings = settings || jsonb_build_object('time_zone', pg_temp.clock_at(10))
where id = '00000000-0000-0000-0000-0000000000d0';
select pg_temp.as_user('d1000000-0000-0000-0000-0000000000d1');
select public.start_store_run('00000000-0000-0000-0000-0000000000d0');
select pg_temp.as_postgres();
select results_eq(
  $$ select m.first_name from public.push_outbox o join public.members m on m.id = o.member_id
     where o.household_id = '00000000-0000-0000-0000-0000000000d0' order by m.first_name $$,
  $$ select name from (values ('Hal'), ('Ivy')) n(name)
     where name = 'Hal' or extract(isodow from public.household_today('00000000-0000-0000-0000-0000000000d0')) > 5 $$,
  'at 10am an adult hears; a kid only on a weekend, since school hours run past the run');

select * from finish();
rollback;
