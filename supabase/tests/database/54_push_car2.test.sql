-- Server push, car 2 (#40 part 2): "won't be home tonight" and "will cook Thursday" go to the household's planners with a
-- device, never to whoever said it or entered it, only on Balanced and Engaged, never for an away night, once, and not after
-- dinner. Taking it back calls off what hasn't gone.
begin;
select plan(36);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

-- What's waiting for the Andersons' people, as (recipient, kind, about whom).
create function pg_temp.queued(target_kind text) returns table (recipient text, about text) language sql as $$
  select r.first_name, a.first_name from public.push_outbox o
  join public.members r on r.id = o.member_id left join public.members a on a.id = o.about_member_id
  where o.kind = target_kind and o.sent_at is null and o.failed is null order by r.first_name;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'eve@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'pam@example.com', 'authenticated', 'authenticated'),
  ('90000000-0000-0000-0000-000000000009', 'quinn@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');

-- A clock where it's about noon now, whenever the tests run, so tonight's 11pm dinner is still ahead and nobody's in the
-- 9pm to 7am quiet hours.
update public.households
set settings = settings || jsonb_build_object('time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select extract(hour from now() at time zone 'UTC')::int - 12 as k) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Eve', 'member', false, 'adult',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Pam', 'planner', false, 'kid',
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Quinn', 'planner', true, 'adult',
   '90000000-0000-0000-0000-000000000009'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b0', 'Dave', 'member', false, 'adult',
   'd0000000-0000-0000-0000-00000000000d');

insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1),
  ('00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000b0',
   public.household_today('00000000-0000-0000-0000-0000000000b0'));
insert into public.plan_nights (id, household_id, plan_id, date, dinner_time) values
  ('00000000-0000-0000-0000-0000000004a0', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, '23:00'),
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0'), '23:00'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, '23:00'),
  ('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 2, '23:00'),
  ('00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 3, '23:00'),
  ('00000000-0000-0000-0000-0000000004b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000003b1',
   public.household_today('00000000-0000-0000-0000-0000000000b0'), null);

-- Everyone but Quinn and Nora has a device.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.register_push_device(repeat('e4', 32), 'sandbox');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.register_push_device(repeat('f5', 32), 'sandbox');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.register_push_device(repeat('c1', 32), 'sandbox');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.register_push_device(repeat('d2', 32), 'sandbox');

-- Won't be home ---------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false);
select throws_ok($$ select * from public.push_outbox $$, '42501', null, 'a client still can''t read the outbox');

select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('not_home') $$,
  $$ values ('Alice', 'Bob'), ('Pam', 'Bob') $$,
  'a no on the check-in goes to the planners with a device: not someone who isn''t a planner, not one without a device');
select results_eq(
  $$ select distinct args, night_id, expires_at from public.push_outbox where kind = 'not_home' $$,
  $$ values ('{"name": "Bob"}'::jsonb, '00000000-0000-0000-0000-0000000004a1'::uuid,
             public.night_dinner_at('00000000-0000-0000-0000-0000000004a1')) $$,
  'with only the first name, about tonight, and good until dinner');
select is((select count(*) from public.push_outbox o join public.members m on m.id = o.member_id
           where o.kind = 'not_home'
             and o.not_before <> public.push_not_before(public.household_time_zone(o.household_id),
                                                        m.age_group = 'kid', o.created_at)), 0::bigint,
  'each held for their own quiet hours, kid hours for a kid planner');
select is(public.night_dinner_at('00000000-0000-0000-0000-0000000004a1'),
  ((public.household_today('00000000-0000-0000-0000-0000000000a0') + time '23:00')
    at time zone public.household_time_zone('00000000-0000-0000-0000-0000000000a0')),
  'dinner is the night''s time on the household''s clock');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'not_home'), 0::bigint,
  '"I''ll be home" calls off what hasn''t gone');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'not_home'), 2::bigint,
  'a no again queues it again, since nothing went');
