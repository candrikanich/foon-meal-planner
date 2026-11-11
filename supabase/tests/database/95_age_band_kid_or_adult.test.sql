-- Only kid or adult is kept after a claim, never Apple's age band (#88, Texas §121.055(b)): redeem_invite still refuses
-- a mismatch with the band, then keeps declared_adult (true, false, or null when Apple didn't say). delete_kid still only
-- unlinks an account whose claim said adult, and deleting an account or a profile clears what was kept.
begin;
select plan(22);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.declared(target uuid) returns boolean language sql as $$
  select declared_adult from public.members where id = target;
$$;

-- Household A: Ann (owner, parent). Unclaimed profiles: Kit, Mo, Ola (kids, with consent), Bea, Cy, Dee (adults).
-- Lex is a kid whose account claimed saying adult before redeem_invite refused that, set up here directly.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bea@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'cy@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'teen@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'lex@example.com', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000001', 'mo@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Mo', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Ola', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Bea', 'member', 'adult', false, null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Cy', 'member', 'adult', false, null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Dee', 'member', 'adult', false, null),
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a0', 'Lex', 'member', 'kid', false,
   'f0000000-0000-0000-0000-00000000000f');
update public.members set declared_adult = true where first_name = 'Lex';
insert into public.consents (household_id, member_id, kind, granted_by, text_version)
select '00000000-0000-0000-0000-0000000000a0', id, 'parental', 'a0000000-0000-0000-0000-00000000000a', 'parental-invite-v3'
from public.members where first_name in ('Kit', 'Mo', 'Ola', 'Lex');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select set_config('test.kit', public.create_invite('00000000-0000-0000-0000-0000000000a2'), true);
select set_config('test.mo', public.create_invite('00000000-0000-0000-0000-0000000000a3'), true);
select set_config('test.ola', public.create_invite('00000000-0000-0000-0000-0000000000a4'), true);
select set_config('test.bea', public.create_invite('00000000-0000-0000-0000-0000000000a5'), true);
select set_config('test.cy', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);
select set_config('test.dee', public.create_invite('00000000-0000-0000-0000-0000000000a7'), true);

-- The band isn't stored anywhere ----------------------------------------------------------------------------------------
select hasnt_column('public', 'members', 'declared_age_band', 'members has no age band column');
select col_type_is('public', 'members', 'declared_adult', 'boolean', 'only whether the claim said adult is kept');

-- A claim keeps kid or adult --------------------------------------------------------------------------------------------
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Kit
select is(public.redeem_invite(current_setting('test.kit'), '13_15'), 'claimed', 'a 13-to-15 claims their kid profile');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Bea
select is(public.redeem_invite(current_setting('test.bea'), 'adult'), 'claimed', 'an adult claims their profile');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Cy
select is(public.redeem_invite(current_setting('test.cy')), 'claimed', 'a claim without an age range goes ahead');
select pg_temp.as_admin();
select is(pg_temp.declared('00000000-0000-0000-0000-0000000000a2'), false, 'a minor''s band is kept only as a minor');
select is(pg_temp.declared('00000000-0000-0000-0000-0000000000a5'), true, 'an adult''s band is kept only as adult');
select is(pg_temp.declared('00000000-0000-0000-0000-0000000000a6'), null::boolean, 'no range keeps nothing');

-- A mismatch is still refused -------------------------------------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- a teen
select is(public.redeem_invite(current_setting('test.dee'), 'under_13'), 'age_mismatch',
  'a minor''s account can''t claim an adult profile');
select is(public.redeem_invite(current_setting('test.ola'), 'adult'), 'age_mismatch',
  'an adult''s account can''t claim a kid''s profile');
select pg_temp.as_admin();
select results_eq(
  $$ select user_id, declared_adult from public.members
     where id in ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a4') $$,
  $$ values (null::uuid, null::boolean), (null::uuid, null::boolean) $$,
  'a refused claim links and keeps nothing');

-- Deleting a kid --------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a2') $$, 'a parent deletes Kit');
select lives_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a8') $$, 'and Lex');
select pg_temp.as_admin();
select is_empty($$ select 1 from auth.users where id = 'e0000000-0000-0000-0000-00000000000e' $$,
  'a kid''s account whose claim said a minor is deleted with them');
select isnt_empty($$ select 1 from auth.users where id = 'f0000000-0000-0000-0000-00000000000f' $$,
  'one whose claim said adult is only unlinked');
select is_empty($$ select 1 from public.members where id = '00000000-0000-0000-0000-0000000000a8' $$,
  'though the profile still goes');

-- Deleting an account clears what was kept ------------------------------------------------------------------------------
select pg_temp.as_user('10000000-0000-0000-0000-000000000001');  -- Mo
select is(public.redeem_invite(current_setting('test.mo'), '16_17'), 'claimed', 'Mo claims their kid profile');
select pg_temp.as_admin();
select is(pg_temp.declared('00000000-0000-0000-0000-0000000000a3'), false, 'as a minor');
select is(public.delete_account_data('10000000-0000-0000-0000-000000000001'), 'unlinked',
  'Mo deletes their account');
select is(pg_temp.declared('00000000-0000-0000-0000-0000000000a3'), null::boolean,
  'and the profile no longer says how they claimed it');
select is(public.delete_account_data('b0000000-0000-0000-0000-00000000000b'), 'profile_anonymized',
  'Bea deletes her account');
select is(pg_temp.declared('00000000-0000-0000-0000-0000000000a5'), null::boolean,
  'and her anonymized profile no longer says adult');

select * from finish();
rollback;
