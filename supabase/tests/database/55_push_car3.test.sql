-- Server push, car 3 (#40 part 2): an urgent list item reaches the other adults on every preset, coalesced; a tonight poll
-- reaches whoever can vote, on Engaged; "Your idea made Friday" reaches whoever asked, on Engaged, once a request.
begin;
select plan(43);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

-- What's waiting, as (recipient, about whom).
create function pg_temp.queued(target_kind text) returns table (recipient text, about text) language sql as $$
  select r.first_name, a.first_name from public.push_outbox o
  join public.members r on r.id = o.member_id left join public.members a on a.id = o.about_member_id
  where o.kind = target_kind and o.sent_at is null and o.failed is null order by r.first_name;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kim@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'eli@example.com', 'authenticated', 'authenticated'),
  ('90000000-0000-0000-0000-000000000009', 'quinn@example.com', 'authenticated', 'authenticated'),
  ('70000000-0000-0000-0000-000000000007', 'gil@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');

-- A clock for both households where it's about noon now, whenever the tests run, so tonight's dinner is still ahead and
-- adults aren't in quiet hours.
update public.households
set settings = settings || jsonb_build_object('time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select extract(hour from now() at time zone 'UTC')::int - 12 as k) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Eli', 'member', false, 'adult',
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Quinn', 'member', false, 'adult',
   '90000000-0000-0000-0000-000000000009'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Gil', 'member', false, 'adult',
   '70000000-0000-0000-0000-000000000007'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b0', 'Dave', 'member', false, 'adult',
   'd0000000-0000-0000-0000-00000000000d');
update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a4';

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
  ('00000000-0000-0000-0000-0000000004b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000003b1',
   public.household_today('00000000-0000-0000-0000-0000000000b0'), '23:00');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Milk'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Eggs'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Bread'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'Butter'),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'Milk');

-- Everyone with an account has a device but Quinn.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.register_push_device(repeat('e3', 32), 'sandbox');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.register_push_device(repeat('f4', 32), 'sandbox');
select pg_temp.as_user('70000000-0000-0000-0000-000000000007');
select public.register_push_device(repeat('a7', 32), 'sandbox');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.register_push_device(repeat('c1', 32), 'sandbox');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.register_push_device(repeat('d2', 32), 'sandbox');

-- Urgent list item, on Light ------------------------------------------------------------------------------------------------------

select pg_temp.as_postgres();
update public.households set settings = settings || '{"notification_preset": "light"}';

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight');
select throws_ok($$ update public.list_items set urgent_by = null $$, '42501', null,
  'nobody writes who marked a line directly');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('urgent_item') $$,
  $$ values ('Alice', 'Bob'), ('Eli', 'Bob'), ('Gil', 'Bob') $$,
  'something for tonight goes to the other adults with a device, on Light too: not a kid, not whoever added it');
select results_eq($$ select distinct args, night_id, expires_at from public.push_outbox $$,
  $$ values ('{"name": "Bob"}'::jsonb, '00000000-0000-0000-0000-0000000004a1'::uuid,
             public.night_dinner_at('00000000-0000-0000-0000-0000000004a1')) $$,
  'with the first name only, never the item, good until tonight''s dinner');
select is((select urgent_by from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'the line remembers who marked it');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick', 'tonight');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3', 'quick');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4', 'quick', 'whenever',
                          'staple');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 3::bigint,
  'a second one waits behind the first, and an ordinary tap or an Out-add tells no one');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.list_items set checked_at = now() where item_id = '00000000-0000-0000-0000-0000000001a1';
select pg_temp.as_postgres();
select is((select count(*) from pg_temp.queued('urgent_item')), 3::bigint,
  'buying one leaves it while Bob still has something else for tonight');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
delete from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2';
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'once nothing of his is left for tonight, it''s called off');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.list_items set urgency = 'tonight' where item_id = '00000000-0000-0000-0000-0000000001a3';
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('urgent_item') $$,
  $$ values ('Bob', 'Alice'), ('Eli', 'Alice'), ('Gil', 'Alice') $$, 'marking a line for tonight counts as adding it');
update public.push_outbox set sent_at = now() - interval '1 hour';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3', 'quick', 'tonight');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 3::bigint, 'adding it for tonight again to a line that already was isn''t news');

