-- Per-member notification presets (#47): who can set whose, how a person's preset is read (a kid's never above the family's),
-- and that every push that depends on a preset reads the recipient's own.
begin;
select plan(33);

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

create function pg_temp.recipients(target_kind text) returns setof text language sql as $$
  select m.first_name from public.push_outbox o join public.members m on m.id = o.member_id
  where o.kind = target_kind order by m.first_name;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');

-- A clock where it's about noon now, so tonight's dinner and 8:30pm are still ahead and adults aren't in quiet hours.
update public.households
set settings = settings || jsonb_build_object('time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select extract(hour from now() at time zone 'UTC')::int - 12 as k) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'planner', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Dan', 'member', false, 'adult',
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Uma', 'member', false, 'adult', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');

-- Who sets whose ---------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', 'engaged') $$,
  'an adult sets their own');
select is((select notification_prefs ->> 'preset' from public.members where id = '00000000-0000-0000-0000-0000000000a3'),
  'engaged', 'and the family can read it');
select lives_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', null) $$,
  'and goes back to following the family');
select is((select notification_prefs ? 'preset' from public.members where id = '00000000-0000-0000-0000-0000000000a3'),
  false, 'with nothing saved of their own');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', 'loud') $$, '22023', null,
  'only Light, Balanced or Engaged');
select throws_ok($$ update public.members set notification_prefs = '{"preset": "engaged"}'
                    where id = '00000000-0000-0000-0000-0000000000a3' $$, '42501', null,
  'nobody writes it directly');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', 'light') $$, '42501', null,
  'a planner can''t change another adult''s');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a5', 'light') $$, '42501', null,
  'or a kid''s, without being a parent');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', 'light') $$, '42501', null,
  'a parent can''t change another adult''s either');
select lives_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a4', 'light') $$,
  'a parent sets a kid''s');
select lives_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a6', 'light') $$,
  'and an adult profile nobody has claimed, which nobody else can speak for');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a4', 'engaged') $$, '22023', null,
  'a kid''s can''t be more than the family''s');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a4', null) $$, '42501', null,
  'a kid doesn''t set their own');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', 'light') $$, 'P0002', null,
  'another family can''t set it');
select is((select count(*) from public.members where household_id = '00000000-0000-0000-0000-0000000000a0'), 0::bigint,
  'or read it');
select pg_temp.as_postgres();
set local role anon;
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a3', 'light') $$, '42501', null,
  'nor anyone signed out');
select pg_temp.as_postgres();

-- How it's read ---------------------------------------------------------------------------------------------------------------

select is(public.member_preset('00000000-0000-0000-0000-0000000000a1'), 'balanced', 'no preset of your own: the family''s');
update public.members set notification_prefs = '{"preset": "engaged"}' where id = '00000000-0000-0000-0000-0000000000a4';
select is(public.member_preset('00000000-0000-0000-0000-0000000000a4'), 'balanced',
  'a kid''s above the family''s (the family turned it down since) reads as the family''s');
select is(public.member_preset('00000000-0000-0000-0000-0000000000a6'), 'light', 'a lower one is theirs');
update public.members set notification_prefs = '{"preset": "loud"}' where id = '00000000-0000-0000-0000-0000000000a6';
select is(public.member_preset('00000000-0000-0000-0000-0000000000a6'), 'balanced', 'one that won''t read is ignored');
update public.members set notification_prefs = '{"preset": "light"}' where id = '00000000-0000-0000-0000-0000000000a4';

select results_eq(
  $$ select public.push_weekly_budget('00000000-0000-0000-0000-0000000000a1'), public.push_weekly_budget('00000000-0000-0000-0000-0000000000a4') $$,
  $$ values (12, 2) $$, 'budgets follow the person''s own preset: Alice Balanced, Kim Light');

-- Every push reads the recipient's ----------------------------------------------------------------------------------------------

-- Bob (planner) is on Light, Alice follows the family's Balanced.
update public.members set notification_prefs = '{"preset": "light"}' where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.register_push_device(repeat('d3', 32), 'sandbox');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.register_push_device(repeat('e4', 32), 'sandbox');
select pg_temp.as_postgres();

insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_nights (id, household_id, plan_id, date, dinner_time) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0'), '23:00'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, '23:00');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3', false);
select public.claim_night('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a3');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.recipients('not_home') $$, $$ values ('Alice') $$,
  'won''t be home skips a planner on Light, though the family is on Balanced');
select results_eq($$ select * from pg_temp.recipients('claim') $$, $$ values ('Alice') $$, 'and so does will cook');

-- Bob turns his up to Engaged; the family stays on Balanced.
delete from public.push_outbox;
update public.members set notification_prefs = '{"preset": "engaged"}' where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.start_store_run('00000000-0000-0000-0000-0000000000a0');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.recipients('heading_to_store') $$, $$ values ('Bob') $$,
  'heading to the store reaches someone on Engaged in a Balanced family, and nobody else');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 180,
  '[{"quick_pick": "takeout"}, {"quick_pick": "leftovers"}]');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.recipients('tonight_poll') $$, $$ values ('Bob') $$, 'so does a tonight poll');

insert into public.requests (household_id, requested_by_member_id, entered_by_member_id, title, status, planned_night_id,
                             created_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
   'Crab legs', 'planned', '00000000-0000-0000-0000-0000000004a2', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a3',
   'Tacos', 'planned', '00000000-0000-0000-0000-0000000004a2', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a3',
   'Soup', 'open', null, now() - interval '1 hour');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.recipients('request_planned') $$, $$ values ('Bob') $$,
  '"your idea made Friday" goes to whoever asked only when they''re on Engaged');
select results_eq($$ select * from pg_temp.recipients('plan_set') $$, $$ values ('Bob'), ('Dan'), ('Kim') $$,
  'Plan''s set goes on every preset, so nobody''s own changes it');

select is(public.enqueue_request_digests(pg_temp.at_a('20:30')), 1, 'the ideas digest');
select results_eq($$ select * from pg_temp.recipients('new_requests') $$, $$ values ('Bob') $$,
  'reaches a planner on Engaged in a Balanced family');

-- The family goes Engaged and Bob turns his down to Light.
delete from public.push_outbox;
delete from public.store_runs;
update public.households set settings = settings || '{"notification_preset": "engaged"}'
where id = '00000000-0000-0000-0000-0000000000a0';
update public.members set notification_prefs = '{"preset": "light"}' where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.start_store_run('00000000-0000-0000-0000-0000000000a0');
select pg_temp.as_postgres();
select results_eq($$ select * from pg_temp.recipients('heading_to_store') $$, $$ values ('Alice') $$,
  'in an Engaged family, someone on Light (Bob) and a kid turned down (Kim) don''t hear');
select is(public.push_weekly_budget('00000000-0000-0000-0000-0000000000a2'), 8, 'and Bob''s budget is Light''s');

-- Retention ---------------------------------------------------------------------------------------------------------------------

update public.members set notification_prefs = '{"preset": "engaged"}' where id = '00000000-0000-0000-0000-0000000000a3';
select public.delete_account_data('d0000000-0000-0000-0000-00000000000d');
select pg_temp.as_postgres();
update public.members set notification_prefs = '{"preset": "engaged"}' where id = '00000000-0000-0000-0000-0000000000a6';
update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a6';
select is((select notification_prefs from public.members where id = '00000000-0000-0000-0000-0000000000a3'), '{}'::jsonb,
  'deleting an account clears their notification settings with the rest');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.set_member_preset('00000000-0000-0000-0000-0000000000a6', 'light') $$, 'P0002', null,
  'and nobody sets a removed member''s');

select * from finish();
rollback;
