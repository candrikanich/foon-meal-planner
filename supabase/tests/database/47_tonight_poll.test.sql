-- The tonight poll (#43): whoever's home votes, for tonight only, and another household can't see any of it.
begin;
select plan(42);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id, eats_separately) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a', false),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b', false),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null, false),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Baby', 'member', false, 'kid', null, true),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, 'kid', null, false),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c', false);
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0')),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1);
insert into public.night_attendance (household_id, plan_night_id, member_id, expected) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a5', false);
insert into public.meals (id, household_id, name, status, tags) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', 'Frozen pizza', 'active', '{backup}'),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', 'Liver', 'retired', '{}'),
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000000b0', 'Paella', 'active', '{}');
insert into public.freezer_stash (id, household_id, meal_id, made_on) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a1', '2026-01-01');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

-- Starting.
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a2', 30,
  '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]') $$, '22023', null, 'tomorrow can''t have a tonight poll');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"}]') $$, '22023', null, 'one option isn''t a vote');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"quick_pick":"takeout"}]') $$, '22023', null, 'nor is the same one twice');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"meal_id":"00000000-0000-0000-0000-0000000005a1"},{"freezer_item_id":"00000000-0000-0000-0000-0000000006a1"}]') $$,
  '22023', null, 'a dish and the same dish from the freezer are one option');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"quick_pick":"pizza party"}]') $$, '22023', null, 'quick picks are the real ones');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"name":"Anything I type"}]') $$, '22023', null, 'a typed name isn''t an option');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"meal_id":"00000000-0000-0000-0000-0000000005a2"}]') $$, '22023', null, 'a retired dish isn''t offered');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"meal_id":"00000000-0000-0000-0000-0000000005b1"}]') $$, '22023', null, 'nor another household''s');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 1,
  '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]') $$, '22023', null, 'too short to vote in');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 1000,
  '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]') $$, '22023', null, 'or too long');

select lives_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"freezer_item_id":"00000000-0000-0000-0000-0000000006a1"}]') $$, 'anyone can start one, not only a planner');
select is((select options -> 1 ->> 'name' from public.polls), 'Frozen pizza', 'the server reads the dish''s name itself');
select is((select started_by from public.polls), '00000000-0000-0000-0000-0000000000a2'::uuid, 'it says who started it');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]') $$, 'FD018', null, 'only one open at a time');

-- Voting.
select lives_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a2', 0) $$, 'Bob votes');
select lives_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a2', 1) $$, 'and changes his mind');
select is((select choice from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a2')::int, 1, 'one vote, the latest');
select lives_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a3', 0) $$,
  'for a kid nobody has claimed, since she has no phone');
select throws_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a1', 0) $$,
  '42501', null, 'not for another adult');
select throws_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a4', 0) $$,
  'FD004', null, 'not for someone who eats separately');
select throws_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a5', 0) $$,
  'FD019', null, 'not for someone who isn''t home');
select throws_ok($$ select public.vote_in_poll((select id from public.polls), '00000000-0000-0000-0000-0000000000a2', 2) $$,
  '22023', null, 'not for an option that isn''t there');

select throws_ok($$ insert into public.poll_votes (poll_id, member_id, household_id, choice)
  values ((select id from public.polls), '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 1) $$,
  '42501', null, 'votes only go through the function');
select throws_ok($$ update public.polls set closes_at = now() + interval '1 year' $$, '42501', null, 'as does closing');

-- Another household.
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*) from public.polls)::int, 0, 'another household can''t read the poll');
select is((select count(*) from public.poll_votes)::int, 0, 'or the votes');

-- Closing.
reset role;
select set_config('test.poll', (select id::text from public.polls), true);
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.close_poll(current_setting('test.poll')::uuid) $$, 'P0002', null, 'or close it');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.close_poll(current_setting('test.poll')::uuid) $$, 'whoever started it can end it');
select throws_ok($$ select public.vote_in_poll(current_setting('test.poll')::uuid, '00000000-0000-0000-0000-0000000000a2', 0) $$,
  'FD020', null, 'and then the vote is over');
select lives_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]') $$, 'a closed poll doesn''t stop another');

reset role;
insert into public.meal_logs (household_id, night_id, quick_pick) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', 'takeout');
update public.polls set closes_at = now() - interval '1 minute';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.start_tonight_poll('00000000-0000-0000-0000-0000000004a1', 30,
  '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]') $$, 'FD017', null, 'once dinner''s logged there''s nothing to vote on');

-- Keeping and letting go.
reset role;
select is((select entered_by_member_id from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a2'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'a vote says whose phone cast it');
select is((select entered_by_member_id from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a3'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'including one cast for someone else');

select set_config('test.second', (select id::text from public.polls where id <> current_setting('test.poll')::uuid), true);
insert into public.poll_votes (poll_id, member_id, household_id, choice, entered_by_member_id) values
  (current_setting('test.second')::uuid, '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 0,
   '00000000-0000-0000-0000-0000000000a3');
update public.polls set started_by = '00000000-0000-0000-0000-0000000000a3' where id = current_setting('test.second')::uuid;
-- A month ago Nora's parent withdrew her own-device consent.
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-v1', now() - interval '60 days', now() - interval '31 days');
insert into public.polls (id, household_id, night_id, options, closes_at, created_at) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1',
   '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]', now() - interval '9 weeks', now() - interval '9 weeks');
insert into public.poll_votes (poll_id, member_id, household_id, choice) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 0);
select public.anonymize_expired_profiles();
select is_empty($$ select 1 from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a3'
  and poll_id = current_setting('test.second')::uuid $$, 'a withdrawn kid''s own vote is erased');
select isnt_empty($$ select 1 from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a3'
  and poll_id = current_setting('test.poll')::uuid $$, 'one tapped in for her stays');
select is((select started_by from public.polls where id = current_setting('test.second')::uuid), null::uuid,
  'and a poll no longer says she started it');
select is_empty($$ select 1 from public.polls where id = '00000000-0000-0000-0000-0000000007a1' $$, 'a poll ages out after eight weeks');
select is_empty($$ select 1 from public.poll_votes where poll_id = '00000000-0000-0000-0000-0000000007a1' $$, 'with its votes');

-- Kim, a kid with her own account, deletes it.
insert into auth.users (id, email, aud, role) values
  ('d0000000-0000-0000-0000-00000000000d', 'kim@example.com', 'authenticated', 'authenticated');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', false, 'kid',
   'd0000000-0000-0000-0000-00000000000d');
insert into public.poll_votes (poll_id, member_id, household_id, choice, entered_by_member_id) values
  (current_setting('test.second')::uuid, '00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 0,
   '00000000-0000-0000-0000-0000000000a6'),
  (current_setting('test.poll')::uuid, '00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 0,
   '00000000-0000-0000-0000-0000000000a1');
update public.polls set started_by = '00000000-0000-0000-0000-0000000000a6' where id = current_setting('test.poll')::uuid;
select is(public.delete_account_data('d0000000-0000-0000-0000-00000000000d'), 'unlinked', 'Kim deletes her account');
select is_empty($$ select 1 from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a6'
  and poll_id = current_setting('test.second')::uuid $$, 'her own vote goes');
select isnt_empty($$ select 1 from public.poll_votes where member_id = '00000000-0000-0000-0000-0000000000a6'
  and poll_id = current_setting('test.poll')::uuid $$, 'one a parent tapped in stays');
select is((select started_by from public.polls where id = current_setting('test.poll')::uuid), null::uuid,
  'and a poll no longer says she started it');

select * from finish();
rollback;
