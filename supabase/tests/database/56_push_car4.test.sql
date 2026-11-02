-- Server push, car 4 (#40 part 2): server pushes share the device's weekly budget, counted from the log on either channel,
-- most important first; and Engaged planners get one digest a day about new ideas that aren't theirs.
begin;
select plan(39);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

-- The Andersons' clock at a given time today.
create function pg_temp.at_a(t time) returns timestamptz language sql as $$
  select (public.household_today('00000000-0000-0000-0000-0000000000a0') + t)
         at time zone public.household_time_zone('00000000-0000-0000-0000-0000000000a0');
$$;

create function pg_temp.at_a_day(days int, t time) returns timestamptz language sql as $$
  select (public.household_today('00000000-0000-0000-0000-0000000000a0') + days + t)
         at time zone public.household_time_zone('00000000-0000-0000-0000-0000000000a0');
$$;

create function pg_temp.log_sent(member uuid, household uuid, n int, at timestamptz) returns void language sql as $$
  insert into public.notification_log (id, household_id, member_id, type, channel, scheduled_for, sent_at)
  select gen_random_uuid(), household, member, 'prep_reminder', 'device', at, at from generate_series(1, n);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'pam@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');

-- A clock where it's about noon now, so 7:30pm today is still ahead whenever the tests run.
update public.households
set settings = settings || jsonb_build_object('time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select extract(hour from now() at time zone 'UTC')::int - 12 as k) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Pam', 'planner', false, 'kid',
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b0', 'Dave', 'member', false, 'adult',
   'd0000000-0000-0000-0000-00000000000d');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.register_push_device(repeat('f3', 32), 'sandbox');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.register_push_device(repeat('c1', 32), 'sandbox');
select pg_temp.as_postgres();

-- The week ------------------------------------------------------------------------------------------------------------------------

update public.households set settings = settings || '{"time_zone": "America/New_York", "week_start": 1}'
where id = '00000000-0000-0000-0000-0000000000b0';
select results_eq(
  $$ select * from public.household_week_bounds('00000000-0000-0000-0000-0000000000b0', '2026-11-04 12:00 America/New_York') $$,
  $$ values ('2026-11-02 00:00 America/New_York'::timestamptz, '2026-11-09 00:00 America/New_York'::timestamptz) $$,
  'the household''s week, from its own first day, on its own clock');
update public.households set settings = settings - 'week_start' where id = '00000000-0000-0000-0000-0000000000b0';
select results_eq(
  $$ select * from public.household_week_bounds('00000000-0000-0000-0000-0000000000b0', '2026-11-04 12:00 America/New_York') $$,
  $$ values ('2026-11-01 00:00 America/New_York'::timestamptz, '2026-11-08 00:00 America/New_York'::timestamptz) $$,
  'Sunday when none is saved, across the clocks going back');
update public.households
set settings = settings || jsonb_build_object('time_zone', public.household_time_zone('00000000-0000-0000-0000-0000000000a0'))
where id = '00000000-0000-0000-0000-0000000000b0';

-- Budgets -------------------------------------------------------------------------------------------------------------------------

select results_eq(
  $$ select public.push_weekly_budget('00000000-0000-0000-0000-0000000000a2'), public.push_weekly_budget('00000000-0000-0000-0000-0000000000a3') $$,
  $$ values (12, 5) $$, 'Balanced (no preset saved): 12 for an adult, 5 for a kid, as on the device');
update public.households set settings = settings || '{"notification_preset": "light"}'
where id = '00000000-0000-0000-0000-0000000000a0';
select results_eq(
  $$ select public.push_weekly_budget('00000000-0000-0000-0000-0000000000a2'), public.push_weekly_budget('00000000-0000-0000-0000-0000000000a3') $$,
  $$ values (8, 2) $$, 'Light: 8 and 2');
