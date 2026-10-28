-- Dinner logs and reactions (#42, part 1).
begin;
select plan(39);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'owen@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"time_zone": "America/Chicago"}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{"time_zone": "Mars/Base"}');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, 'kid',
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Chili');
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   (now() at time zone 'America/Chicago')::date - 3, now()),
  -- an older week, never approved
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0',
   (now() at time zone 'America/Chicago')::date - 20, null);
insert into public.plan_nights (id, household_id, plan_id, date, meal_id, quick_pick) values
  -- three nights ago: tacos; two nights ago: takeout; yesterday: nothing planned; today: chili; tomorrow: tacos
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 3, '00000000-0000-0000-0000-0000000002a1', null),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2, null, 'takeout'),
  ('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, null, null),
  ('00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0'), '00000000-0000-0000-0000-0000000002a2', null),
  ('00000000-0000-0000-0000-0000000004a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, '00000000-0000-0000-0000-0000000002a1', null),
  -- in the unapproved week: never saved overnight
  ('00000000-0000-0000-0000-0000000004b1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 20, '00000000-0000-0000-0000-0000000002a1', null);

-- The household's day ---------------------------------------------------------------------------
select is(public.household_today('00000000-0000-0000-0000-0000000000a0'), (now() at time zone 'America/Chicago')::date,
  'today is in the household''s time zone');
select is(public.household_today('00000000-0000-0000-0000-0000000000b0'), (now() at time zone 'America/New_York')::date,
  'an unknown time zone falls back to New York');

-- One tap confirms and rates ---------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4',
  '00000000-0000-0000-0000-0000000000a2', 'favorite') $$, 'Bob loves tonight''s chili');
select results_eq(
  $$ select meal_id, verified, confirmed_by_member_id from public.meal_logs
     where night_id = '00000000-0000-0000-0000-0000000004a4' $$,
  $$ values ('00000000-0000-0000-0000-0000000002a2'::uuid, true, '00000000-0000-0000-0000-0000000000a2'::uuid) $$,
  'that one tap confirmed the planned dinner, as Bob''s profile (not his account)');
select lives_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4',
  '00000000-0000-0000-0000-0000000000a3', 'not_for_me') $$, 'and passes the phone to Nora, who has no account');
select lives_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4',
  '00000000-0000-0000-0000-0000000000a2', 'good') $$, 'Bob changes his mind');
select results_eq(
  $$ select m.first_name, r.reaction::text, r.entered_by_member_id from public.reactions r
     join public.members m on m.id = r.member_id order by m.first_name $$,
  $$ values ('Bob', 'good', '00000000-0000-0000-0000-0000000000a2'::uuid),
            ('Nora', 'not_for_me', '00000000-0000-0000-0000-0000000000a2'::uuid) $$,
  'one reaction each, the change replaced the first, and Bob''s phone is recorded for both');
select is((select count(*)::int from public.meal_logs), 1, 'still one log for the night');
select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4',
  '00000000-0000-0000-0000-0000000000a1', 'good') $$, '42501', null,
  'nobody rates for someone who has their own account');
select throws_ok($$ select public.confirm_dinner('00000000-0000-0000-0000-0000000004a5') $$, '22023', null,
  'tomorrow''s dinner hasn''t happened yet');
select throws_ok($$ insert into public.meal_logs (household_id, night_id, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a5', '00000000-0000-0000-0000-0000000002a1') $$,
  '22023', null, 'not even by writing the table');
select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a3',
  '00000000-0000-0000-0000-0000000000a2', 'good') $$, '22023', null, 'an empty night has nothing to rate');
select lives_ok($$ select public.confirm_dinner('00000000-0000-0000-0000-0000000004a2') $$, 'takeout is confirmed');
select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a2',
  '00000000-0000-0000-0000-0000000000a2', 'good') $$, '22023', null, 'but quick picks aren''t rated');

-- "We had something else", leftovers, and who cooked ---------------------------------------------
select lives_ok($$ update public.meal_logs set meal_id = '00000000-0000-0000-0000-0000000002a1', leftovers = true,
  cooked_by_member_id = '00000000-0000-0000-0000-0000000000a1'
  where night_id = '00000000-0000-0000-0000-0000000004a4' $$, 'anyone home corrects the log');
select throws_ok($$ update public.meal_logs set quick_pick = 'takeout'
  where night_id = '00000000-0000-0000-0000-0000000004a4' $$, '23514', null, 'a meal or a quick pick, not both');