update public.push_outbox set sent_at = now() where kind = 'not_home';

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'not_home'), 2::bigint,
  'once it''s gone, taking it back leaves it');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false);
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'not_home'), 2::bigint,
  'and a no, back home, and no again doesn''t send twice');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3', false);
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('not_home') $$, $$ values ('Pam', 'Nora') $$,
  'a planner passing the phone for Nora isn''t told what they tapped themselves');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.night_attendance set expected = false
where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a3';
select pg_temp.as_postgres();
select is((select count(*) from pg_temp.queued('not_home')), 0::bigint,
  'a planner''s later write to that attendance calls it off, even one that leaves them out');

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a5', false);
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('not_home') $$, $$ values ('Alice', 'Pam') $$,
  'a planner who says it isn''t told about themselves');
delete from public.push_outbox;

update public.households set settings = settings || '{"notification_preset": "light"}'
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', false);
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', true);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nothing on Light, where there''s no check-in');

update public.households set settings = settings || '{"notification_preset": "engaged"}'
  || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
       'from', public.household_today('00000000-0000-0000-0000-0000000000a0'),
       'to', public.household_today('00000000-0000-0000-0000-0000000000a0'))))
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', false);
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', true);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nor on an away night');

update public.households set settings = settings - 'away_dates' where id = '00000000-0000-0000-0000-0000000000a0';
update public.plan_nights set dinner_time = '00:01' where id = '00000000-0000-0000-0000-0000000004a1';
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', false);
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', true);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nor once dinner time''s gone by');

update public.plan_nights set dinner_time = '23:00' where id = '00000000-0000-0000-0000-0000000004a1';
insert into public.meal_logs (household_id, night_id, quick_pick)
values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', 'takeout');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', false);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nor once dinner''s logged');
delete from public.meal_logs where night_id = '00000000-0000-0000-0000-0000000004a1';
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', false);
select pg_temp.as_postgres();
select is((select count(*) from pg_temp.queued('not_home')), 2::bigint, 'which is all that held Eve''s back');
delete from public.push_outbox;

-- Will cook -------------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.claim_night('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('claim') $$, $$ values ('Alice', 'Bob'), ('Pam', 'Bob') $$,
  'a claim goes to the planners with a device');
select results_eq(
  $$ select distinct o.args, o.night_id, o.claim_id = c.id, o.expires_at from public.push_outbox o
     join public.night_claims c on c.night_id = o.night_id and c.released_at is null where o.kind = 'claim' $$,
  $$ values ('{"name": "Bob"}'::jsonb, '00000000-0000-0000-0000-0000000004a2'::uuid, true,
             public.night_dinner_at('00000000-0000-0000-0000-0000000004a2')) $$,
  'with the cook''s first name only, the night and the claim, good until that dinner');
select is((select count(*) from public.push_outbox o join public.members m on m.id = o.member_id
           where o.kind = 'claim'
             and o.not_before <> public.push_not_before(public.household_time_zone(o.household_id),
                                                        m.age_group = 'kid', o.created_at)), 0::bigint,
  'held for each planner''s quiet hours');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.claim_night('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'claim'), 2::bigint,
  'offering again changes nothing, so nothing more is sent');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.release_claim((select id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000004a2'));
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'claim'), 0::bigint,
  'taking it back before it''s sent calls it off');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.claim_night('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a3');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('claim') $$, $$ values ('Pam', 'Nora') $$,
  'whoever entered it isn''t told');
update public.push_outbox set sent_at = now() where kind = 'claim';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.release_claim((select id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000004a3'));
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where kind = 'claim'), 1::bigint,
  'once it''s sent, taking it back leaves it');

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.claim_night('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a5');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('claim') $$, $$ values ('Alice', 'Pam') $$,
  'a planner''s own claim goes to the other planners');
delete from public.push_outbox;

insert into public.night_claims (household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a0', '00000000-0000-0000-0000-0000000000a4',
   '00000000-0000-0000-0000-0000000000a4');
select is((select count(*) from public.push_outbox), 0::bigint, 'not for a night gone by');

