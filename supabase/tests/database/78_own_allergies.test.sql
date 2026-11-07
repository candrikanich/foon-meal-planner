-- Adults remove their own allergies (#285): an adult who isn't a parent can delete their own, and only their own. (They
-- can add their own too since 81.) Kids still can't touch theirs; parents still manage everyone's; another household
-- reaches nothing.
begin;
select plan(14);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
-- Counted as whoever's signed in, so it's always someone in household A who can see A's allergies.
create function pg_temp.allergies(person uuid) returns int language sql as $$
  select count(*)::int from public.member_allergies where member_id = person;
$$;

-- Household A: Ann (owner, parent), Grace and Hal (adults who aren't parents, signed in), Kim (a kid, signed in), Ivy
-- (a kid without an account). Household B: Carol (owner) and Dan (an adult who isn't a parent, signed in).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'hal@example.com', 'authenticated', 'authenticated'),
  ('70000000-0000-0000-0000-000000000007', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'dan@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'active', 'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Hal', 'member', 'adult', false, 'active', 'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false, 'active', '70000000-0000-0000-0000-000000000007'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Ivy', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'adult', false, 'active', 'f0000000-0000-0000-0000-00000000000f');
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', null, 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental', 'a0000000-0000-0000-0000-00000000000a', 'v1'),
  ('00000000-0000-0000-0000-0000000000b0', null, 'allergy_data', 'c0000000-0000-0000-0000-00000000000c', 'allergy-data-v1');
insert into public.member_allergies (household_id, member_id, category, custom_text) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'milk', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'custom', 'kiwi'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'peanuts', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'sesame', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'wheat', null),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'eggs', null);

-- Another household reaches nothing, even an adult who may now remove their own -----------------------------------------
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Dan
delete from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000a0';
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{}', '{}') $$,
  'P0002', null, 'another household''s adult can''t find anyone to clear');

-- An adult who isn't a parent: their own, delete only --------------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is((select count(*)::int from public.member_allergies), 5, 'or delete any of its allergies directly');
delete from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a3';
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a3'), 1, 'an adult can''t delete another adult''s');
delete from public.member_allergies where member_id in ('00000000-0000-0000-0000-0000000000a4',
                                                        '00000000-0000-0000-0000-0000000000a5');
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a4')
          + pg_temp.allergies('00000000-0000-0000-0000-0000000000a5'), 2, 'or a kid''s');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{}', '{}') $$,
  '42501', null, 'or clear another adult''s through the function');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a5', '{}', '{}') $$,
  '42501', null, 'or a kid''s');
-- Adding to their own came later, in 81.
update public.member_allergies set category = 'soy' where member_id = '00000000-0000-0000-0000-0000000000a2';
select is((select count(*)::int from public.member_allergies
           where member_id = '00000000-0000-0000-0000-0000000000a2' and category = 'soy'), 0,
  'or changing one');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{}', '{}') $$,
  'an adult clears their own');
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a2'), 0, 'and they''re gone');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Hal
delete from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a3';
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a3'), 0, 'a row at a time works too');

-- A kid still can't touch their own ---------------------------------------------------------------------------------------
select pg_temp.as_user('70000000-0000-0000-0000-000000000007');  -- Kim
delete from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a4';
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a4'), 1, 'a kid can''t delete their own');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  '42501', null, 'or clear them through the function');

-- Parents still manage kids' -----------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a5', '{wheat,milk}', '{}') $$,
  'a parent changes a kid''s');
delete from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a4';
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a4'), 0, 'and removes a kid''s');

select pg_temp.as_admin();
select * from finish();
rollback;
