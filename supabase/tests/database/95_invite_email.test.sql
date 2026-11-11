-- Emailing an adult's invite (#48 PR B): only a parent in the household, only for an unclaimed adult's open invite,
-- only while account email is on, under the limits; the send record is the server's alone, holds no address, and goes
-- after a day.
begin;
select plan(26);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true), set_config('role', 'anon', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.code(name text) returns text language sql as $$
  select current_setting('test.' || name);
$$;
create function pg_temp.reserve(member uuid, code text) returns jsonb language sql as $$
  select public.reserve_invite_email(member, code);
$$;

-- The Andersons: Alice (owner, parent), Grace (planner, not a parent), Ben (claimed adult), Gran (unclaimed adult),
-- Uncle Joe (unclaimed adult), Nora (unclaimed kid). The Carters: Carol (owner).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a3', 'grace@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a4', 'ben@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'The Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"time_zone": "America/Chicago"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'active', 'a0000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', false, 'active', 'a0000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Gran', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Joe', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select set_config('test.gran', public.create_invite('00000000-0000-0000-0000-0000000000a5'), true);
select set_config('test.joe_old', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);
select set_config('test.joe', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);

-- Who may ask ---------------------------------------------------------------------------------
select pg_temp.as_anon();
select throws_ok($$ select pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) $$, '42501', null,
  'signed-out callers can''t call it');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) $$, '42501', null,
  'another household''s parent can''t email the Andersons'' invite');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');
select throws_ok($$ select pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) $$, '42501', null,
  'a planner who isn''t a parent can''t');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select pg_temp.reserve('00000000-0000-0000-0000-0000000000ff', pg_temp.code('gran')) $$, '42501', null,
  'a profile that doesn''t exist reads as not theirs');

-- Who it's for ----------------------------------------------------------------------------------
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a7', pg_temp.code('gran')) ->> 'outcome', 'kid',
  'a kid''s invite is never emailed');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a4', pg_temp.code('gran')) ->> 'outcome', 'not_invitable',
  'a claimed profile can''t be');

-- Email off -------------------------------------------------------------------------------------
select pg_temp.as_admin();
update public.app_config set account_email_enabled = false;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) ->> 'outcome', 'email_off',
  'nothing goes while account email is off');
select pg_temp.as_admin();
select is((select count(*)::int from public.invite_email_sends), 0, 'and nothing is counted');
update public.app_config set account_email_enabled = true;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- The code ------------------------------------------------------------------------------------
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', 'THEAN-2345-6789') ->> 'outcome', 'wrong_code',
  'a code that isn''t the invite''s is refused');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('joe')) ->> 'outcome', 'wrong_code',
  'so is another profile''s code');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a6', pg_temp.code('joe_old')) ->> 'outcome', 'wrong_code',
  'and a code inviting again replaced');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', 'short') ->> 'outcome', 'wrong_code',
  'and anything too short to be one');

select set_config('test.sent', pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran'))::text, true);
select is(pg_temp.code('sent')::jsonb ->> 'outcome', 'send', 'the open invite''s code goes');
select is(pg_temp.code('sent')::jsonb ->> 'code', pg_temp.code('gran'), 'with the code rebuilt as it was made');
select is(
  (select jsonb_build_object('first_name', j ->> 'first_name', 'inviter', j ->> 'inviter', 'household', j ->> 'household',
                             'time_zone', j ->> 'time_zone')
   from (select pg_temp.code('sent')::jsonb as j) s),
  '{"first_name": "Gran", "inviter": "Alice", "household": "The Andersons", "time_zone": "America/Chicago"}'::jsonb,
  'and who it''s for, who sent it and the household');
select ok((pg_temp.code('sent')::jsonb ->> 'expires_at')::timestamptz > now() + interval '6 days',
  'and when the invite expires');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', lower(replace(pg_temp.code('gran'), '-', ' '))) ->> 'code',
  pg_temp.code('gran'), 'a code typed in any case or spacing goes the same');

-- What's kept -----------------------------------------------------------------------------------
select pg_temp.as_admin();
select is(
  (select array_agg(column_name::text order by ordinal_position) from information_schema.columns
   where table_schema = 'public' and table_name = 'invite_email_sends'),
  array['id', 'household_id', 'sent_by', 'created_at'],
  'a send keeps who sent it, the household and when: never an address');
select is((select count(*)::int from public.invite_email_sends
           where household_id = '00000000-0000-0000-0000-0000000000a0'
             and sent_by = 'a0000000-0000-0000-0000-00000000000a'), 2, 'each send is counted');

-- Nobody reads the sends, not even their own household.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from public.invite_email_sends $$, '42501', null, 'the sender can''t read the sends');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select * from public.invite_email_sends $$, '42501', null, 'nor can another household');
select throws_ok($$ insert into public.invite_email_sends (household_id, sent_by)
                   values ('00000000-0000-0000-0000-0000000000a0', 'c0000000-0000-0000-0000-00000000000c') $$,
  '42501', null, 'or write one');

-- Limits ----------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) from generate_series(1, 3);
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) ->> 'outcome', 'rate_limited',
  'a parent sends 5 a day');

-- Another parent's sends count toward the household's 10.
select pg_temp.as_admin();
delete from public.invite_email_sends;
insert into public.invite_email_sends (household_id, sent_by)
select '00000000-0000-0000-0000-0000000000a0', 'a0000000-0000-0000-0000-0000000000a3' from generate_series(1, 10);
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) ->> 'outcome', 'rate_limited',
  'a household sends 10 a day');

-- A day on, the rows go and so does the limit.
select pg_temp.as_admin();
update public.invite_email_sends set created_at = now() - interval '25 hours';
select public.prune_invite_email_sends();
select is((select count(*)::int from public.invite_email_sends), 0, 'sends go after a day');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.reserve('00000000-0000-0000-0000-0000000000a5', pg_temp.code('gran')) ->> 'outcome', 'send',
  'and the parent can send again');

select * from finish();
rollback;
