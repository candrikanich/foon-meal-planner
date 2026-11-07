-- Adults edit their own allergies one at a time (follow-up to #285): an adult who isn't a parent adds and removes single
-- allergies on their own profile, through the function or a row at a time, under the household's allergy agreement like
-- a parent. Never anyone else's, never a kid's, never another household's; a kid still can't touch their own; and a
-- parent can still add one back.
begin;
select plan(29);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.allergies(person uuid) returns int language sql as $$
  select count(*)::int from public.member_allergies where member_id = person;
$$;
create function pg_temp.has(person uuid, allergen public.allergen) returns boolean language sql as $$
  select exists (select 1 from public.member_allergies where member_id = person and category = allergen);
$$;

-- Household A agreed to keep allergy data: Ann (owner, parent), Grace and Hal (adults who aren't parents, signed in),
-- Kim (a kid, signed in), Ivy (a kid without an account). Household B agreed too: Carol (owner), Dan (an adult who isn't a
-- parent). Household C never agreed: Eve (owner, parent) and Fay (an adult who isn't a parent).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'hal@example.com', 'authenticated', 'authenticated'),
  ('70000000-0000-0000-0000-000000000007', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'dan@example.com', 'authenticated', 'authenticated'),
  ('e1000000-0000-0000-0000-0000000000e1', 'eve@example.com', 'authenticated', 'authenticated'),
  ('f1000000-0000-0000-0000-0000000000f1', 'fay@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000c0', 'Evanses', 'e1000000-0000-0000-0000-0000000000e1');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'active', 'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Hal', 'member', 'adult', false, 'active', 'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false, 'active', '70000000-0000-0000-0000-000000000007'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Ivy', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'adult', false, 'active', 'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c0', 'Eve', 'planner', 'adult', true, 'active', 'e1000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c0', 'Fay', 'member', 'adult', false, 'active', 'f1000000-0000-0000-0000-0000000000f1');
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', null, 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental', 'a0000000-0000-0000-0000-00000000000a', 'v1'),
  ('00000000-0000-0000-0000-0000000000b0', null, 'allergy_data', 'c0000000-0000-0000-0000-00000000000c', 'allergy-data-v1');
insert into public.member_allergies (household_id, member_id, category, custom_text) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'milk', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'peanuts', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'custom', 'kiwi'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'peanuts', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'sesame', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'wheat', null),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'eggs', null);

-- An adult who isn't a parent edits their own, one at a time -------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
-- She can have milk again, but not peanuts or kiwi.
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{peanuts}', '{kiwi}') $$,
  'an adult removes one of their own allergies');
select ok(not pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'milk')
          and pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'peanuts')
          and pg_temp.allergies('00000000-0000-0000-0000-0000000000a2') = 2,
  'and only that one goes');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{peanuts,shellfish}', '{kiwi}') $$,
  'an adult adds one to their own');
select ok(pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'shellfish')
          and pg_temp.allergies('00000000-0000-0000-0000-0000000000a2') = 3,
  'and the rest stay');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{peanuts,shellfish}', '{kiwi,mango}') $$,
  'Other too');
select lives_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'soy') $$,
  'a row at a time works too');
delete from public.member_allergies
where member_id = '00000000-0000-0000-0000-0000000000a2' and category = 'shellfish';
select ok(pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'soy')
          and not pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'shellfish')
          and pg_temp.allergies('00000000-0000-0000-0000-0000000000a2') = 4,
  'adding and removing single rows');
update public.member_allergies set category = 'fish'
where member_id = '00000000-0000-0000-0000-0000000000a2' and category = 'soy';
select ok(pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'soy'),
  'rewriting a row stays a parent''s: an edit is a removal and an addition');

-- Never anyone else's ----------------------------------------------------------------------------------------------------
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{peanuts,milk}', '{}') $$,
  '42501', null, 'an adult can''t add to another adult''s');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'milk') $$,
  '42501', null, 'not even a row at a time');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{}', '{}') $$,
  '42501', null, 'or remove theirs');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a5', '{wheat,milk}', '{}') $$,
  '42501', null, 'or add to a kid''s');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'milk') $$,
  '42501', null, 'a row at a time either');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'milk') $$,
  '42501', null, 'or to a parent''s');
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a3') + pg_temp.allergies('00000000-0000-0000-0000-0000000000a5')
          + pg_temp.allergies('00000000-0000-0000-0000-0000000000a1'), 2, 'so theirs are as they were');

-- Another household reaches nothing ---------------------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'milk') $$,
  '42501', null, 'an adult can''t add to someone in another household');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000b2', '{eggs,milk}', '{}') $$,
  'P0002', null, 'or find them through the function');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000a2', 'milk') $$,
  '42501', null, 'or file their own under another household');

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Dan
select is((select count(*)::int from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'another household''s adult can''t see these');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{milk}', '{}') $$,
  'P0002', null, 'or add to them');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'milk') $$,
  '42501', null, 'a row at a time either');

-- A kid still can't touch their own ---------------------------------------------------------------------------------------
select pg_temp.as_user('70000000-0000-0000-0000-000000000007');  -- Kim
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{sesame,milk}', '{}') $$,
  '42501', null, 'a kid can''t add to their own');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'milk') $$,
  '42501', null, 'not even a row at a time');

-- The household's agreement: the same rule as a parent's --------------------------------------------------------------------
select pg_temp.as_user('f1000000-0000-0000-0000-0000000000f1');  -- Fay
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000c2', '{milk}', '{}') $$,
  '42501', null, 'without the household''s agreement an adult can''t add their own');
select throws_ok(
  $$ insert into public.member_allergies (household_id, member_id, category) values
       ('00000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000c2', 'milk') $$,
  '42501', null, 'not even a row at a time');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000c2', '{}', '{}') $$,
  'clearing keeps nothing, so it needs no agreement');

select pg_temp.as_user('e1000000-0000-0000-0000-0000000000e1');  -- Eve
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000c2', '{milk}', '{}') $$,
  '42501', null, 'a parent who hasn''t agreed can''t either');

-- A parent can still add one back -------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{milk,peanuts,soy}', '{kiwi,mango}') $$,
  'a parent adds back an allergy an adult removed');
select ok(pg_temp.has('00000000-0000-0000-0000-0000000000a2', 'milk'), 'and it''s back');

select pg_temp.as_admin();
select * from finish();
rollback;
