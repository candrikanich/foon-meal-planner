-- Retention cleanup (#286): set_meal_photo hands back the photo a meal pointed at before, so the app can delete it from
-- storage, and only the household's planners can change it; the daily job prunes import counts older than a week for
-- every account, not only on that account's next import.
begin;
select plan(13);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Ann (owner, planner) and Ben (an adult who isn't a planner), with Tacos. Household B: Carol (owner,
-- planner) with Paella.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true, 'active', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Paella');

-- Replacing a photo ---------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.set_meal_photo(uuid, text)', 'execute'),
  'signed-out callers can''t set a photo');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(
  public.set_meal_photo('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0/meals/one.jpg'),
  null, 'a dish''s first photo replaces nothing');
select is(
  public.set_meal_photo('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0/meals/two.jpg'),
  '00000000-0000-0000-0000-0000000000a0/meals/one.jpg', 'replacing it hands back the old photo, to delete');
select is((select photo_path from public.meals where id = '00000000-0000-0000-0000-0000000002a1'),
  '00000000-0000-0000-0000-0000000000a0/meals/two.jpg', 'and the dish shows the new one');
select throws_ok(
  $$ select public.set_meal_photo('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000b0/meals/x.jpg') $$,
  '23514', null, 'a dish can''t point at another household''s folder');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select throws_ok(
  $$ select public.set_meal_photo('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0/meals/ben.jpg') $$,
  '42501', null, 'someone who doesn''t plan can''t change a photo');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select throws_ok(
  $$ select public.set_meal_photo('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0/meals/carol.jpg') $$,
  '42501', null, 'another household''s planner can''t either');
select is(
  public.set_meal_photo('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0/meals/paella.jpg'),
  null, 'but sets her own dish''s photo');

select pg_temp.as_admin();
select is((select photo_path from public.meals where id = '00000000-0000-0000-0000-0000000002a1'),
  '00000000-0000-0000-0000-0000000000a0/meals/two.jpg', 'so Tacos still shows Ann''s photo');

-- Import counts --------------------------------------------------------------------------------------------------------
-- Ann imported 8 days ago, 7 days ago and today; Ben last imported a month ago and never again.
insert into public.import_usage (user_id, day, imports) values
  ('a0000000-0000-0000-0000-00000000000a', (now() at time zone 'utc')::date - 8, 3),
  ('a0000000-0000-0000-0000-00000000000a', (now() at time zone 'utc')::date - 7, 2),
  ('a0000000-0000-0000-0000-00000000000a', (now() at time zone 'utc')::date, 1),
  ('b0000000-0000-0000-0000-00000000000b', (now() at time zone 'utc')::date - 30, 5);

select is(public.anonymize_expired_profiles(), 0, 'nobody is due to be anonymized');
select is_empty(
  $$ select 1 from public.import_usage where user_id = 'b0000000-0000-0000-0000-00000000000b' $$,
  'an account that never imports again loses its old count');
select is((select string_agg(((now() at time zone 'utc')::date - day)::text, ',' order by day)
           from public.import_usage where user_id = 'a0000000-0000-0000-0000-00000000000a'), '7,0',
  'counts more than 7 days old go; the last week''s stay');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.claim_import_slot(), true, 'and the cap still counts today''s imports');

select * from finish();
rollback;