select throws_ok($$ update public.meal_logs set confirmed_by_member_id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'who confirmed is recorded, not claimed');
select throws_ok($$ update public.meal_logs set verified = false $$, '42501', null,
  'a confirmed dinner stays confirmed');
select throws_ok($$ update public.reactions set entered_by_member_id = null $$, '42501', null,
  'whose phone it was is recorded too');
select is((select count(*)::int from (select 1 from public.reactions r where r.member_id = '00000000-0000-0000-0000-0000000000a1') x),
  0, 'nobody else''s reaction exists for Alice');
select results_eq($$ with changed as (update public.reactions set reaction = 'good'
  where member_id = '00000000-0000-0000-0000-0000000000a4' returning 1) select count(*)::int from changed $$,
  $$ values (0) $$, 'and Bob can''t rewrite Owen''s, who has his own account');
select throws_ok($$ delete from public.reactions $$, '42501', null, 'reactions are never deleted');
select throws_ok($$ delete from public.meal_logs $$, '42501', null, 'nor are dinner logs');

-- Another household sees and changes nothing ------------------------------------------------------
reset role;
create temp table tonight_log on commit drop as
  select id from public.meal_logs where night_id = '00000000-0000-0000-0000-0000000004a4';
grant select on tonight_log to authenticated;
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.meal_logs $$, 'another household can''t see the logs');
select is_empty($$ select 1 from public.reactions $$, 'or the reactions');
select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1',
  '00000000-0000-0000-0000-0000000000a3', 'good') $$, '42501', null, 'or react to its dinners');
select throws_ok($$ insert into public.reactions (household_id, meal_log_id, member_id, reaction)
  select '00000000-0000-0000-0000-0000000000a0', id, '00000000-0000-0000-0000-0000000000a3', 'good' from tonight_log $$,
  '42501', null, 'not even by writing the table, for their unclaimed kid');

-- 24 hours later, reactions lock --------------------------------------------------------------------
reset role;
update public.reactions set created_at = now() - interval '25 hours'
  where member_id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4',
  '00000000-0000-0000-0000-0000000000a2', 'tired_of_it') $$, '42501', null, 'a day later, it''s history');

-- Overnight: no answer means unverified -----------------------------------------------------------
reset role;
select is(public.confirm_overnight_dinners(), 1,
  'three nights ago''s tacos were saved; takeout was answered; the empty night, today, and the unapproved week weren''t');
select results_eq(
  $$ select n.date - public.household_today(n.household_id), l.meal_id, l.verified, l.confirmed_by_member_id
     from public.meal_logs l join public.plan_nights n on n.id = l.night_id where not l.verified $$,
  $$ values (-3, '00000000-0000-0000-0000-0000000002a1'::uuid, false, null::uuid) $$,
  'as planned, unverified, confirmed by nobody');
select is(public.confirm_overnight_dinners(), 0, 'running again changes nothing');
-- The plan changes after the fact: they ate out that night after all.
update public.plan_nights set meal_id = null, quick_pick = 'eat_out' where id = '00000000-0000-0000-0000-0000000004a1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.confirm_dinner('00000000-0000-0000-0000-0000000004a1') $$, 'the planner checks a gap');
select results_eq(
  $$ select meal_id, quick_pick::text, verified, confirmed_by_member_id from public.meal_logs
     where night_id = '00000000-0000-0000-0000-0000000004a1' $$,
  $$ values (null::uuid, 'eat_out', true, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'verified as what the plan says now, and credited to the planner');

-- Export and deletion --------------------------------------------------------------------------------
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'reactions'), 2,
  'the export includes reactions');

-- Retention: a kid's own ratings vs. ones entered for them ------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4',
  '00000000-0000-0000-0000-0000000000a4', 'tired_of_it') $$, 'Owen rates tonight on his own phone');
reset role;
update public.reactions set comment = 'Too spicy' where member_id = '00000000-0000-0000-0000-0000000000a3';
-- A month ago Owen's parent withdrew his own-device consent (his account is unlinked); Nora left the family a year ago.
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-v1', now() - interval '60 days', now() - interval '31 days');
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a4';
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a3';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a3';
select ok(public.anonymize_expired_profiles() >= 2, 'the retention job runs');
select is_empty($$ select 1 from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a4' $$,
  'Owen''s own rating is erased');
select results_eq(
  $$ select reaction::text, comment from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a3' $$,
  $$ values ('not_for_me', null::text) $$,
  'Nora''s rating, entered on Bob''s phone, stays as anonymous history without her words');

select public.delete_account_data('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.meal_logs) + (select count(*)::int from public.reactions), 0,
  'deleting the household deletes its logs and reactions');

select * from finish();
rollback;
