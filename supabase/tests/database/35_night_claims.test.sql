-- Claim a night and dinner jobs (#50). A claim is a promise: anyone can make one for themselves or a profile nobody has
-- claimed, two people get one answer, and only functions write it. Every way a night changes either leaves it or ends it,
-- and credit only comes from the log it fills in. Jobs are a setting only planners change, one key at a time.
begin;
select plan(100);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.open_claimer(night uuid) returns uuid language sql as $$
  select member_id from public.night_claims where night_id = night and released_at is null;
$$;
create function pg_temp.logged_cook(night uuid) returns uuid language sql as $$
  select cooked_by_member_id from public.meal_logs where night_id = night;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'kim@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'dee@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
-- Alice plans, Bob and Dee are members, Kim is a kid with her own account, Nora a kid without one, Tot eats separately, and
-- Gus gets removed further down.
-- Carol plans another household.
insert into public.members (id, household_id, first_name, role, age_group, eats_separately, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', false,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'adult', false,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Tot', 'member', 'kid', true, null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Dee', 'member', 'adult', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Gus', 'member', 'adult', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', false,
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Tacos');
-- Far ahead: ...d0 to ...d6, Sunday to Saturday, and ...e0 to ...e6 the week after. And nights around the real today, in the
-- household's day (New York, with no time zone set): ...f0 tonight and ...f3 tomorrow, then last week, approved, so the
-- overnight job looks at it: ...f1 last night, ...f2 two nights ago, and on back to ...f8 a week ago.
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2037-11-01', null),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', '2037-11-08', null),
  ('00000000-0000-0000-0000-0000000003a3', '00000000-0000-0000-0000-0000000000a0', public.household_today('00000000-0000-0000-0000-0000000000a0'), null),
  ('00000000-0000-0000-0000-0000000003a4', '00000000-0000-0000-0000-0000000000a0', public.household_today('00000000-0000-0000-0000-0000000000a0') - 7, now());
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000d' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a1', '2037-11-01'::date + d
from generate_series(0, 6) d;
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000e' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a2', '2037-11-08'::date + d
from generate_series(0, 6) d;
insert into public.plan_nights (id, household_id, plan_id, date, meal_id)
select v.id::uuid, '00000000-0000-0000-0000-0000000000a0', v.plan::uuid, public.household_today('00000000-0000-0000-0000-0000000000a0') + v.days, '00000000-0000-0000-0000-0000000002a1'
from (values
  ('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000003a3', 0),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000003a3', 1),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000003a4', -1),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000003a4', -2),
  ('00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000003a4', -3),
  ('00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-0000000003a4', -4),
  ('00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-0000000003a4', -5),
  ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000003a4', -6),
  ('00000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-0000000003a4', -7)
) as v (id, plan, days);
insert into public.night_attendance (household_id, plan_night_id, member_id, expected)
select '00000000-0000-0000-0000-0000000000a0', n.id, m.id, true
from public.plan_nights n cross join public.members m
where n.household_id = '00000000-0000-0000-0000-0000000000a0' and m.household_id = '00000000-0000-0000-0000-0000000000a0';

-- Who can claim -------------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d0', '00000000-0000-0000-0000-0000000000a2') $$,
  'a member offers to cook');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000d0'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'and everyone reads it as theirs');
select is((select entered_by_member_id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000d0'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'from their own phone');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'not for someone with their own account');
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a4') $$,
  'pass the phone: for a kid with no account');
select is((select entered_by_member_id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000d1'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'and it says whose phone');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a5') $$,
  'FD008', null, 'someone who eats separately can''t be the cook');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a3') $$,
  'a kid with her own account offers');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a2') $$,
  '42501', null, 'but only for herself');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a2') $$,
  '42501', null, 'a planner can''t volunteer someone with an account: it''s voluntary');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000b1') $$,
  'P0002', null, 'another household can''t see the night');
