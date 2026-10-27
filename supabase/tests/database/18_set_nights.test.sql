-- This Week (#23): set_nights writes Build my week's picks (meal or quick pick, plus the reason chip)
-- for several nights in one transaction.
begin;
select plan(13);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Carters'' chili');

select has_column('public', 'plan_nights', 'reason', 'nights carry the reason chip');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
create temp table week on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
grant select on week to authenticated;
create temp table nights on commit drop as
  select id, date from public.plan_nights where plan_id = (select id from week) order by date;
grant select on nights to authenticated;

select lives_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(
       jsonb_build_object('id', %L, 'meal_id', '00000000-0000-0000-0000-0000000002a1', 'reason', 'Haven''t had it in 3 weeks'),
       jsonb_build_object('id', %L, 'quick_pick', 'takeout', 'reason', 'Takeout on the busiest night'))) $$,
  (select id from week),
  (select id from nights where date = '2026-11-02'),
  (select id from nights where date = '2026-11-03')), 'a planner saves a draft');
select results_eq(
  $$ select date, meal_id, quick_pick::text, reason from public.plan_nights where plan_id = (select id from week)
     and date in ('2026-11-02', '2026-11-03') order by date $$,
  $$ values ('2026-11-02'::date, '00000000-0000-0000-0000-0000000002a1'::uuid, null::text, 'Haven''t had it in 3 weeks'),
            ('2026-11-03', null, 'takeout', 'Takeout on the busiest night') $$,
  'each night holds its pick and reason');
select lives_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(jsonb_build_object('id', %L))) $$,
  (select id from week), (select id from nights where date = '2026-11-02')), 'a night can be cleared');
select is((select (meal_id, quick_pick, reason)::text from public.plan_nights
           where id = (select id from nights where date = '2026-11-02')), '(,,)', 'cleared');

select throws_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(
       jsonb_build_object('id', %L, 'meal_id', '00000000-0000-0000-0000-0000000002b1'))) $$,
  (select id from week), (select id from nights where date = '2026-11-04')),
  '23503', null, 'another household''s meal cannot be planned');
select throws_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(
       jsonb_build_object('id', %L, 'meal_id', '00000000-0000-0000-0000-0000000002a1', 'quick_pick', 'takeout'))) $$,
  (select id from week), (select id from nights where date = '2026-11-04')),
  '23514', null, 'a night holds a meal or a quick pick, not both');
select throws_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(jsonb_build_object('id', %L, 'reason', repeat('x', 81)))) $$,
  (select id from week), (select id from nights where date = '2026-11-04')),
  '23514', null, 'reasons stay short');
select throws_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(jsonb_build_object('id', gen_random_uuid()))) $$,
  (select id from week)),
  'P0002', null, 'a night from another plan is refused');

update public.plan_nights set locked = true, meal_id = '00000000-0000-0000-0000-0000000002a1'
  where id = (select id from nights where date = '2026-11-05');
select throws_ok(format(
  $$ select public.set_nights(%L, jsonb_build_array(
       jsonb_build_object('id', %L, 'quick_pick', 'takeout'),
       jsonb_build_object('id', %L))) $$,
  (select id from week), (select id from nights where date = '2026-11-06'), (select id from nights where date = '2026-11-05')),
  'P0002', null, 'a locked night is refused, even if another device hasn''t seen the lock');
select is((select (meal_id, quick_pick)::text from public.plan_nights
           where id = (select id from nights where date = '2026-11-06')), '(,)',
  'and nothing else in that write is saved');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(format($$ select public.set_nights(%L, '[]') $$, (select id from week)),
  '42501', null, 'a member who is not a planner cannot plan nights');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(format($$ select public.set_nights(%L, '[]') $$, (select id from week)),
  'P0002', null, 'another household''s plan is not found');

select * from finish();
rollback;