update public.households
set settings = settings || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
  'from', public.household_today('00000000-0000-0000-0000-0000000000a0') + 3,
  'to', public.household_today('00000000-0000-0000-0000-0000000000a0') + 3)))
where id = '00000000-0000-0000-0000-0000000000a0';
insert into public.night_claims (household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a4',
   '00000000-0000-0000-0000-0000000000a4');
select is((select count(*) from public.push_outbox), 0::bigint, 'not for an away night');
update public.night_claims set released_at = now() where night_id = '00000000-0000-0000-0000-0000000004a4';

update public.households set settings = (settings - 'away_dates') || '{"notification_preset": "light"}'
where id = '00000000-0000-0000-0000-0000000000a0';
insert into public.night_claims (household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a4',
   '00000000-0000-0000-0000-0000000000a4');
select is((select count(*) from public.push_outbox), 0::bigint, 'not on Light');
update public.night_claims set released_at = now() where night_id = '00000000-0000-0000-0000-0000000004a4';
update public.households set settings = settings - 'notification_preset' where id = '00000000-0000-0000-0000-0000000000a0';
insert into public.night_claims (household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a4',
   '00000000-0000-0000-0000-0000000000a4');
select is((select count(*) from public.push_outbox), 2::bigint, 'and with no preset saved, it''s Balanced, so it goes');

-- Another household -----------------------------------------------------------------------------------------------------------

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.answer_check_in('00000000-0000-0000-0000-0000000004b1', '00000000-0000-0000-0000-0000000000c2', false);
select pg_temp.as_postgres();
select results_eq(
  $$ select distinct household_id from public.push_outbox where member_id in
       (select id from public.members where household_id = '00000000-0000-0000-0000-0000000000a0') $$,
  $$ values ('00000000-0000-0000-0000-0000000000a0'::uuid) $$,
  'the Andersons hear only about their own family');
select results_eq(
  $$ select r.first_name, a.first_name from public.push_outbox o join public.members r on r.id = o.member_id
     join public.members a on a.id = o.about_member_id where o.household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  $$ values ('Carol', 'Dave') $$, 'and the Carters only about theirs');

-- Sending ---------------------------------------------------------------------------------------------------------------------

delete from public.push_outbox;
insert into public.push_outbox (id, household_id, member_id, kind, night_id, about_member_id, args, not_before, expires_at)
values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'not_home', '00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2', '{"name": "Bob"}',
   now() - interval '1 minute', now() + interval '1 hour'),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'claim', '00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2', '{"name": "Bob"}',
   now() - interval '1 hour', now() - interval '1 minute');

set local role service_role;
select results_eq(
  $$ select id, kind, week_start, night_id, night_date, args, attempts from public.claim_push_outbox(10) $$,
  $$ values ('00000000-0000-0000-0000-0000000005a1'::uuid, 'not_home', null::date,
             '00000000-0000-0000-0000-0000000004a2'::uuid,
             public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, '{"name": "Bob"}'::jsonb, 1) $$,
  'a row is handed over with its night, the night''s date and the name');
select is((select failed from public.push_outbox where id = '00000000-0000-0000-0000-0000000005a2'), 'stale',
  'one not sent by the time it expires is given up');
select public.complete_push_outbox('00000000-0000-0000-0000-0000000005a1', 'sent');
select results_eq($$ select member_id, type, channel, night_id from public.notification_log $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, 'not_home', 'push', '00000000-0000-0000-0000-0000000004a2'::uuid) $$,
  'and a sent one is logged with its new kind');

-- Leaving -----------------------------------------------------------------------------------------------------------------------

select pg_temp.as_postgres();
insert into public.push_outbox (household_id, member_id, kind, night_id, about_member_id, args, not_before) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'claim',
   '00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2', '{"name": "Bob"}', now());
update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a2';
select is((select count(*) from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a2'), 0::bigint,
  'someone removed takes along what was waiting about them, so their name doesn''t go out');
select is((select count(*) from public.push_outbox), 0::bigint, 'and nothing else is left');

select * from finish();
rollback;