select is((select count(*) from public.night_claims)::int, 0, 'or read a claim');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000b1') $$,
  '42501', null, 'and nobody goes on a night from another household');

-- Direct writes -------------------------------------------------------------------------------------------------------
select throws_ok($$ insert into public.night_claims (household_id, night_id, member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'a planner can''t write claims directly');
select throws_ok($$ update public.night_claims set member_id = '00000000-0000-0000-0000-0000000000a1' $$, '42501', null,
  'or change one');
select throws_ok($$ delete from public.night_claims $$, '42501', null, 'or delete one');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ update public.night_claims set released_at = now() $$, '42501', null, 'nor can a member');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ insert into public.night_claims (household_id, night_id, member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000a3') $$,
  '42501', null, 'nor a kid');
select is((select count(*) from public.night_claims)::int, 3, 'the family reads the claims');

-- Two people, one night -----------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d0', '00000000-0000-0000-0000-0000000000a1') $$,
  'FD005', null, 'a second person gets a clear answer');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000d0'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'and the first claim stands');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d0', '00000000-0000-0000-0000-0000000000a2') $$,
  'tapping it twice is fine');
select is((select count(*) from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000d0')::int, 1,
  'and is still one claim');

-- Which nights --------------------------------------------------------------------------------------------------------
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a2') $$,
  'FD006', null, 'last night can''t be claimed, by the household''s day');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.plan_nights set quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000d4';
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000a1') $$,
  'FD009', null, 'a takeout night has nothing to cook');
update public.night_attendance set expected = false
where plan_night_id = '00000000-0000-0000-0000-0000000000d5' and member_id = '00000000-0000-0000-0000-0000000000a1';
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-0000000000a1') $$,
  'FD010', null, 'someone marked out can''t offer');
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-07', '2037-11-07');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d6', '00000000-0000-0000-0000-0000000000a1') $$,
  'FD007', null, 'an away night can''t be claimed');
select lives_ok($$ select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-07', '2037-11-07') $$,
  'back home');

-- Tonight -------------------------------------------------------------------------------------------------------------
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000000a1') $$,
  'tonight can be claimed');
select lives_ok($$ select public.add_away_dates('00000000-0000-0000-0000-0000000000a0',
    public.household_today('00000000-0000-0000-0000-0000000000a0'), public.household_today('00000000-0000-0000-0000-0000000000a0')) $$,
  'dates that cover tonight');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000f0'), '00000000-0000-0000-0000-0000000000a1'::uuid,
  'leave tonight''s claim: its dinner stays too');
select lives_ok($$ select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0',
    public.household_today('00000000-0000-0000-0000-0000000000a0'), public.household_today('00000000-0000-0000-0000-0000000000a0')) $$,
  'and off again');

