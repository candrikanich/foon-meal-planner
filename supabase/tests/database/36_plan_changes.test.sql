-- Change history and undo (#57). A trigger logs every change to a night's pick, whoever writes it, and says when the system
-- moved a night rather than a person. Undo restores a plain change that's still the night's last, by the same write as Swap,
-- and refuses everything else. Nobody writes the log directly.
begin;
select plan(89);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
-- The night's newest entry, its id, and how many it has.
create function pg_temp.last_change(night uuid) returns public.plan_changes language sql as $$
  select * from public.plan_changes where night_id = night order by id desc limit 1;
$$;
create function pg_temp.last_id(night uuid) returns bigint language sql as $$
  select max(id) from public.plan_changes where night_id = night;
$$;
create function pg_temp.entries(night uuid) returns int language sql as $$
  select count(*)::int from public.plan_changes where night_id = night;
$$;
create function pg_temp.night_meal(night uuid) returns uuid language sql as $$
  select meal_id from public.plan_nights where id = night;
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
-- Alice and Bob plan, Dee is a member, Kim a kid with her own account, and Carol plans another household.
insert into public.members (id, household_id, first_name, role, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'planner', 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Dee', 'member', 'adult',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid',
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', 'Soup');
-- Far ahead: ...d0 to ...d6 and ...e0 to ...e6, Sunday to Saturday, then ...c0 to ...c2. And around the real today, in the household's day (New
-- York, with no time zone set): ...f0 tonight, ...f3 tomorrow, ...f1 last night.
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2037-11-01'),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', '2037-11-08'),
  ('00000000-0000-0000-0000-0000000003a5', '00000000-0000-0000-0000-0000000000a0', '2037-11-15'),
  ('00000000-0000-0000-0000-0000000003a3', '00000000-0000-0000-0000-0000000000a0', public.household_today('00000000-0000-0000-0000-0000000000a0')),
  ('00000000-0000-0000-0000-0000000003a4', '00000000-0000-0000-0000-0000000000a0', public.household_today('00000000-0000-0000-0000-0000000000a0') - 7);
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000d' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a1', '2037-11-01'::date + d
from generate_series(0, 6) d;
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000e' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a2', '2037-11-08'::date + d
from generate_series(0, 6) d;
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a5', '2037-11-15'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a5', '2037-11-16'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a5', '2037-11-17');
insert into public.plan_nights (id, household_id, plan_id, date)
select v.id::uuid, '00000000-0000-0000-0000-0000000000a0', v.plan::uuid,
       public.household_today('00000000-0000-0000-0000-0000000000a0') + v.days
from (values
  ('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000003a3', 0),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000003a3', 1),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000003a4', -1)
) as v (id, plan, days);

-- Every writer is logged, with who did it ---------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- An older build's Swap: a plain PATCH, with no idea the log exists.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', reason = 'Picked', locked = true
where id = '00000000-0000-0000-0000-0000000000d0';
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000d0'), 1, 'a direct write is logged');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).actor_member_id,
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'as whoever''s token made it');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).kind, 'pick', 'as a plain change');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).after_meal_id,
  '00000000-0000-0000-0000-0000000002a1'::uuid, 'saying what it became');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).before_locked, false, 'and how it was');
select ok((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).restorable, 'and it can be restored');

update public.plan_nights set effort = 'rushed' where id = '00000000-0000-0000-0000-0000000000d0';
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000d0';
update public.plan_nights set reason = 'Other' where id = '00000000-0000-0000-0000-0000000000d0';
update public.plan_nights set locked = true where id = '00000000-0000-0000-0000-0000000000d0';
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000d0'), 1, 'effort, the lock and the reason aren''t plan changes');

-- A whole Build, one statement.
select public.set_nights('00000000-0000-0000-0000-0000000003a2', jsonb_build_array(
  jsonb_build_object('id', '00000000-0000-0000-0000-0000000000e0', 'meal_id', '00000000-0000-0000-0000-0000000002a1'),
  jsonb_build_object('id', '00000000-0000-0000-0000-0000000000e1', 'meal_id', '00000000-0000-0000-0000-0000000002a2'),
  jsonb_build_object('id', '00000000-0000-0000-0000-0000000000e2', 'quick_pick', 'takeout')));
