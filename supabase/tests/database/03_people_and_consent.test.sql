-- People rules and allergy consent (#75, #78): adult/kid, planner/member, guardians (parents),
-- ownership from households.owner, member removal, and the consent log.
begin;
select plan(60);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Alice (owner, guardian), Paul (guardian, planner), Grace (grandma: adult planner,
-- not a guardian), Tess (kid planner), Kim (kid), Nora (kid, unclaimed), Mo (guardian whose role is
-- Member), Ed (guardian, unclaimed). Household B: Carol.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a2', 'paul@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a3', 'grace@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a4', 'tess@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a5', 'kim@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a7', 'mo@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true, 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Paul', 'planner', 'adult', true, 'a0000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'a0000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Tess', 'planner', 'kid', false, 'a0000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false, 'a0000000-0000-0000-0000-0000000000a5'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Mo', 'member', 'adult', true, 'a0000000-0000-0000-0000-0000000000a7'),
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a0', 'Ed', 'member', 'adult', true, null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'c0000000-0000-0000-0000-00000000000c');
insert into public.consents (household_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000b0', 'allergy_data', 'c0000000-0000-0000-0000-00000000000c', 'test-v1');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000c1', 'peanuts');

-- Types -------------------------------------------------------------------------------------
select is(enum_range(null::public.member_role)::text, '{planner,member}', 'roles are planner and member only');
select is(enum_range(null::public.member_status)::text, '{active,away,removed}', 'members can be removed');
select is(enum_range(null::public.subscription_status)::text, '{none,trial,active,lapsed,cancelled}',
  'subscriptions can be cancelled');
select throws_ok(
  $$ update public.members set guardian = true where id = '00000000-0000-0000-0000-0000000000a6' $$,
  '23514', null, 'only adults are guardians');

-- Allergy consent: guardians only -----------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'milk') $$,
  '42501', null, 'no allergy is stored before the household opts in');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select throws_ok(
  $$ insert into public.consents (household_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'v1') $$,
  '42501', null, 'a grandparent cannot opt the household in');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a5');  -- Kim
select throws_ok(
  $$ insert into public.consents (household_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'v1') $$,
  '42501', null, 'a kid cannot give consent');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok(
  $$ insert into public.consents (household_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000b0', 'allergy_data', 'v1') $$,
  '42501', null, 'nobody consents for another household');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select lives_ok(
  $$ insert into public.consents (household_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'v1') $$,
  'a guardian opts the household in');
select is((select granted_by from public.consents where household_id = '00000000-0000-0000-0000-0000000000a0'),
  'a0000000-0000-0000-0000-0000000000a2'::uuid, 'consent records who gave it');
select throws_ok(
  $$ insert into public.consents (household_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'v1') $$,
  '23505', null, 'one active consent of a kind per household');
select throws_ok(
  $$ insert into public.consents (household_id, kind, text_version, granted_by) values
       ('00000000-0000-0000-0000-0000000000a0', 'parental', 'v1', 'a0000000-0000-0000-0000-00000000000a') $$,
  '42501', null, 'consent cannot be recorded in someone else''s name');
select throws_ok(
  $$ insert into public.consents (household_id, member_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'allergy_data', 'v1') $$,
  '23514', null, 'allergy consent is household-wide');
select throws_ok(
  $$ insert into public.consents (household_id, member_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'parental', 'v1') $$,
  '42501', null, 'parental consent is only for a kid''s profile');
select lives_ok(
  $$ insert into public.consents (household_id, member_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'parental', 'v1') $$,
  'a guardian gives parental consent for a kid');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Dave, no household
select is(public.has_active_consent('00000000-0000-0000-0000-0000000000a0', 'allergy_data'), false,
  'outsiders cannot learn whether a household stores allergies');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select throws_ok(
  $$ insert into public.consents (household_id, member_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'parental', 'v1') $$,
  '42501', null, 'a grandparent cannot give parental consent');
update public.consents set revoked_at = now() where household_id = '00000000-0000-0000-0000-0000000000a0';
select is((select count(*)::int from public.consents
           where household_id = '00000000-0000-0000-0000-0000000000a0' and revoked_at is null), 2,
  'a grandparent cannot revoke consent');

-- Who edits allergies: guardians only; everyone sees them ------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select lives_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'milk'),
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'sesame'),
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'eggs'),
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'fish') $$,
  'a guardian adds anyone''s allergies');
select lives_ok(
  $$ delete from public.member_allergies
     where member_id = '00000000-0000-0000-0000-0000000000a6' and category = 'sesame' $$,
  'a guardian removes an allergy');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'soy') $$,
  '42501', null, 'a grandparent cannot edit allergies, even their own');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'soy') $$,
  '42501', null, 'a grandparent cannot add a kid''s allergy');
select is((select count(*)::int from public.member_allergies), 3, 'a grandparent sees household allergies');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a4');  -- Tess
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'wheat') $$,
  '42501', null, 'a kid planner cannot add allergies');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a5');  -- Kim
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'wheat') $$,
  '42501', null, 'a kid cannot add their own allergy');