-- Taking it back ------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok(format($$ select public.release_claim(%L) $$,
    (select id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000d0')),
  '42501', null, 'a member can''t take back someone else''s');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok(format($$ select public.release_claim(%L) $$,
    (select id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000d0')),
  '42501', null, 'nor can a kid');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.release_claim((select '00000000-0000-0000-0000-000000000099'::uuid)) $$, 'P0002', null,
  'an unknown claim is no claim');
reset role;
create temp table claim_ids on commit drop as select night_id, id from public.night_claims where released_at is null;
grant select on claim_ids to authenticated;
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(format($$ select public.release_claim(%L) $$,
    (select id from claim_ids where night_id = '00000000-0000-0000-0000-0000000000d0')),
  'P0002', null, 'and another household''s planner can''t see it');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok(format($$ select public.release_claim(%L) $$,
    (select id from claim_ids where night_id = '00000000-0000-0000-0000-0000000000d0')), 'they take it back');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000d0'), null::uuid, 'and the night''s open');
select is((select count(*) from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000d0')::int, 1,
  'the row stays, as what someone said');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000d0', '00000000-0000-0000-0000-0000000000a1') $$,
  'someone else can take it now');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok(format($$ select public.release_claim(%L) $$,
    (select id from claim_ids where night_id = '00000000-0000-0000-0000-0000000000d0')), 'a stale phone taking back the old one');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000d0'), '00000000-0000-0000-0000-0000000000a1'::uuid,
  'doesn''t touch the new claim');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select lives_ok(format($$ select public.release_claim(%L) $$,
    (select id from claim_ids where night_id = '00000000-0000-0000-0000-0000000000d1')),
  'anyone can take back a claim for a kid with no account, on a shared phone');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(format($$ select public.release_claim(%L) $$,
    (select id from claim_ids where night_id = '00000000-0000-0000-0000-0000000000d2')),
  'a planner can clear anyone''s, for a claim gone stale');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000d2'), null::uuid, 'and it''s cleared');

-- Every way a night changes -------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.claim_night('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a2');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
-- Swap, Plan it, and an older app write the night directly.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', locked = true
where id = '00000000-0000-0000-0000-0000000000e1';
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'Swap to a dish: the promise stands');
-- Build, Fill, and Shuffle go through set_nights, for nights that aren't locked.
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000e1';
select public.set_nights('00000000-0000-0000-0000-0000000003a2', jsonb_build_array(jsonb_build_object(
  'id', '00000000-0000-0000-0000-0000000000e1', 'meal_id', '00000000-0000-0000-0000-0000000002a2')));
select is((select meal_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000e1'),
  '00000000-0000-0000-0000-0000000002a2'::uuid, 'Build changes the dish');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'and the promise stands');
update public.plan_nights set meal_id = null, reason = null, locked = false where id = '00000000-0000-0000-0000-0000000000e1';
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'clearing the night leaves it too');
-- A quick pick puts it on hold: the row's there, the app shows it as on hold, and nothing credits it.
update public.plan_nights set quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000e1';
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'a quick pick leaves the row');
update public.plan_nights set quick_pick = null, meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000e1';
-- Double it: on the dish, it stands; on the night that becomes leftovers, it waits; undone, it's back.
select public.double_it('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'Double it: whoever''s cooking twice as much is still cooking');
select public.undo_double_it('00000000-0000-0000-0000-0000000000e1');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'undone, the same');
select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '2026-01-01');
select public.use_freezer_item('00000000-0000-0000-0000-0000000000e1', (select id from public.freezer_stash limit 1), 'From the freezer');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'a freezer dish: someone still gets dinner on the table');
-- Away dates end it, from a stale app or not, and it stays ended.
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-09', '2037-11-09');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), null::uuid, 'away dates end it');
select is((select count(*) from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000e1')::int, 1,
  'keeping the row');
select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-09', '2037-11-09');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e1'), null::uuid, 'and shortening the dates doesn''t bring it back');

-- Out or gone: someone else can step in ------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.claim_night('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000a2');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.night_attendance set expected = false
where plan_night_id = '00000000-0000-0000-0000-0000000000e3' and member_id = '00000000-0000-0000-0000-0000000000a2';
select lives_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000a1') $$,
  'once the person who offered is marked out, someone else can take the night');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000e3'), '00000000-0000-0000-0000-0000000000a1'::uuid,
  'and the night has one cook');