update public.push_outbox set sent_at = now() - interval '5 minutes';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick', 'tonight');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 3::bigint, 'nor within 15 minutes of the last one');
update public.push_outbox set sent_at = now() - interval '20 minutes';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight');
select pg_temp.as_postgres();
select is((select count(*) from pg_temp.queued('urgent_item')), 3::bigint, 'after that, it goes again');

delete from public.push_outbox;
delete from public.list_items;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'weekly', 'tonight');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'only the quick list');

delete from public.list_items;
update public.households
set settings = settings || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
  'from', public.household_today('00000000-0000-0000-0000-0000000000a0'),
  'to', public.household_today('00000000-0000-0000-0000-0000000000a0'))))
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'not when the family''s away tonight');

delete from public.list_items;
update public.households set settings = settings - 'away_dates' where id = '00000000-0000-0000-0000-0000000000a0';
update public.plan_nights set dinner_time = '00:01' where id = '00000000-0000-0000-0000-0000000004a1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight');
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'nor once tonight''s dinner time has gone by');
update public.plan_nights set dinner_time = '23:00' where id = '00000000-0000-0000-0000-0000000004a1';

delete from public.list_items;
update public.members set status = 'away' where id = '00000000-0000-0000-0000-0000000000a7';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('urgent_item') $$, $$ values ('Alice', 'Bob'), ('Eli', 'Bob') $$,
  'not to someone travelling, who can''t pick it up');
update public.members set status = 'active' where id = '00000000-0000-0000-0000-0000000000a7';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.list_items set checked_at = now() where item_id = '00000000-0000-0000-0000-0000000001a1';
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'someone else buying it calls it off too');

delete from public.list_items;
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'weekly');
select public.move_to_quick_list((select id from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2'),
  '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', null, gen_random_uuid());
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, '"Couldn''t find it" moving a line to the quick list tells no one');

delete from public.list_items;
delete from public.plan_nights where id = '00000000-0000-0000-0000-0000000004b1';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.add_to_list('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000001b1', 'quick', 'tonight');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('urgent_item') $$, $$ values ('Dave', 'Carol') $$,
  'another household hears only about its own');
select results_eq($$ select night_id, expires_at from public.push_outbox $$,
  $$ values (null::uuid, ((public.household_today('00000000-0000-0000-0000-0000000000b0') + time '18:00')
                          at time zone public.household_time_zone('00000000-0000-0000-0000-0000000000b0'))) $$,
  'with no night tonight, the household''s dinner time says when it stops being news');
insert into public.plan_nights (id, household_id, plan_id, date, dinner_time) values
  ('00000000-0000-0000-0000-0000000004b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000003b1',
   public.household_today('00000000-0000-0000-0000-0000000000b0'), '23:00');
delete from public.push_outbox;

-- Tonight poll ----------------------------------------------------------------------------------------------------------------------

update public.households set settings = settings || '{"notification_preset": "engaged"}';
insert into public.night_attendance (household_id, plan_night_id, member_id, expected) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false);

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 180,
  '[{"quick_pick": "takeout"}, {"quick_pick": "leftovers"}]');
select pg_temp.as_postgres();
-- Three hours, so a kid held by school hours (to 3pm) still hears before it closes, whatever day the tests run.
select results_eq($$ select * from pg_temp.queued('tonight_poll') $$, $$ values ('Gil', 'Alice'), ('Kim', 'Alice') $$,
  'a poll goes to whoever can vote: not whoever started it, someone out tonight, or someone who eats separately');
select results_eq($$ select distinct o.args, o.night_id, o.expires_at = p.closes_at from public.push_outbox o
                     join public.polls p on p.night_id = o.night_id $$,
  $$ values ('{"name": "Alice"}'::jsonb, '00000000-0000-0000-0000-0000000004a1'::uuid, true) $$,
  'with the starter''s first name, about tonight, good until the poll closes');
select is((select count(*) from public.push_outbox o join public.members m on m.id = o.member_id
           where o.not_before <> public.push_not_before(public.household_time_zone(o.household_id),
                                                        m.age_group = 'kid', o.created_at)), 0::bigint,
  'a kid waits for kid quiet hours');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.close_poll((select id from public.polls));
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'ending it early calls off what hasn''t gone');

update public.households set settings = settings || '{"notification_preset": "balanced"}'
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 180,
  '[{"quick_pick": "takeout"}, {"quick_pick": "leftovers"}]');
select public.close_poll((select id from public.polls order by closes_at desc limit 1));
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'only on Engaged');