select is((select count(*)::int from public.member_allergies), 3, 'a kid sees household allergies');
delete from public.member_allergies;
update public.member_allergies set category = 'soy';

-- Managing people: guardians only ------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select throws_ok(
  $$ update public.members set role = 'member' where id = '00000000-0000-0000-0000-0000000000a5' $$,
  '42501', null, 'a non-guardian planner cannot change roles');
select throws_ok(
  $$ update public.members set guardian = true where id = '00000000-0000-0000-0000-0000000000a3' $$,
  '42501', null, 'nobody makes themselves a guardian');
select lives_ok(
  $$ update public.members set avatar = 'owl' where id = '00000000-0000-0000-0000-0000000000a3' $$,
  'a non-guardian edits their own avatar');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a4');  -- Tess
select throws_ok(
  $$ insert into public.members (household_id, first_name) values ('00000000-0000-0000-0000-0000000000a0', 'Extra') $$,
  '42501', null, 'a kid planner cannot add members');
select throws_ok(
  $$ update public.members set age_group = 'adult' where id = '00000000-0000-0000-0000-0000000000a4' $$,
  '42501', null, 'a kid planner cannot make themselves an adult');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a5');  -- Kim
select throws_ok(
  $$ update public.members set age_group = 'adult' where id = '00000000-0000-0000-0000-0000000000a5' $$,
  '42501', null, 'a kid cannot make themselves an adult');
select throws_ok(
  $$ update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a5' $$,
  '42501', null, 'a kid cannot remove themselves');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select lives_ok(
  $$ update public.members set role = 'planner' where id = '00000000-0000-0000-0000-0000000000a5' $$,
  'a guardian changes roles');
select throws_ok(
  $$ update public.members set role = 'member' where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'a guardian cannot change the owner''s profile');
select throws_ok(
  $$ update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'a guardian cannot remove the owner');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok(
  $$ update public.members set guardian = false where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'the owner stays a guardian');
select throws_ok(
  $$ update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'the owner cannot remove themselves');

-- A guardian who isn't a planner still manages people ---------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a7');  -- Mo
select lives_ok(
  $$ update public.members set role = 'member' where id = '00000000-0000-0000-0000-0000000000a4' $$,
  'a guardian with the Member role changes roles');
select is((select role::text from public.members where id = '00000000-0000-0000-0000-0000000000a4'), 'member',
  'the role change took effect');
select lives_ok(
  $$ update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a8' $$,
  'a guardian with the Member role removes a member');
select pg_temp.as_admin();
select ok(not (select guardian from public.members where id = '00000000-0000-0000-0000-0000000000a8'),
  'a removed profile loses guardian rights');

-- Removing a member keeps their history and cuts off access -----------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select lives_ok(
  $$ update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a3' $$,
  'a guardian removes a member');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a3'), null,
  'removal unlinks the account');
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a3'), 2,
  'removal keeps the profile''s data');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace, removed
select is_empty($$ select 1 from public.members $$, 'a removed member loses access');
select lives_ok($$ insert into public.households (name) values ('Grace''s place') $$,
  'a removed member can start their own household');

-- Ownership transfer --------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select throws_ok(
  $$ update public.households set owner = 'a0000000-0000-0000-0000-0000000000a2'
     where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'only the owner transfers ownership');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok(
  $$ update public.households set owner = 'a0000000-0000-0000-0000-0000000000a4'
     where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'ownership goes only to a guardian');
select throws_ok(
  $$ update public.households set owner = null where id = '00000000-0000-0000-0000-0000000000a0' $$,
  '42501', null, 'clients cannot clear the owner');
select lives_ok(
  $$ update public.households set owner = 'a0000000-0000-0000-0000-0000000000a2'
     where id = '00000000-0000-0000-0000-0000000000a0' $$,
  'the owner transfers ownership to another guardian');
select throws_ok(
  $$ update public.members set role = 'member' where id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'the new owner''s profile is protected');

-- Revoking consent erases the household's allergy data ---------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select lives_ok(
  $$ update public.consents set revoked_at = '2099-01-01'
     where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data' $$,
  'a guardian revokes allergy consent');
select is((select revoked_at from public.consents
           where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data'), now(),
  'the revocation time is stamped by the database, not the client');
select throws_ok(
  $$ update public.consents set revoked_at = null
     where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data' $$,
  '42501', null, 'a revocation cannot be undone');
select throws_ok($$ delete from public.consents $$, '42501', null, 'the consent log is never deleted');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'milk') $$,
  '42501', null, 'no new allergies after revocation');

select pg_temp.as_admin();
select is((select count(*)::int from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'revocation deletes the household''s allergies');
select is((select count(*)::int from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000b0'), 1,
  'other households keep theirs');

-- The owner's first profile is a guardian automatically (onboarding) -----------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Dave
insert into public.households (id, name) values ('00000000-0000-0000-0000-0000000000d0', 'Daltons');
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d0', 'Dave', 'planner',
   'd0000000-0000-0000-0000-00000000000d');
select ok((select guardian from public.members where id = '00000000-0000-0000-0000-0000000000d1'),
  'the owner''s own profile becomes a guardian');

select * from finish();
rollback;