update public.households set settings = settings || '{"notification_preset": "engaged"}'
where id = '00000000-0000-0000-0000-0000000000a0';
select results_eq(
  $$ select public.push_weekly_budget('00000000-0000-0000-0000-0000000000a2'), public.push_weekly_budget('00000000-0000-0000-0000-0000000000a3') $$,
  $$ values (16, 6) $$, 'Engaged: 16 and 6');
update public.households set settings = settings - 'notification_preset' where id = '00000000-0000-0000-0000-0000000000a0';

select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 11, now());
select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 5,
  (select starts - interval '1 second' from public.household_week_bounds('00000000-0000-0000-0000-0000000000a0', now())));
insert into public.notification_log (id, household_id, member_id, type, channel, scheduled_for, sent_at)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'after_dinner',
        'device', now() + interval '1 hour', null);
select pg_temp.log_sent('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 12, now());
select is(public.push_budget_left('00000000-0000-0000-0000-0000000000a2', now()), 1,
  'what''s gone out this week is used: not last week''s, not something scheduled but not sent, not another person''s');

insert into public.push_outbox (id, household_id, member_id, kind, args, not_before) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'tonight_poll', '{"name": "Alice"}', now() - interval '2 minutes'),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'plan_set', '{}', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-0000000005a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'tonight_poll', '{"name": "Alice"}', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-0000000005c1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c1',
   'plan_set', '{}', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-0000000005a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'plan_set', '{}', now() - interval '1 minute');

set local role service_role;
select results_eq($$ select id from public.claim_push_outbox(10) order by id $$,
  $$ values ('00000000-0000-0000-0000-0000000005a2'::uuid), ('00000000-0000-0000-0000-0000000005a4'::uuid) $$,
  'with one left, Bob gets Plan''s set before an older poll; Carol, at budget, gets nothing; Alice is untouched');
select pg_temp.as_postgres();
select results_eq($$ select id, failed from public.push_outbox where failed is not null order by id $$,
  $$ values ('00000000-0000-0000-0000-0000000005a1'::uuid, 'over_budget'),
            ('00000000-0000-0000-0000-0000000005c1'::uuid, 'over_budget') $$,
  'what doesn''t fit ends as over budget');
select is((select failed from public.push_outbox where id = '00000000-0000-0000-0000-0000000005a3'), null,
  'one not due yet isn''t judged yet');

set local role service_role;
select public.complete_push_outbox('00000000-0000-0000-0000-0000000005a2', 'sent');
select pg_temp.as_postgres();
select is(public.push_budget_left('00000000-0000-0000-0000-0000000000a2', now()), 0,
  'a push sent is logged, so it uses the budget the device reads');
select is((select count(*) from public.notification_log where type = 'tonight_poll'), 0::bigint,
  'and one over budget isn''t logged');
update public.push_outbox set not_before = now() - interval '1 second' where id = '00000000-0000-0000-0000-0000000005a3';
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10)), 0::bigint, 'once it''s used up, nothing more goes that week');
select pg_temp.as_postgres();

select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 4, now());
insert into public.push_outbox (household_id, member_id, kind, args, not_before) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'urgent_item', '{"name": "Bob"}',
   now() - interval '1 minute'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'not_home', '{"name": "Bob"}',
   now() - interval '3 minutes');
set local role service_role;
select results_eq($$ select kind from public.claim_push_outbox(10) $$, $$ values ('urgent_item') $$,
  'a kid with one left gets the urgent item before an older no');
select pg_temp.as_postgres();

-- Alice has one left, and her Plan's set is waiting to be tried again.
select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 11, now());
update public.push_outbox set claimed_until = now() + interval '4 minutes'
where id = '00000000-0000-0000-0000-0000000005a4';
insert into public.push_outbox (id, household_id, member_id, kind, args, not_before) values
  ('00000000-0000-0000-0000-0000000005a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'urgent_item', '{"name": "Bob"}', now() - interval '1 minute');
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10)), 0::bigint,
  'a push still being tried holds its place, so a new one can''t take the same last slot');