-- A claim fills in who cooked, for what's logged ------------------------------------------------------------------------
reset role;
-- The overnight job, with a claim on every night but one, and only the one good claim standing.
insert into public.night_claims (household_id, night_id, member_id, released_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a2', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000f4', '00000000-0000-0000-0000-0000000000a2', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000f5', '00000000-0000-0000-0000-0000000000a5', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-0000000000a7', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000000a2', now()),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000f8', '00000000-0000-0000-0000-0000000000a2', null);
update public.night_attendance set expected = false
where plan_night_id = '00000000-0000-0000-0000-0000000000f4' and member_id = '00000000-0000-0000-0000-0000000000a2';
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a7';
update public.plan_nights set meal_id = null, quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000f8';
select is(public.confirm_overnight_dinners(), 7, 'the overnight job logs the past nights');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'and a claim says who cooked');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f2'), null::uuid, 'no claim, no cook');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f4'), null::uuid, 'marked out: no credit');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f5'), null::uuid, 'eats separately: no credit');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f6'), null::uuid, 'removed: no credit');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f7'), null::uuid, 'taken back: no credit');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f8'), null::uuid, 'a quick pick isn''t cooking');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.confirm_dinner('00000000-0000-0000-0000-0000000000f1');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f1'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'confirming a log saved overnight keeps it');
select is((select verified from public.meal_logs where night_id = '00000000-0000-0000-0000-0000000000f1'), true,
  'and confirms it');
select throws_ok(format($$ select public.release_claim(%L) $$,
    (select id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000f1')),
  '42501', null, 'someone else still can''t take it back');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok(format($$ select public.release_claim(%L) $$,
    (select id from public.night_claims where night_id = '00000000-0000-0000-0000-0000000000f1')),
  'FD006', null, 'and once it''s logged it''s history, even for a planner');

-- An unverified log picks up a claim it didn't have, as it's confirmed: only when the plan comes back to a dish.
update public.plan_nights set quick_pick = null, meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000f8';
select public.confirm_dinner('00000000-0000-0000-0000-0000000000f8');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f8'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'back to a dish after the overnight save, the promise counts when it''s confirmed');

-- Tonight's claim (Alice's, from above), confirmed.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.react_to_dinner('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000000a2', 'good');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f0'), '00000000-0000-0000-0000-0000000000a1'::uuid,
  'the first rating confirms the dinner, with the cook who offered');
select throws_ok($$ select public.claim_night('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000000a2') $$,
  'FD006', null, 'a logged dinner can''t be claimed');
update public.meal_logs set cooked_by_member_id = null where night_id = '00000000-0000-0000-0000-0000000000f0';
select public.react_to_dinner('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000000a4', 'good');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f0'), null::uuid,
  'a cook someone cleared stays cleared when the next person rates: a log is what happened');
update public.meal_logs set cooked_by_member_id = '00000000-0000-0000-0000-0000000000a6' where night_id = '00000000-0000-0000-0000-0000000000f0';
select public.confirm_dinner('00000000-0000-0000-0000-0000000000f0');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f0'), '00000000-0000-0000-0000-0000000000a6'::uuid,
  'and so does the cook someone corrected it to');
-- We had something else: the log moves, and the plan keeps what was planned. Quick picks aren't credited, in CookCredit.
update public.meal_logs set cooked_by_member_id = '00000000-0000-0000-0000-0000000000a2' where night_id = '00000000-0000-0000-0000-0000000000f2';
update public.meal_logs set meal_id = '00000000-0000-0000-0000-0000000002a2' where night_id = '00000000-0000-0000-0000-0000000000f2';
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f2'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'We had something else leaves who cooked for the first responder to fix');

-- Wasn't home clears the cook, unless they've been thanked (a thanked cook doesn't move).
select public.set_not_home('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a2');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f1'), null::uuid, 'whoever says they weren''t home didn''t cook');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.thank_the_chef((select id from public.meal_logs where night_id = '00000000-0000-0000-0000-0000000000f2'));
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.set_not_home('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000a2');
select is(pg_temp.logged_cook('00000000-0000-0000-0000-0000000000f2'), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'but a cook someone thanked stays');

-- Retention -----------------------------------------------------------------------------------------------------------
reset role;
insert into public.night_claims (id, household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000e6',
   '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000e0',
   '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a1');
-- Kim's consent was withdrawn over 30 days ago: what she entered herself goes, and what a parent entered stays.
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a3';
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'test-v1', now() - interval '90 days', now() - interval '40 days');
select public.anonymize_expired_profiles();
select is((select count(*) from public.night_claims where id = '00000000-0000-0000-0000-000000000011')::int, 0,
  'a withdrawn kid''s own offer is erased');