update public.households set settings = settings || '{"notification_preset": "engaged"}'
  || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
       'from', public.household_today('00000000-0000-0000-0000-0000000000a0'),
       'to', public.household_today('00000000-0000-0000-0000-0000000000a0'))))
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 180,
  '[{"quick_pick": "takeout"}, {"quick_pick": "leftovers"}]');
select public.close_poll((select id from public.polls order by closes_at desc limit 1));
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox), 0::bigint, 'not on an away night');
update public.households set settings = settings - 'away_dates' where id = '00000000-0000-0000-0000-0000000000a0';

insert into public.push_outbox (household_id, member_id, kind, night_id, about_member_id, args, not_before, expires_at)
values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7', 'tonight_poll',
        '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1', '{"name": "Alice"}',
        now() - interval '10 minutes', now() - interval '1 second');
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10)), 0::bigint, 'a poll that''s closed isn''t sent');
select pg_temp.as_postgres();
select is((select failed from public.push_outbox), 'stale', 'it''s given up');
delete from public.push_outbox;

-- Your idea made the plan ---------------------------------------------------------------------------------------------------------

insert into public.requests (id, household_id, requested_by_member_id, entered_by_member_id, title, status, planned_night_id)
values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-0000000000a2', 'Crab legs', 'planned', '00000000-0000-0000-0000-0000000004a2'),
  ('00000000-0000-0000-0000-0000000006a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3',
   '00000000-0000-0000-0000-0000000000a3', 'Tacos', 'planned', '00000000-0000-0000-0000-0000000004a1'),
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-0000000000a2', 'Soup', 'planned', '00000000-0000-0000-0000-0000000004a0'),
  ('00000000-0000-0000-0000-0000000006a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1', 'Pie', 'planned', '00000000-0000-0000-0000-0000000004a2'),
  ('00000000-0000-0000-0000-0000000006a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6',
   '00000000-0000-0000-0000-0000000000a1', 'Pasta', 'planned', '00000000-0000-0000-0000-0000000004a2'),
  ('00000000-0000-0000-0000-0000000006a6', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7',
   '00000000-0000-0000-0000-0000000000a7', 'Curry', 'open', null),
  ('00000000-0000-0000-0000-0000000006a7', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7',
   '00000000-0000-0000-0000-0000000000a1', 'Ramen', 'planned', '00000000-0000-0000-0000-0000000004a2'),
  ('00000000-0000-0000-0000-0000000006a8', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7',
   null, 'Stew', 'planned', '00000000-0000-0000-0000-0000000004a2'),
  ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c2',
   '00000000-0000-0000-0000-0000000000c2', 'Chili', 'planned', '00000000-0000-0000-0000-0000000004b1');

update public.households
set settings = settings || jsonb_build_object('away_dates', jsonb_build_array(jsonb_build_object(
  'from', public.household_today('00000000-0000-0000-0000-0000000000a0') + 1,
  'to', public.household_today('00000000-0000-0000-0000-0000000000a0') + 1)))
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('request_planned') $$, $$ values ('Kim', 'Kim') $$,
  'approving tells whoever asked that their idea made a night: not for a night gone by or an away night');
select results_eq($$ select args, night_id, request_id, expires_at from public.push_outbox where kind = 'request_planned' $$,
  $$ values ('{}'::jsonb, '00000000-0000-0000-0000-0000000004a1'::uuid, '00000000-0000-0000-0000-0000000006a2'::uuid,
             public.night_dinner_at('00000000-0000-0000-0000-0000000004a1')) $$,
  'with no name and no dish, good until that dinner');

update public.households set settings = settings - 'away_dates' where id = '00000000-0000-0000-0000-0000000000a0';
update public.plans set approved_at = null where id = '00000000-0000-0000-0000-0000000003a1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.queued('request_planned') $$,
  $$ values ('Bob', 'Bob'), ('Gil', 'Gil'), ('Kim', 'Kim') $$,
  'approving again tells only about ideas not told yet: not the approver''s own, not one a parent entered for someone, '
  'and one with no record of whose phone it was counts as the requester''s');

update public.households set settings = settings || '{"notification_preset": "balanced"}'
where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.approve_plan('00000000-0000-0000-0000-0000000003b1', '[]'::jsonb);
select pg_temp.as_postgres();
select is((select count(*) from public.push_outbox where household_id = '00000000-0000-0000-0000-0000000000b0'
             and kind = 'request_planned'), 0::bigint, 'only on Engaged');

