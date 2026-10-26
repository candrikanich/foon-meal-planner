-- Households, members, allergies: tenancy, roles, and the member self-edit rule (#4).
begin;
select plan(51);

-- Impersonation: RLS reads the role and JWT claims PostgREST would set for a signed-in user.
create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');

-- Schema shape ------------------------------------------------------------------------------
select ok((select relrowsecurity from pg_class where oid = 'public.households'::regclass), 'RLS on households');
select ok((select relrowsecurity from pg_class where oid = 'public.members'::regclass), 'RLS on members');
select ok((select relrowsecurity from pg_class where oid = 'public.member_allergies'::regclass), 'RLS on member_allergies');

-- Household B, created directly (as the server would) ---------------------------------------
insert into public.households (id, name, emoji, owner) values
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', '🍝', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'owner',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c1', 'peanuts');

-- Alice creates household A through RLS -----------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select lives_ok(
  $$ insert into public.households (id, name, emoji) values ('00000000-0000-0000-0000-0000000000a0', 'Andersons', '🌮') $$,
  'a signed-in user creates a household they own');
select lives_ok(
  $$ insert into public.members (id, household_id, first_name, role, user_id) values
       ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'owner',
        'a0000000-0000-0000-0000-00000000000a') $$,
  'the owner adds themselves as the first member');
select lives_ok(
  $$ insert into public.members (id, household_id, first_name, role) values
       ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member'),
       ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member') $$,
  'the owner adds unclaimed profiles');
select lives_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'milk') $$,
  'the owner records an allergy');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'custom') $$,
  '23514', null, 'a custom allergy needs its text');
select throws_ok(
  $$ insert into public.households (name, owner) values ('Spoof', 'c0000000-0000-0000-0000-00000000000c') $$,
  '42501', null, 'nobody creates a household owned by someone else');
select throws_ok(
  $$ update public.households set founding = true where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'clients cannot set the founding flag');
select throws_ok(
  $$ update public.households set subscription_status = 'active' where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'clients cannot set subscription status');
select lives_ok(
  $$ update public.households set name = 'The Andersons', settings = '{"week_start": "sun"}'
     where id = '00000000-0000-0000-0000-0000000000a0' $$,
  'the owner edits household name and settings');
select throws_ok(
  $$ insert into public.members (household_id, first_name, role, user_id) values
       ('00000000-0000-0000-0000-0000000000a0', 'Alice again', 'member', 'a0000000-0000-0000-0000-00000000000a') $$,
  '23505', null, 'a user belongs to at most one member profile');
select throws_ok(
  $$ insert into public.members (household_id, first_name, role) values
       ('00000000-0000-0000-0000-0000000000a0', 'Second owner', 'owner') $$,
  '23505', null, 'a household has at most one owner profile');

-- Cross-household isolation (as Alice) ------------------------------------------------------
select is_empty($$ select 1 from public.households where id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household is invisible');
select is_empty($$ select 1 from public.members where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household''s members are invisible');
select is_empty($$ select 1 from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'another household''s allergies are invisible');
select throws_ok(
  $$ insert into public.members (household_id, first_name) values ('00000000-0000-0000-0000-0000000000b0', 'Intruder') $$,
  '42501', null, 'cannot add members to another household');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c1', 'soy') $$,
  '42501', null, 'cannot add allergies in another household');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000c1', 'soy') $$,
  '23503', null, 'an allergy cannot point at a member of another household');
update public.members set first_name = 'Hacked' where id = '00000000-0000-0000-0000-0000000000c1';
update public.households set name = 'Hacked' where id = '00000000-0000-0000-0000-0000000000b0';

-- Planner powers and limits (as Alice) ------------------------------------------------------
select lives_ok(
  $$ update public.members set status = 'away', away_until = '2026-12-20'
     where id = '00000000-0000-0000-0000-0000000000a3' $$,
  'a planner sets a member away with a return date');
select throws_ok(
  $$ update public.members set away_until = '2026-12-20' where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '23514', null, 'a return date only makes sense while away');
select throws_ok(
  $$ delete from public.members where id = '00000000-0000-0000-0000-0000000000a3' $$,
  '42501', null, 'members are never hard-deleted');
select throws_ok(
  $$ delete from public.member_allergies $$,
  '42501', null, 'allergies are not deleted through the API');