select is((select count(*) from public.night_claims where id = '00000000-0000-0000-0000-000000000012')::int, 1,
  'one a parent entered for her stays');

-- Bob deletes his account: what he promised and hasn't done is off; the rows stay, anonymous.
insert into public.night_claims (id, household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d6',
   '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2');
select is(public.delete_account_data('b0000000-0000-0000-0000-00000000000b'), 'profile_anonymized', 'Bob deletes his account');
select isnt((select released_at from public.night_claims where id = '00000000-0000-0000-0000-000000000013'), null,
  'and his open claim ends');
select is(pg_temp.open_claimer('00000000-0000-0000-0000-0000000000d6'), null::uuid, 'so the night''s open');

-- A removed kid's open claim ends with retention.
update public.night_claims set member_id = '00000000-0000-0000-0000-0000000000a4', entered_by_member_id = '00000000-0000-0000-0000-0000000000a1',
  released_at = null where id = '00000000-0000-0000-0000-000000000013';
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a4';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a4';
select public.anonymize_expired_profiles();
select isnt((select released_at from public.night_claims where id = '00000000-0000-0000-0000-000000000013'), null,
  'a removed kid''s open claim ends with retention');

-- The export has them.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select ok(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'night_claims') > 0,
  'the export lists claims');

-- Dinner jobs ---------------------------------------------------------------------------------------------------------
select is((select settings ? 'dinner_jobs' from public.households where id = '00000000-0000-0000-0000-0000000000a0'), false,
  'off until a planner picks a job');
select is(public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'dishes', true) -> 'jobs', '["dishes"]'::jsonb,
  'a planner turns on a job, and gets the setting back');
select is(public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'set_table', true) -> 'jobs',
  '["dishes", "set_table"]'::jsonb, 'another adds to what''s there, not what a stale phone remembers');
select is(public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'set_table', true) -> 'jobs',
  '["dishes", "set_table"]'::jsonb, 'twice is once');
select is(public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'dishes', false) -> 'jobs', '["set_table"]'::jsonb,
  'and turning one off leaves the other');
select throws_ok($$ select public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'mow_the_lawn', true) $$, '22023', null,
  'only jobs Foon knows');
select is(public.set_dinner_job_person('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', false) -> 'left_out',
  '["00000000-0000-0000-0000-0000000000a1"]'::jsonb, 'a planner leaves someone out');
select is(public.set_dinner_job_person('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', true) -> 'left_out',
  '[]'::jsonb, 'and puts them back');
select throws_ok($$ select public.set_dinner_job_person('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b1', false) $$,
  'P0002', null, 'someone from another household isn''t in this one');
-- A settings save can't change it, from an older app or a stale phone.
select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"dinner_jobs": {"jobs": []}, "dinner_time": "19:00"}');
select is((select settings -> 'dinner_jobs' -> 'jobs' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '["set_table"]'::jsonb, 'a settings save can''t touch the jobs');
select is((select settings ->> 'dinner_time' from public.households where id = '00000000-0000-0000-0000-0000000000a0'), '19:00',
  'while what else it saves lands');
update public.households set settings = settings || '{"dinner_jobs": {"jobs": []}}' where id = '00000000-0000-0000-0000-0000000000a0';
select is((select settings -> 'dinner_jobs' -> 'jobs' from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '["set_table"]'::jsonb, 'nor can a planner''s direct write');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'dishes', true) $$, '42501', null,
  'a member can''t change jobs');
select throws_ok($$ select public.set_dinner_job_person('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', false) $$,
  '42501', null, 'or who''s in the rotation, even themselves');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.set_dinner_job('00000000-0000-0000-0000-0000000000a0', 'dishes', true) $$, '42501', null,
  'nor can another household');

select * from finish();
rollback;