select is((select count(*)::int from public.plan_changes where night_id in
    ('00000000-0000-0000-0000-0000000000e0', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2')
    and kind = 'pick' and actor_member_id = '00000000-0000-0000-0000-0000000000a1'), 3, 'a Build logs each night it changed');
select is((select count(distinct created_at)::int from public.plan_changes where night_id in
    ('00000000-0000-0000-0000-0000000000e0', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2')),
  1, 'at the one moment, which is how it reads as one entry');
select isnt((pg_temp.last_change('00000000-0000-0000-0000-0000000000e0')).created_at,
  (pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).created_at, 'and a separate write doesn''t join it');
select public.set_nights('00000000-0000-0000-0000-0000000003a2', jsonb_build_array(
  jsonb_build_object('id', '00000000-0000-0000-0000-0000000000e3')));
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000e3'), 0, 'a Build that changes nothing on a night logs nothing');

-- Inside a security definer function, who did it still comes from the token.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a3', '2026-01-01');
select public.use_freezer_item('00000000-0000-0000-0000-0000000000e4', (select id from public.freezer_stash limit 1), 'Frozen');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000e4')).actor_member_id,
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'the freezer logs Bob, not the function''s owner');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000e4')).kind, 'freezer', 'and says it''s the freezer');
select ok(not (pg_temp.last_change('00000000-0000-0000-0000-0000000000e4')).restorable, 'which isn''t undone this way');

-- Double it, and what follows from a doubled dish changing --------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000d1';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a3' where id = '00000000-0000-0000-0000-0000000000d2';
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000002a3', null);
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000d1'), 1, 'doubling a dish changes nothing about its own pick');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).kind, 'doubled', 'the leftovers night says Double it');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).linked_date, '2037-11-02'::date, 'and whose leftovers');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).actor_member_id,
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'by Alice');
select ok(not (pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).restorable, 'with its own undo');

select public.undo_double_it('00000000-0000-0000-0000-0000000000d1');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).kind, 'undo_double', 'Undo Double it says so');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).actor_member_id,
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'as the person who tapped it, not the system');
select is(pg_temp.night_meal('00000000-0000-0000-0000-0000000000d2'), '00000000-0000-0000-0000-0000000002a3'::uuid,
  'and the dish is back');

-- Swapping a doubled dish: a person changed one night, and the system moved the other.
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000002a3', null);
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000d1';
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d1')).kind, 'pick', 'the swap is Alice''s');
select ok(not (pg_temp.last_change('00000000-0000-0000-0000-0000000000d1')).restorable,
  'and can''t be restored: the doubling wouldn''t come back with the dish');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).kind, 'follow', 'the other night is the system''s');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).actor_member_id, null, 'with nobody''s name on it');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d2')).linked_date, '2037-11-02'::date, 'saying which night it followed');
select ok(pg_temp.last_id('00000000-0000-0000-0000-0000000000d1') < pg_temp.last_id('00000000-0000-0000-0000-0000000000d2'),
  'listed after the change it followed');

-- Swapping the leftovers night itself ends the link and is the person's own change.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000d3';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a3' where id = '00000000-0000-0000-0000-0000000000d4';
select public.double_it('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d4',
  '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000002a3', null);
update public.plan_nights set quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000d4';
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d4')).kind, 'pick', 'a swap on the leftovers night is a plain swap');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d4')).actor_member_id,
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'by Alice');
select ok(not (pg_temp.last_change('00000000-0000-0000-0000-0000000000d4')).restorable, 'that can''t bring the link back');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000d4')),
  'FD013', null, 'so undo refuses it');

-- The freezer on a doubled dish frees the leftovers night from inside the function, with no trigger involved: still the system.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000c1';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000c2';
select public.double_it('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c2',
  '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000002a1', null);
select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '2026-01-01');
select public.use_freezer_item('00000000-0000-0000-0000-0000000000c1',
  (select id from public.freezer_stash where meal_id = '00000000-0000-0000-0000-0000000002a2'), 'Frozen');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000c1')).kind, 'freezer', 'the dish night is Alice using the freezer');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000c2')).kind, 'follow', 'its leftovers night is the system''s');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000c2')).actor_member_id, null, 'with nobody''s name on it');

-- A log correction moves the plan, whoever made it: We had something else, from a member.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000f0';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000f3';
select public.double_it('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000000f3',
  '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000002a2', null);
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.confirm_dinner('00000000-0000-0000-0000-0000000000f0');
update public.meal_logs set meal_id = null, quick_pick = 'takeout' where night_id = '00000000-0000-0000-0000-0000000000f0';
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000f3')).kind, 'follow', 'a corrected dinner frees its leftovers night');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000f3')).actor_member_id, null, 'not as Dee planning it');
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000f0'), 1, 'the correction isn''t a change to tonight''s plan');

-- Away dates are Foon's doing, not whoever tapped ---------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.plan_nights set quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000d6';
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-07', '2037-11-07');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d6')).kind, 'away', 'away dates say they cleared it');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d6')).actor_member_id, null, 'with nobody''s name on it');
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000d5'), 0, 'an empty night cleared has nothing to log');
update public.plan_nights set quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000d5';
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d5')).kind, 'pick', 'and the next write is a person again');

