-- The Engaged new-ideas digest goes between 8:30 and 9pm on the household's clock (Q1): after a later dinner has settled,
-- and still before quiet hours.
begin;
select plan(7);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

create function pg_temp.at_a(t time) returns timestamptz language sql as $$
  select (public.household_today('00000000-0000-0000-0000-0000000000a0') + t)
         at time zone public.household_time_zone('00000000-0000-0000-0000-0000000000a0');
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');

-- A clock where it's about noon now, so this evening is still ahead whenever the tests run.
update public.households
set settings = settings || jsonb_build_object('notification_preset', 'engaged', 'time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select extract(hour from now() at time zone 'UTC')::int - 12 as k) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_postgres();

insert into public.requests (household_id, requested_by_member_id, entered_by_member_id, title, status, created_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Ramen', 'open', now() - interval '1 hour');

select is(public.enqueue_request_digests(pg_temp.at_a('19:45')), 0, 'not at the old 7:30 to 9 window''s 7:45 run');
select is(public.enqueue_request_digests(pg_temp.at_a('20:15')), 0, 'not before 8:30pm');
select is(public.enqueue_request_digests(pg_temp.at_a('21:00')), 0, 'not from 9pm, when quiet hours begin');
select is(public.enqueue_request_digests(pg_temp.at_a('20:30')), 1, 'from 8:30pm');
select is((select expires_at from public.push_outbox where kind = 'new_requests'),
  (public.household_today('00000000-0000-0000-0000-0000000000a0') + time '21:00')
    at time zone public.household_time_zone('00000000-0000-0000-0000-0000000000a0'),
  'good until 9pm');
select is(public.enqueue_request_digests(pg_temp.at_a('20:45')), 0, 'once a day');

delete from public.push_outbox;
select is(public.enqueue_request_digests(pg_temp.at_a('20:45')), 1, 'the window''s last run, at 8:45, still sends it');

select * from finish();
rollback;