select pg_temp.as_postgres();
select is((select failed from public.push_outbox where id = '00000000-0000-0000-0000-0000000005a5'), 'over_budget',
  'and the new one is over budget');
delete from public.push_outbox;
delete from public.notification_log;

-- New-ideas digest ----------------------------------------------------------------------------------------------------------------

insert into public.requests (household_id, requested_by_member_id, entered_by_member_id, title, status, created_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Crab legs', 'open', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Tacos', 'open', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a1',
   'Pasta', 'open', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1',
   'Pie', 'open', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Soup', 'archived', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Stew', 'open', now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c2',
   'Chili', 'open', now() - interval '1 hour');

select is(public.enqueue_request_digests(pg_temp.at_a('19:45')), 0, 'nothing on Balanced');

update public.households set settings = settings || '{"notification_preset": "engaged"}';
select is(public.enqueue_request_digests(pg_temp.at_a('19:00')), 0, 'nothing before 7:30pm');
select is(public.enqueue_request_digests(pg_temp.at_a('21:15')), 0, 'or once quiet hours begin');

update public.households
set settings = settings || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
  'from', public.household_today('00000000-0000-0000-0000-0000000000a0'),
  'to', public.household_today('00000000-0000-0000-0000-0000000000a0'))))
where id = '00000000-0000-0000-0000-0000000000a0';
update public.households set settings = settings || '{"notification_preset": "balanced"}'
where id = '00000000-0000-0000-0000-0000000000b0';
select is(public.enqueue_request_digests(pg_temp.at_a('19:45')), 0, 'or on an away day');
update public.households set settings = (settings - 'away_dates')
where id = '00000000-0000-0000-0000-0000000000a0';
update public.households set settings = settings || '{"notification_preset": "engaged"}'
where id = '00000000-0000-0000-0000-0000000000b0';

select is(public.enqueue_request_digests(pg_temp.at_a('19:45')), 3, 'at 7:45 on Engaged, each planner with a device');
select results_eq(
  $$ select m.first_name, o.args, o.about_member_id from public.push_outbox o join public.members m on m.id = o.member_id
     order by m.first_name $$,
  $$ values ('Alice', '{"count": 2, "name": "Bob"}'::jsonb, '00000000-0000-0000-0000-0000000000a2'::uuid),
            ('Carol', '{"count": 1, "name": "Dave"}'::jsonb, '00000000-0000-0000-0000-0000000000c2'::uuid),
            ('Pam', '{"count": 4}'::jsonb, null::uuid) $$,
  'counting open ideas from the last day that aren''t theirs (not asked for, not entered by them), naming one person only');
select is((select count(*) from public.push_outbox o join public.members m on m.id = o.member_id
           where o.not_before <> public.push_not_before(public.household_time_zone(o.household_id), m.age_group = 'kid',
                                                        pg_temp.at_a('19:45'))
              or o.expires_at <> ((public.household_today(o.household_id) + time '21:00')
                                  at time zone public.household_time_zone(o.household_id))), 0::bigint,
  'each held for their own quiet hours, and good until 9pm');
select is(public.enqueue_request_digests(pg_temp.at_a('20:00')), 0, 'once a planner a day');

-- The next day, only what's new since the last one.
insert into public.requests (household_id, requested_by_member_id, entered_by_member_id, title, status, created_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Ramen', 'open', pg_temp.at_a_day(0, '22:00'));
update public.push_outbox set sent_at = now();
select is(public.enqueue_request_digests(pg_temp.at_a_day(1, '19:45')), 2, 'the next day, the planners with something new');
select results_eq(
  $$ select m.first_name, o.args from public.push_outbox o join public.members m on m.id = o.member_id
     where o.sent_at is null order by m.first_name $$,
  $$ values ('Alice', '{"count": 1, "name": "Bob"}'::jsonb), ('Pam', '{"count": 1, "name": "Bob"}'::jsonb) $$,
  'count only what came since their last digest');
select is(public.enqueue_request_digests(pg_temp.at_a_day(1, '20:00')), 0,
  'and once a day by the run''s own clock: the digest is stamped with when it ran');

-- Someone removed -------------------------------------------------------------------------------------------------------------------

insert into public.requests (household_id, requested_by_member_id, entered_by_member_id, title, status, created_at) values
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c2',
   'Gumbo', 'open', pg_temp.at_a_day(1, '22:00'));
