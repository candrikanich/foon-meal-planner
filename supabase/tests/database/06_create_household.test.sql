-- create_household (#8): the household and the owner's guardian profile, in one transaction.
begin;
select plan(8);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'erin@example.com', 'authenticated', 'authenticated');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select is((public.create_household(' The Daltons ', '🌮', ' Dave ')).name, 'The Daltons',
  'create_household returns the new household, trimmed');
select is((select count(*)::int from public.households), 1, 'the owner sees their household');
select results_eq(
  $$ select first_name, role::text, age_group::text, guardian, user_id from public.members $$,
  $$ values ('Dave', 'planner', 'adult', true, 'd0000000-0000-0000-0000-00000000000d'::uuid) $$,
  'the owner''s profile is an adult guardian planner linked to them');
select throws_ok($$ select public.create_household('Second', null, 'Dave') $$,
  '42501', null, 'one household per person');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.create_household('The Ellises', null, '   ') $$,
  '23514', null, 'a blank first name is refused');
select is_empty($$ select 1 from public.households $$, 'a failed create leaves no household behind');
select is((public.create_household('The Ellises', '', 'Erin')).emoji, null, 'a blank emoji is stored as none');

select set_config('role', 'anon', true);
select throws_ok($$ select public.create_household('Anon', null, 'X') $$,
  '42501', null, 'anon cannot create households');

select * from finish();
rollback;
