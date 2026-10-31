-- An idea keeps the dish it's linked to (#155): a stale phone can't re-point it.
begin;
select plan(7);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Chili again');
insert into public.requests (id, household_id, requested_by_member_id, title) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0',
   '00000000-0000-0000-0000-0000000000a1', 'Chili');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select lives_ok($$ select public.update_request('00000000-0000-0000-0000-0000000005a1', null, null, false,
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'an idea with no dish links to one');
select lives_ok($$ select public.update_request('00000000-0000-0000-0000-0000000005a1', null, null, false,
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'the same dish again is fine, so a retry works');
select throws_ok($$ select public.update_request('00000000-0000-0000-0000-0000000005a1', null, null, false,
  '00000000-0000-0000-0000-0000000002a2', null, null) $$, 'FD014', null, 'another dish is refused');
select is((select meal_id from public.requests where id = '00000000-0000-0000-0000-0000000005a1'),
  '00000000-0000-0000-0000-0000000002a1'::uuid, 'and the idea keeps its dish');
select lives_ok($$ select public.update_request('00000000-0000-0000-0000-0000000005a1', 'special', null, false,
  null, null, null) $$, 'other changes to a linked idea still work');
select is((select status::text from public.requests where id = '00000000-0000-0000-0000-0000000005a1'), 'special',
  'and they land');
select throws_ok($$ select public.update_request('00000000-0000-0000-0000-0000000005a1', null, null, false,
  '00000000-0000-0000-0000-0000000002ff', null, null) $$, 'P0002', null, 'a dish that does not exist is still P0002');

select * from finish();
rollback;