-- The log never gets in the way ---------------------------------------------------------------------------------------------
reset role;
alter table public.plan_changes add constraint nope check (false) not valid;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2'
                   where id = '00000000-0000-0000-0000-0000000000e5' $$, 'a Swap saves when the log can''t');
select is(pg_temp.night_meal('00000000-0000-0000-0000-0000000000e5'), '00000000-0000-0000-0000-0000000002a2'::uuid, 'and the pick is there');
select is(pg_temp.entries('00000000-0000-0000-0000-0000000000e5'), 0, 'with no entry');
reset role;
alter table public.plan_changes drop constraint nope;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Who can undo ---------------------------------------------------------------------------------------------------------------
create temporary table the_change on commit drop as
  select pg_temp.last_id('00000000-0000-0000-0000-0000000000d0') as id;
grant select on the_change to authenticated;

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), '42501', null, 'a member can''t undo');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), '42501', null, 'nor a kid');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), 'P0002', null,
  'another household''s planner can''t see it');

-- What undo does -------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), 'a planner undoes another planner''s change');
select is((select (meal_id, quick_pick, reason, locked)::text from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d0'),
  '(,,,f)', 'the night holds what it held, lock and reason too');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).kind, 'undo', 'the undo is logged');
select is((pg_temp.last_change('00000000-0000-0000-0000-0000000000d0')).actor_member_id,
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'as Bob');
select throws_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), 'FD012', null, 'the same change twice is refused');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000d0')),
  'FD013', null, 'and an undo isn''t undone');

-- A stale phone: the entry says Chili, and someone has moved the night on since.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000e6';
truncate the_change;
insert into the_change select pg_temp.last_id('00000000-0000-0000-0000-0000000000e6');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000e6';
select throws_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), 'FD012', null,
  'a night that''s moved on since the entry is refused');
select is(pg_temp.night_meal('00000000-0000-0000-0000-0000000000e6'), '00000000-0000-0000-0000-0000000002a2'::uuid, 'and left alone');
-- Back to the same pick: it holds what the first entry says, but that isn't the last change any more.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000e6';
select throws_ok(format('select public.undo_plan_change(%s)', (select id from the_change)), 'FD012', null,
  'only the night''s last change can be undone');
-- Someone locked it since: not this person's to unlock.
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000e6';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000e6';
update public.plan_nights set locked = true where id = '00000000-0000-0000-0000-0000000000e6';
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000e6')), 'FD012', null,
  'a lock changed since is a change too');

-- Moved with no entry to say so, because the log couldn't be written: what the night holds decides, not the log.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000e5';
reset role;
alter table public.plan_changes add constraint nope check (false) not valid;
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a3' where id = '00000000-0000-0000-0000-0000000000e5';
reset role;
alter table public.plan_changes drop constraint nope;
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000e5')), 'FD012', null,
  'what the night holds now is compared, even when it''s still the last entry');
select is(pg_temp.night_meal('00000000-0000-0000-0000-0000000000e5'), '00000000-0000-0000-0000-0000000002a3'::uuid,
  'and the newer pick stands');

-- Nights it won't touch ------------------------------------------------------------------------------------------------------
-- Past.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000f1';
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000f1')),
  'FD013', null, 'a past night is refused');

-- In the household's day, not anyone else's: these two time zones are never on the same date. Carol's night is today in
-- Pago Pago, which is already a past date in Kiritimati.
reset role;
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Paella');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000b0', (now() at time zone 'Pacific/Pago_Pago')::date);
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000000b9', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000003b1',
   (now() at time zone 'Pacific/Pago_Pago')::date);
update public.households set settings = settings || '{"time_zone": "Pacific/Kiritimati"}' where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002b1' where id = '00000000-0000-0000-0000-0000000000b9';
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000b9')),
  'FD013', null, 'gone by, in a household on Kiritimati time');
reset role;
update public.households set settings = settings || '{"time_zone": "Pacific/Pago_Pago"}' where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select lives_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000b9')),
  'and tonight, on Pago Pago time');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Tonight, logged. Dee confirmed it above; the plan can still be changed, but not undone.
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000f0';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a3' where id = '00000000-0000-0000-0000-0000000000f0';
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000f0')),
  'FD013', null, 'a logged dinner is refused');
-- Away: an entry from before the dates.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', quick_pick = null where id = '00000000-0000-0000-0000-0000000000d5';
reset role;
update public.households set settings = settings || '{"away_dates": [{"from": "2037-11-06", "to": "2037-11-07"}]}'
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000d5')),
  '22023', null, 'an away night is refused, in the words the app already has');

-- Going back to empty on an away night: the away trigger wouldn't stop this one, so undo has to ask.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000c0';
reset role;
update public.households set settings = settings || '{"away_dates": [{"from": "2037-11-15", "to": "2037-11-15"}]}'
where id = '00000000-0000-0000-0000-0000000000a0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000c0')),
  '22023', null, 'even an undo that would leave it empty');