select throws_ok(
  $$ delete from public.households where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'households are not deleted through the API');
select throws_ok(
  $$ update public.members set user_id = 'd0000000-0000-0000-0000-00000000000d'
     where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'profiles are claimed only through the server');
select throws_ok(
  $$ update public.members set household_id = '00000000-0000-0000-0000-0000000000b0'
     where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'members cannot be moved to another household');

-- Bob claims his profile (the server does this, #9) -----------------------------------------
select pg_temp.as_admin();
update public.members set user_id = 'b0000000-0000-0000-0000-00000000000b' where id = '00000000-0000-0000-0000-0000000000a2';

-- Member powers and limits (as Bob) ---------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

select is((select count(*)::int from public.members), 3, 'a member sees everyone in their household');
select is((select count(*)::int from public.member_allergies), 1, 'a member sees household allergies');
select ok(public.is_household_member('00000000-0000-0000-0000-0000000000a0'), 'is_household_member is true for a member');
select ok(not public.is_household_planner('00000000-0000-0000-0000-0000000000a0'), 'is_household_planner is false for a member');
select lives_ok(
  $$ update public.members
     set avatar = 'fox', attendance_defaults = '{"mon": false}', notification_prefs = '{"preset": "light"}'
     where id = '00000000-0000-0000-0000-0000000000a2' $$,
  'a member edits their own avatar, schedule, and notification prefs');
select throws_ok(
  $$ update public.members set role = 'planner' where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'a member cannot change their own role');
select throws_ok(
  $$ update public.members set status = 'away' where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'a member cannot change their own status');
update public.members set avatar = 'hacked' where id = '00000000-0000-0000-0000-0000000000a3';
update public.member_allergies set category = 'eggs';
update public.households set name = 'Hacked';
select throws_ok(
  $$ insert into public.members (household_id, first_name) values ('00000000-0000-0000-0000-0000000000a0', 'Extra') $$,
  '42501', null, 'a member cannot add members');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'soy') $$,
  '42501', null, 'a member cannot add allergies');
select throws_ok(
  $$ insert into public.households (name) values ('Bob''s second household') $$,
  '42501', null, 'a user with a member profile cannot create another household');

-- Owner role is protected from other planners -----------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ update public.members set role = 'planner' where id = '00000000-0000-0000-0000-0000000000a2' $$,
  'the owner promotes a member to planner');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ update public.members set role = 'member' where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'a planner cannot demote the owner');
select throws_ok(
  $$ update public.members set role = 'owner' where id = '00000000-0000-0000-0000-0000000000a3' $$,
  '42501', null, 'a planner cannot make someone owner');
select throws_ok(
  $$ insert into public.members (household_id, first_name, role) values
       ('00000000-0000-0000-0000-0000000000a0', 'Usurper', 'owner') $$,
  '42501', null, 'a planner cannot add an owner profile');

-- Outsiders ---------------------------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select is_empty($$ select 1 from public.households $$, 'a user without a household sees no households');
select is_empty($$ select 1 from public.members $$, 'a user without a household sees no members');

select pg_temp.as_admin();
set local role anon;
select throws_ok($$ select 1 from public.members $$, '42501', null, 'anon has no access to members');

-- Attempts above changed nothing ------------------------------------------------------------
select pg_temp.as_admin();
select is((select first_name from public.members where id = '00000000-0000-0000-0000-0000000000c1'), 'Carol',
  'cross-household member update had no effect');
select is((select name from public.households where id = '00000000-0000-0000-0000-0000000000b0'), 'Carters',
  'cross-household household update had no effect');
select is((select avatar from public.members where id = '00000000-0000-0000-0000-0000000000a3'), null,
  'a member cannot edit someone else''s profile');
select is((select category::text from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a3'), 'milk',
  'a member cannot edit allergies');

-- Account deletion keeps the household and the profile's history ---------------------------
select lives_ok($$ delete from auth.users where id = 'a0000000-0000-0000-0000-00000000000a' $$,
  'an owner can delete their account');
select is((select owner from public.households where id = '00000000-0000-0000-0000-0000000000a0'), null,
  'the household survives with no owner');
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a1'), null,
  'the owner''s profile survives, unlinked');

select * from finish();
rollback;
