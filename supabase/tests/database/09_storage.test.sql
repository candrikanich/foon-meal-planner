-- Photo storage (#13): a private bucket where each household reads its own folder and planners write it.
begin;
select plan(13);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Alice (planner), Bob (member). Household B: Carol (planner).
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
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos');
insert into storage.objects (bucket_id, name) values
  ('household-photos', '00000000-0000-0000-0000-0000000000b0/meals/paella.jpg');

select is((select public from storage.buckets where id = 'household-photos'), false, 'the photo bucket is private');
select is((select allowed_mime_types from storage.buckets where id = 'household-photos'), '{image/jpeg}'::text[],
  'the bucket only accepts JPEG (the app re-encodes every photo)');

-- Planners write their own household's folder (as Alice) -----------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ insert into storage.objects (bucket_id, name) values
       ('household-photos', '00000000-0000-0000-0000-0000000000a0/meals/tacos.jpg') $$,
  'a planner uploads to their household''s folder');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values
       ('household-photos', '00000000-0000-0000-0000-0000000000b0/meals/spy.jpg') $$,
  '42501', null, 'nobody uploads into another household''s folder');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('household-photos', 'shared/meals/x.jpg') $$,
  '42501', null, 'uploads must sit under a household folder');
select is_empty(
  $$ select 1 from storage.objects where name like '00000000-0000-0000-0000-0000000000b0/%' $$,
  'another household''s photos are invisible');
select lives_ok(
  $$ update public.meals set photo_path = '00000000-0000-0000-0000-0000000000a0/meals/tacos.jpg'
     where id = '00000000-0000-0000-0000-0000000002a1' $$,
  'a meal points at a photo in its own household''s folder');
select throws_ok(
  $$ update public.meals set photo_path = '00000000-0000-0000-0000-0000000000b0/meals/paella.jpg'
     where id = '00000000-0000-0000-0000-0000000002a1' $$,
  '23514', null, 'a meal cannot point at another household''s photo');

-- Members read but don't write (as Bob) -----------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from storage.objects where bucket_id = 'household-photos'), 1,
  'a member sees their household''s photos');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values
       ('household-photos', '00000000-0000-0000-0000-0000000000a0/meals/bob.jpg') $$,
  '42501', null, 'a member who isn''t a planner cannot upload');

-- Other households and signed-out sessions (as Carol) --------------------------------------
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty(
  $$ select 1 from storage.objects where name like '00000000-0000-0000-0000-0000000000a0/%' $$,
  'Carol cannot see the Andersons'' photos');
update storage.objects set name = '00000000-0000-0000-0000-0000000000b0/meals/stolen.jpg'
where name = '00000000-0000-0000-0000-0000000000a0/meals/tacos.jpg';

select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-0000-0000-00000000000a', 'role', 'authenticated',
                    'session_id', 'dead0000-0000-0000-0000-000000000000')::text, true);
select is_empty($$ select 1 from storage.objects where bucket_id = 'household-photos' $$,
  'a signed-out session sees no photos');

select pg_temp.as_admin();
select is((select count(*)::int from storage.objects where name = '00000000-0000-0000-0000-0000000000a0/meals/tacos.jpg'), 1,
  'Carol''s attempt to move the photo had no effect');

select * from finish();
rollback;
