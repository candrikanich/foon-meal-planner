-- "Wasn't home" (#42, part 2): for yourself, or for a profile nobody has claimed, on a night that's happened.
begin;
select plan(8);

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
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1);
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1);
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 30);
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 30);
insert into public.night_attendance (household_id, plan_night_id, member_id, expected) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true);

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2') $$,
  'Bob says he wasn''t home last night');
select lives_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3') $$,
  'and, passing the phone, that Nora wasn''t either (no row for her yet)');
select results_eq(
  $$ select member_id, expected from public.night_attendance where plan_night_id = '00000000-0000-0000-0000-0000000004a1'
     order by member_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid, false), ('00000000-0000-0000-0000-0000000000a3'::uuid, false) $$,
  'both are marked away for that night');
select throws_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'not for someone with their own account');
select throws_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2') $$,
  '22023', null, 'not for a night that hasn''t happened');
select throws_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a2') $$,
  '22023', null, 'or one more than a week ago: that''s history');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3') $$,
  'P0002', null, 'another household can''t touch it');
select throws_ok($$ select public.set_not_home('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000c1') $$,
  'P0002', null, 'even for themselves');

select * from finish();
rollback;
