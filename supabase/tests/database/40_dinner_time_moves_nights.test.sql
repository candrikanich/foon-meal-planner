-- Changing the household's dinner time moves tonight and later nights (#170). Past nights and other households stay put, and
-- the move isn't logged as a change to the plan, so it can't show in activity or mark the list stale.
begin;
select plan(9);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000005a0', '00000000-0000-0000-0000-0000000000a0', public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, now()),
  ('00000000-0000-0000-0000-0000000005b0', '00000000-0000-0000-0000-0000000000b0', public.household_today('00000000-0000-0000-0000-0000000000b0') - 1, null);
insert into public.plan_nights (id, household_id, plan_id, date, dinner_time) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a0', public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, '18:00'),
  ('00000000-0000-0000-0000-0000000006a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a0', public.household_today('00000000-0000-0000-0000-0000000000a0'), '18:00'),
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a0', public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, '18:00'),
  ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000005b0', public.household_today('00000000-0000-0000-0000-0000000000b0') + 1, '18:00');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"dinner_time": "19:30"}'::jsonb);
reset role;

select is((select dinner_time from public.plan_nights where id = '00000000-0000-0000-0000-0000000006a1'), '18:00'::time, 'last night keeps its time');
select is((select dinner_time from public.plan_nights where id = '00000000-0000-0000-0000-0000000006a2'), '19:30'::time, 'tonight moves');
select is((select dinner_time from public.plan_nights where id = '00000000-0000-0000-0000-0000000006a3'), '19:30'::time, 'tomorrow moves');
select is((select dinner_time from public.plan_nights where id = '00000000-0000-0000-0000-0000000006b1'), '18:00'::time, 'another household''s night stays');
select is_empty($$ select 1 from public.plan_changes where household_id = '00000000-0000-0000-0000-0000000000a0' $$, 'not logged as a plan change');
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000005a0'), false, 'the list isn''t behind because of it');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"new_dishes_per_week": 2}'::jsonb);
reset role;
select is((select dinner_time from public.plan_nights where id = '00000000-0000-0000-0000-0000000006a2'), '19:30'::time, 'saving another setting moves nothing');

update public.plan_nights set dinner_time = '18:00' where id = '00000000-0000-0000-0000-0000000006a2';
select throws_ok($$ select public.households_move_dinner_time() $$, '0A000', null, 'it only runs as a trigger');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"dinner_time": "07:00"}'::jsonb) $$, '42501', null,
  'another household can''t change it');
reset role;

select * from finish();
rollback;