update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000c2';
select is(public.enqueue_request_digests(pg_temp.at_a_day(2, '19:45')), 0,
  'ideas from someone removed since don''t make a digest, so their name doesn''t go out');
select results_eq($$ select args, about_member_id from public.push_outbox where member_id = '00000000-0000-0000-0000-0000000000c1' $$,
  $$ values ('{"count": 1}'::jsonb, null::uuid) $$,
  'the digest that named them stays, without their name, so Carol''s once a day still holds');

-- A kid's consent withdrawn ---------------------------------------------------------------------------------------------------------

insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before, sent_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'new_requests',
   '00000000-0000-0000-0000-0000000000a4', '{"count": 1, "name": "Nora"}', now(), now()),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'new_requests',
   '00000000-0000-0000-0000-0000000000a4', '{"count": 1, "name": "Nora"}', now(), null);
insert into public.consents (household_id, member_id, kind, granted_by, granted_at, revoked_at, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental',
   'a0000000-0000-0000-0000-00000000000a', now() - interval '90 days', now() - interval '31 days', 'v1');
select public.anonymize_expired_profiles();
select is((select count(*) from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a4'
             or args ->> 'name' = 'Nora'), 0::bigint,
  'a kid''s withdrawn consent takes their name out of the digests that named them, sent ones too');
select is((select count(*) from public.push_outbox where kind = 'new_requests' and args = '{"count": 1}'
             and household_id = '00000000-0000-0000-0000-0000000000a0'), 2::bigint,
  'but the digests stay, so a planner''s once a day still holds');
select is((select count(*) from public.push_outbox where kind = 'new_requests'), 7::bigint,
  'and the others are untouched: Alice''s and Pam''s two days, and Carol''s');

-- A profile claimed mid-window ---------------------------------------------------------------------------------------------------

insert into public.requests (household_id, requested_by_member_id, entered_by_member_id, title, status, created_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a2',
   'Waffles', 'open', pg_temp.at_a_day(3, '19:00'));
select is(public.enqueue_request_digests(pg_temp.at_a_day(3, '19:45')), 2, 'Nora''s idea, passed to Bob''s phone');
select is((select count(*) from public.push_outbox where args ->> 'name' = 'Nora'), 2::bigint, 'names her');
insert into auth.users (id, email, aud, role) values
  ('40000000-0000-0000-0000-000000000004', 'nora@example.com', 'authenticated', 'authenticated');
update public.members set user_id = '40000000-0000-0000-0000-000000000004'
where id = '00000000-0000-0000-0000-0000000000a4';
select is((select count(*) from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a4'
             or args ->> 'name' = 'Nora'), 0::bigint, 'when she claims her profile, the digests stop naming her');
select is(public.enqueue_request_digests(pg_temp.at_a_day(3, '20:00')), 0,
  'but stay, so the 8pm run doesn''t send the same news again');

-- Clients ------------------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.enqueue_request_digests() $$, '42501', null, 'a client can''t queue a digest');
select throws_ok($$ select public.push_budget_left('00000000-0000-0000-0000-0000000000a2', now()) $$, '42501', null,
  'or read someone''s budget');
select throws_ok($$ select * from public.push_outbox $$, '42501', null, 'or read the outbox');
select pg_temp.as_postgres();
select ok(exists (select 1 from cron.job where jobname = 'enqueue-request-digests' and schedule = '*/15 * * * *'),
  'the digest is queued by pg_cron every 15 minutes');

select * from finish();
rollback;
