-- Invites (#9, #14 limits): parents invite unclaimed profiles; a code links one account, once.
begin;
select plan(27);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
-- Codes are returned once; tests keep them in transaction-local settings.
create function pg_temp.code(name text) returns text language sql as $$
  select current_setting('test.' || name);
$$;

-- Household A: Alice (owner, parent), Grace (planner, not a parent), Ben (claimed), Nora and Owen
-- (unclaimed kids), Rita (removed). Household B: Carol. Dave, Erin, Frank have no household yet.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a3', 'grace@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a4', 'ben@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'erin@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'frank@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'The Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'active', 'a0000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', false, 'active', 'a0000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Rita', 'member', 'adult', false, 'removed', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c');

-- Creating invites -------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select set_config('test.nora_old', public.create_invite('00000000-0000-0000-0000-0000000000a5'), true);
select matches(pg_temp.code('nora_old'), '^THEAN-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$',
  'codes read PREFIX-XXXX-XXXX from an unambiguous alphabet');
select set_config('test.nora', public.create_invite('00000000-0000-0000-0000-0000000000a5'), true);
select is((select count(*)::int from public.invites
           where member_id = '00000000-0000-0000-0000-0000000000a5' and revoked_at is null), 1,
  'a new invite replaces the earlier one');
select isnt(pg_temp.code('nora'), pg_temp.code('nora_old'), 'each invite gets a fresh code');
select set_config('test.owen', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);
select pg_temp.as_admin();
select is_empty(
  $$ select 1 from public.invites where code_hash in (pg_temp.code('nora'), pg_temp.code('owen')) $$,
  'plain codes are never stored');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select is((select count(*)::int from public.invites), 3, 'parents see their household''s invites');
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a4') $$,
  '22023', null, 'a claimed profile cannot be invited');
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a7') $$,
  '22023', null, 'a removed profile cannot be invited');
select throws_ok(
  $$ insert into public.invites (household_id, member_id, code_hash) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'x') $$,
  '42501', null, 'invites are created only through create_invite');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a5') $$,
  '42501', null, 'a planner who is not a parent cannot invite');
select is_empty($$ select 1 from public.invites $$, 'non-parents do not see invites');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a5') $$,
  '42501', null, 'nobody invites into another household');
select is(public.redeem_invite(pg_temp.code('owen')), 'has_household',
  'someone who already has a household cannot join another');

-- Redeeming ---------------------------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Dave
select is(public.redeem_invite(pg_temp.code('nora_old')), 'expired', 'a replaced code no longer works');
select is(public.redeem_invite(lower(replace(pg_temp.code('nora'), '-', ' '))), 'claimed',
  'a code works in any case, with spaces instead of dashes');
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a5'),
  'd0000000-0000-0000-0000-00000000000d'::uuid, 'redeeming links the account to the profile');
select is((select count(*)::int from public.members), 6, 'the new member sees their household');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Erin
select is(public.redeem_invite(pg_temp.code('nora')), 'used', 'a code works once');
select is(public.redeem_invite('THEAN-2222-2222'), 'invalid', 'an unknown code is invalid');
select is(public.redeem_invite('nope'), 'invalid', 'a malformed code is invalid');
select public.redeem_invite('THEAN-2222-2223');
select public.redeem_invite('THEAN-2222-2224');
select public.redeem_invite('THEAN-2222-2225');
select is(public.redeem_invite(pg_temp.code('owen')), 'rate_limited',
  'five wrong guesses in 15 minutes lock redeeming, even for a real code');

-- Nora is removed (unlinking Dave), then restored: her old code must not link anyone new.
select pg_temp.as_admin();
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a5';
update public.members set status = 'active' where id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Frank
select is(public.redeem_invite(pg_temp.code('nora')), 'used',
  'a redeemed code never works again, even after the profile is removed and restored');

-- Removing a profile cancels its open invite: a texted code can't outlive a removal.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select set_config('test.owen_before_removal', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a6';
update public.members set status = 'active' where id = '00000000-0000-0000-0000-0000000000a6';
select throws_ok($$ select code_hash from public.invites $$, '42501', null, 'parents cannot read code hashes');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Frank
select is(public.redeem_invite(pg_temp.code('owen_before_removal')), 'expired',
  'an invite sent before a removal stops working, even if the profile is restored');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select set_config('test.owen', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);

select pg_temp.as_admin();
update public.invites set expires_at = now() - interval '1 minute'
where member_id = '00000000-0000-0000-0000-0000000000a6' and revoked_at is null;
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Frank
select is(public.redeem_invite(pg_temp.code('owen')), 'expired', 'invites expire');
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a6'), null,
  'nothing links after a failed redeem');

-- Access ------------------------------------------------------------------------------------
select throws_ok($$ select 1 from public.invite_redeem_attempts $$,
  '42501', null, 'redeem attempts are not readable by clients');
select pg_temp.as_admin();
set local role anon;
select throws_ok($$ select public.redeem_invite('THEAN-2222-2222') $$, '42501', null, 'anon cannot redeem');

select * from finish();
rollback;
