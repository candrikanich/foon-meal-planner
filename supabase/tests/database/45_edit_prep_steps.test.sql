-- Prep steps through save_meal (#45): planners edit them, older builds leave them alone, and the limits hold.
begin;
select plan(16);

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
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name, servings, prep_steps) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos', 4,
   '[{"step": "Thaw the beef", "lead_hours": 24}]');

create function pg_temp.save(steps jsonb) returns public.meals language sql as $$
  select public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', null, null, '[]'::jsonb,
                          null, null, steps);
$$;

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(
  (public.save_meal('00000000-0000-0000-0000-0000000002a1', 'Tacos', 4::smallint, '{}', '{}', null, null, '[]'::jsonb)).prep_steps,
  '[{"step": "Thaw the beef", "lead_hours": 24}]'::jsonb, 'an older build''s save leaves them alone');
select is((pg_temp.save('[{"step": "Marinate", "lead_hours": 4}, {"step": "Chop ahead"}]')).prep_steps,
  '[{"step": "Marinate", "lead_hours": 4}, {"step": "Chop ahead"}]'::jsonb, 'a planner edits them, and a step can have no lead time');
select is((pg_temp.save('[]')).prep_steps, '[]'::jsonb, 'an empty list clears them');

select throws_ok($$ select pg_temp.save('{"step": "Marinate"}') $$, '22023', null, 'it has to be a list');
select throws_ok($$ select pg_temp.save('[{"step": "  ", "lead_hours": 4}]') $$, '22023', null, 'a step needs words');
select throws_ok($$ select pg_temp.save('[{"step": "Marinate", "lead_hours": 0}]') $$, '22023', null, 'a lead time can''t be zero');
select throws_ok($$ select pg_temp.save('[{"step": "Marinate", "lead_hours": 337}]') $$, '22023', null, 'or over two weeks');
select throws_ok($$ select pg_temp.save((select jsonb_agg(jsonb_build_object('step', 'Step', 'lead_hours', 1)) from generate_series(1, 11))) $$,
  '22023', null, 'and there can be 10 at most');
select throws_ok($$ select pg_temp.save('[{"step": "\t\n"}]') $$, '22023', null, 'white space isn''t words');
select throws_ok($$ select pg_temp.save('[1]') $$, '22023', null, 'each step is an object');
select throws_ok($$ select pg_temp.save('[{"step": "Marinate", "lead_hours": 1.5}]') $$, '22023', null, 'lead times are whole hours');
select throws_ok($$ select pg_temp.save('[{"step": "Marinate", "note": "x"}]') $$, '22023', null, 'and nothing else comes along');

select throws_ok($$ update public.meals set prep_steps = '[{"step": 1}]' where id = '00000000-0000-0000-0000-0000000002a1' $$,
  '23514', null, 'writing the column directly has the same limits, so a bad row can''t reach the app');
select lives_ok($$ update public.meals set prep_steps = '[{"step": "Soak", "lead_hours": 8}]' where id = '00000000-0000-0000-0000-0000000002a1' $$,
  'and a good one still goes');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select pg_temp.save('[{"step": "Marinate", "lead_hours": 4}]') $$, '42501', null, 'a member can''t edit them');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select pg_temp.save('[{"step": "Marinate", "lead_hours": 4}]') $$, 'P0002', null, 'and another household can''t find the dish');

select * from finish();
rollback;