delete from public.requests where id = '00000000-0000-0000-0000-0000000006a2';
select is((select count(*) from pg_temp.queued('request_planned')), 2::bigint, 'a request erased takes its push along');

update public.push_outbox
set not_before = case when request_id = '00000000-0000-0000-0000-0000000006a1' then now() - interval '1 minute'
                    else now() + interval '1 hour' end
where kind = 'request_planned';
update public.requests set status = 'open', planned_night_id = null where id = '00000000-0000-0000-0000-0000000006a1';
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10) where kind = 'request_planned'),
  0::bigint, 'an idea sent back to Someday before it goes isn''t told');
select pg_temp.as_postgres();
update public.requests set status = 'planned', planned_night_id = '00000000-0000-0000-0000-0000000004a1'
where id = '00000000-0000-0000-0000-0000000006a1';
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10) where kind = 'request_planned'),
  0::bigint, 'nor one moved to another night, which would say the wrong day');
select pg_temp.as_postgres();
select is((select count(*) from pg_temp.queued('request_planned') where recipient = 'Bob'), 1::bigint,
  'it waits rather than being given up');
update public.requests set planned_night_id = '00000000-0000-0000-0000-0000000004a2'
where id = '00000000-0000-0000-0000-0000000006a1';
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10) where kind = 'request_planned'),
  1::bigint, 'and goes once it''s back on that night');
select pg_temp.as_postgres();

-- Sending ---------------------------------------------------------------------------------------------------------------------

delete from public.push_outbox;
update public.requests set planned_night_id = '00000000-0000-0000-0000-0000000004a1'
where id = '00000000-0000-0000-0000-0000000006a1';
insert into public.push_outbox (id, household_id, member_id, kind, night_id, about_member_id, request_id, args, not_before)
values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'request_planned', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-0000000006a1', '{}', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'urgent_item', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1', null,
   '{"name": "Alice"}', now() - interval '1 minute');
set local role service_role;
select results_eq($$ select kind, night_id, args from public.claim_push_outbox(10) order by kind $$,
  $$ values ('request_planned', '00000000-0000-0000-0000-0000000004a1'::uuid, '{}'::jsonb),
            ('urgent_item', '00000000-0000-0000-0000-0000000004a1'::uuid, '{"name": "Alice"}'::jsonb) $$,
  'each is handed over with its night and args');
select pg_temp.as_postgres();
update public.push_outbox set claimed_until = null;
update public.plan_nights set dinner_time = '00:01' where id = '00000000-0000-0000-0000-0000000004a1';
set local role service_role;
select is((select count(*) from public.claim_push_outbox(10)), 0::bigint, 'moving dinner earlier than now');
select pg_temp.as_postgres();
select results_eq($$ select distinct failed from public.push_outbox $$, $$ values ('stale') $$, 'gives both up');

-- Leaving -----------------------------------------------------------------------------------------------------------------------

insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'urgent_item',
   '00000000-0000-0000-0000-0000000000a7', '{"name": "Gil"}', now()),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'tonight_poll',
   '00000000-0000-0000-0000-0000000000a7', '{"name": "Gil"}', now());
update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a7';
select is((select count(*) from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a7'), 0::bigint,
  'someone removed takes along what was waiting about them');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select * from public.push_outbox $$, '42501', null, 'and no client reads the outbox');

-- A kid's consent withdrawn ------------------------------------------------------------------------------------------------------

select pg_temp.as_postgres();
insert into public.list_items (household_id, item_id, list, urgency) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4', 'quick', 'tonight');
update public.list_items set urgent_by = '00000000-0000-0000-0000-0000000000a6'
where item_id = '00000000-0000-0000-0000-0000000001a4';
insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before, sent_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'urgent_item',
   '00000000-0000-0000-0000-0000000000a6', '{"name": "Nora"}', now(), null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'tonight_poll',
   '00000000-0000-0000-0000-0000000000a6', '{"name": "Nora"}', now(), now());
insert into public.consents (household_id, member_id, kind, granted_by, granted_at, revoked_at, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'parental',
   'a0000000-0000-0000-0000-00000000000a', now() - interval '90 days', now() - interval '31 days', 'v1');
select public.anonymize_expired_profiles();
select is((select count(*) from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a6'), 0::bigint,
  'a kid''s withdrawn consent takes the pushes about what they did, sent ones too');
select is((select urgent_by from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a4'), null::uuid,
  'and a line stops saying they marked it');

select * from finish();
rollback;