select is(pg_temp.night_meal('00000000-0000-0000-0000-0000000000c0'), '00000000-0000-0000-0000-0000000002a1'::uuid, 'and it''s left alone');

-- A dish that's left rotation doesn't come back.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a3' where id = '00000000-0000-0000-0000-0000000000d3';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000d3';
reset role;
update public.meals set status = 'archived' where id = '00000000-0000-0000-0000-0000000002a3';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000d3')),
  'FD013', null, 'an archived dish isn''t put back');
reset role;
update public.meals set status = 'active' where id = '00000000-0000-0000-0000-0000000002a3';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Linked since: a change that's still the last one, on a night that has since been doubled. Locked already, so doubling it
-- doesn't look like a lock changing.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', locked = true where id = '00000000-0000-0000-0000-0000000000e1';
update public.plan_nights set meal_id = null, quick_pick = null, locked = false where id = '00000000-0000-0000-0000-0000000000e2';
select public.double_it('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000e1')),
  'FD013', null, 'half a doubled pair is refused, even if its last entry looks plain');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000e2')),
  'FD013', null, 'as is its leftovers night');
select is((select meal_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000e1'),
  '00000000-0000-0000-0000-0000000002a1'::uuid, 'neither moves');
select throws_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000e4')),
  'FD013', null, 'a freezer night is refused');

-- And undo goes through what Swap goes through.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000e3';
select lives_ok(format('select public.undo_plan_change(%s)', pg_temp.last_id('00000000-0000-0000-0000-0000000000e3')),
  'undoing to an empty night works');
select is(pg_temp.night_meal('00000000-0000-0000-0000-0000000000e3'), null, 'and it''s empty');
select throws_ok('select public.undo_plan_change(-1)', 'P0002', null, 'no such change');

-- Who reads it, and nobody writes it -----------------------------------------------------------------------------------------
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select ok((select count(*) from public.plan_changes) > 0, 'a member reads the log');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select ok((select count(*) from public.plan_changes) > 0, 'a kid reads the log');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.plan_changes where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'another household reads nothing');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.plan_changes (household_id, night_id, kind, before_locked, after_locked) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000d0', 'pick', false, false) $$,
  '42501', null, 'a planner can''t write an entry');
select throws_ok($$ update public.plan_changes set restorable = true $$, '42501', null, 'or change one');
select throws_ok($$ delete from public.plan_changes $$, '42501', null, 'or delete one');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ delete from public.plan_changes $$, '42501', null, 'nor can a member');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ update public.plan_changes set restorable = true $$, '42501', null, 'nor a kid');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ delete from public.plan_changes $$, '42501', null, 'nor another household');

-- Export and retention -------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select ok(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'plan_changes') > 0, 'export includes the log');

reset role;
-- A kid who plans, whose parent withdrew consent over 30 days ago: what she changed herself goes.
insert into public.members (id, household_id, first_name, role, age_group) values
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Wren', 'planner', 'kid');
insert into public.consents (household_id, member_id, kind, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'parental', 'v1',
   now() - interval '60 days', now() - interval '31 days');
update public.plan_changes set actor_member_id = '00000000-0000-0000-0000-0000000000a5'
where id = pg_temp.last_id('00000000-0000-0000-0000-0000000000e0');
-- Past the window.
update public.plan_changes set created_at = now() - interval '9 weeks' where id = pg_temp.last_id('00000000-0000-0000-0000-0000000000e1');
update public.plan_changes set created_at = now() - interval '7 weeks' where id = pg_temp.last_id('00000000-0000-0000-0000-0000000000e2');
create temporary table retained on commit drop as select
  pg_temp.last_id('00000000-0000-0000-0000-0000000000e1') as old_entry, pg_temp.last_id('00000000-0000-0000-0000-0000000000e2') as kept_entry,
  pg_temp.last_id('00000000-0000-0000-0000-0000000000e0') as kid_entry;
select public.anonymize_expired_profiles();
select is((select count(*)::int from public.plan_changes where id = (select old_entry from retained)), 0, 'older than eight weeks is gone');
select is((select count(*)::int from public.plan_changes where id = (select kept_entry from retained)), 1, 'younger stays');
select is((select count(*)::int from public.plan_changes where id = (select kid_entry from retained)), 0, 'what a withdrawn kid did herself goes');

-- An adult leaving: the entry stays and reads as a former member.
select public.delete_account_data('b0000000-0000-0000-0000-00000000000b');
select is((select m.first_name from public.plan_changes c join public.members m on m.id = c.actor_member_id
           where c.night_id = '00000000-0000-0000-0000-0000000000d0' and c.kind = 'undo'), 'Former member',
  'someone who deleted their account reads as a former member');

select * from finish();
rollback;
