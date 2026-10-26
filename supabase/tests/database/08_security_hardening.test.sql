-- Security hardening (#14): signing out everywhere ends household access at once, and an invite
-- stops working when the parent who sent it no longer manages the household.
begin;
select plan(13);

-- Real access tokens carry the session they belong to; signing out deletes that session.
create function pg_temp.as_session(uid uuid, session uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', uid, 'role', 'authenticated', 'session_id', session)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a2', 'paul@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'erin@example.com', 'authenticated', 'authenticated');
insert into auth.sessions (id, user_id, not_after) values
  ('5e550000-0000-0000-0000-0000000000a1', 'a0000000-0000-0000-0000-00000000000a', null),  -- Alice's phone
  ('5e550000-0000-0000-0000-0000000000a2', 'a0000000-0000-0000-0000-00000000000a', null),  -- Alice's Mac
  ('5e550000-0000-0000-0000-0000000000a3', 'a0000000-0000-0000-0000-00000000000a', now() - interval '1 minute'),
  ('5e550000-0000-0000-0000-0000000000b1', 'a0000000-0000-0000-0000-0000000000a2', null),
  ('5e550000-0000-0000-0000-0000000000d1', 'd0000000-0000-0000-0000-00000000000d', null),
  ('5e550000-0000-0000-0000-0000000000e1', 'e0000000-0000-0000-0000-00000000000e', null);
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, guardian, user_id, age_group) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'a0000000-0000-0000-0000-00000000000a', 'adult'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Paul', 'planner', true, 'a0000000-0000-0000-0000-0000000000a2', 'adult'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, null, 'kid'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, null, 'kid');
insert into public.items (household_id, canonical_name) values ('00000000-0000-0000-0000-0000000000a0', 'Milk');

-- Sign out everywhere -----------------------------------------------------------------------
select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from public.members), 4, 'a live session reads the household');

select pg_temp.as_admin();
delete from auth.sessions where id = '5e550000-0000-0000-0000-0000000000a1';  -- the phone is signed out

select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a1');
select is_empty($$ select 1 from public.households $$, 'a signed-out session no longer sees the household');
select is_empty($$ select 1 from public.members $$, 'a signed-out session no longer sees members');
select is_empty($$ select 1 from public.items $$, 'a signed-out session no longer sees the library');
select throws_ok(
  $$ insert into public.items (household_id, canonical_name) values ('00000000-0000-0000-0000-0000000000a0', 'Eggs') $$,
  '42501', null, 'a signed-out session cannot write');
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a5') $$,
  '42501', null, 'a signed-out session cannot invite');
-- No filter, so only the update policy's own checks apply (its self-edit branch included).
update public.members set avatar = 'signed-out';
select pg_temp.as_admin();
select is((select count(*)::int from public.members where avatar = 'signed-out'), 0,
  'a signed-out session cannot edit even its own profile');
select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a1');

select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.members), 4, 'the same account''s other live session still works');

select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a3');
select is_empty($$ select 1 from public.members $$, 'an expired session has no access');

-- Invites stop working when their sender stops managing the household ----------------------
select pg_temp.as_session('a0000000-0000-0000-0000-0000000000a2', '5e550000-0000-0000-0000-0000000000b1');  -- Paul
select set_config('test.nora', public.create_invite('00000000-0000-0000-0000-0000000000a5'), true);
select set_config('test.owen', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);

select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a2');  -- Alice
update public.members set guardian = false where id = '00000000-0000-0000-0000-0000000000a2';

select pg_temp.as_session('d0000000-0000-0000-0000-00000000000d', '5e550000-0000-0000-0000-0000000000d1');  -- Dave
select is(public.redeem_invite(current_setting('test.nora')), 'expired',
  'an invite from someone who is no longer a parent stops working');

select pg_temp.as_session('a0000000-0000-0000-0000-00000000000a', '5e550000-0000-0000-0000-0000000000a2');  -- Alice
update public.members set guardian = true where id = '00000000-0000-0000-0000-0000000000a2';
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a2';

select pg_temp.as_session('e0000000-0000-0000-0000-00000000000e', '5e550000-0000-0000-0000-0000000000e1');  -- Erin
select is(public.redeem_invite(current_setting('test.owen')), 'expired',
  'an invite from a removed parent stops working');
select is((select count(*)::int from public.members where user_id is not null and first_name in ('Nora', 'Owen')), 0,
  'neither profile was claimed');

select pg_temp.as_admin();
delete from auth.sessions where id = '5e550000-0000-0000-0000-0000000000d1';
select pg_temp.as_session('d0000000-0000-0000-0000-00000000000d', '5e550000-0000-0000-0000-0000000000d1');
select throws_ok($$ select public.redeem_invite('THEAN-2222-2222') $$,
  '42501', null, 'a signed-out session cannot redeem');

select * from finish();
rollback;
