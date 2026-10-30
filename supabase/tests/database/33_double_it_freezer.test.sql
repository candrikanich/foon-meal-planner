-- Double it and the freezer stash (#53). Double it plans a leftovers night through a function that checks what the
-- device saw; every other way a night changes (Swap, Build, an older app, away dates) unwinds it through a trigger. The
-- stash can only be written through functions; anyone in the family adds to it and uses it up, only planners plan from it.
begin;
select plan(105);

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
-- Alice plans. Bob is a member. Carol plans another household.
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name, status) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili', 'active'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Tacos', 'active'),
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', 'Liver', 'retired'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Paella', 'active');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Beef'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Beans');
-- A week ahead of the clock, Sunday to Saturday: nights ...d0 to ...d6.
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2037-11-01'),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', '2020-11-01'),
  ('00000000-0000-0000-0000-0000000003a3', '00000000-0000-0000-0000-0000000000a0', '2037-11-08');
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000d' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a1', '2037-11-01'::date + d
from generate_series(0, 6) d;
-- The same week long past: ...e0 to ...e6.
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000e' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a2', '2020-11-01'::date + d
from generate_series(0, 6) d;
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1'
where id = '00000000-0000-0000-0000-0000000000d1';

-- Who can double a night ---------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, '42501', null, 'a member can''t double a night');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'P0002', null, 'and another household can''t see it');

-- What the device saw ------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a2', null, null) $$, 'FD001', null,
  'a device that thinks the night holds another dish is refused');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, 'takeout') $$, 'FD001', null,
  'and so is one that thinks the leftovers night holds something else');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d0',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'FD001', null, 'leftovers come after the dish, not before');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000e2',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'FD001', null, 'and in the same week');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000d4',
  null, null, null) $$, 'FD001', null, 'an empty night has nothing to double');

-- Double it ----------------------------------------------------------------------------------
select lives_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'a planner doubles Monday, with leftovers Tuesday');
select results_eq($$ select quick_pick::text, leftovers_from, locked, meal_id from public.plan_nights
                     where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values ('leftovers', '00000000-0000-0000-0000-0000000000d1'::uuid, true, null::uuid) $$,
  'Tuesday is locked leftovers from Monday');
select is((select locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d1'), true,
  'Monday is locked too, so a rebuild keeps the pair');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'FD001', null, 'a dish is doubled once');
select throws_ok($$ update public.plan_nights set leftovers_from = null where id = '00000000-0000-0000-0000-0000000000d2' $$,
  '42501', null, 'a planner can''t write the link directly');
select throws_ok($$ update public.plan_nights set leftovers_restore = '{}' where id = '00000000-0000-0000-0000-0000000000d2' $$,
  '42501', null, 'or what it would restore');
select throws_ok($$ select public.set_nights('00000000-0000-0000-0000-0000000003a1',
  '[{"id": "00000000-0000-0000-0000-0000000000d2", "meal_id": "00000000-0000-0000-0000-0000000002a2"}]'::jsonb) $$,
  'P0002', null, 'a build from an older app leaves the locked leftovers night alone');

-- Undo ----------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.undo_double_it('00000000-0000-0000-0000-0000000000d1') $$, '42501', null,
  'a member can''t undo it');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.undo_double_it('00000000-0000-0000-0000-0000000000d1') $$, 'a planner undoes it');
select results_eq($$ select quick_pick::text, leftovers_from, locked, leftovers_restore from public.plan_nights
                     where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values (null::text, null::uuid, false, null::jsonb) $$, 'Tuesday is back to open');
select is((select locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d1'), false,
  'Monday goes back to unlocked, as it was');
select lives_ok($$ select public.undo_double_it('00000000-0000-0000-0000-0000000000d1') $$,
  'a second device undoing it finds nothing to do');

-- Replacing what's there ---------------------------------------------------------------------
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2', reason = 'Due for a turn'
where id = '00000000-0000-0000-0000-0000000000d2';
update public.plan_nights set locked = true where id = '00000000-0000-0000-0000-0000000000d1';
select lives_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000002a2', null) $$,
  'doubling over a planned dish works when the device saw that dish');
select is((select meal_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2'), null,
  'and the dish leaves the night');
select lives_ok($$ select public.undo_double_it('00000000-0000-0000-0000-0000000000d1') $$, 'undo');
select results_eq($$ select meal_id, reason, locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values ('00000000-0000-0000-0000-0000000002a2'::uuid, 'Due for a turn', false) $$, 'puts the dish back');
select is((select locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d1'), true,
  'and Monday, locked before, stays locked');
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000d1';

update public.plan_nights set locked = true where id = '00000000-0000-0000-0000-0000000000d2';
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000002a2', null) $$, 'FD001', null,
  'a locked night can''t be taken over');
update public.plan_nights set locked = false, meal_id = null, reason = null where id = '00000000-0000-0000-0000-0000000000d2';
update public.plan_nights set effort = 'event' where id = '00000000-0000-0000-0000-0000000000d3';
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'FD001', null, 'nor an event night');
update public.plan_nights set effort = 'normal' where id = '00000000-0000-0000-0000-0000000000d3';

-- A leftovers night Build already placed is linked, not replaced, and comes back as it was.
update public.plan_nights set quick_pick = 'leftovers', reason = 'Leftovers from last night', locked = true
where id = '00000000-0000-0000-0000-0000000000d2';
select lives_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, 'leftovers') $$, 'a locked leftovers night can take the link');
select lives_ok($$ select public.undo_double_it('00000000-0000-0000-0000-0000000000d1') $$, 'undo');
select results_eq($$ select quick_pick::text, reason, locked, leftovers_from from public.plan_nights
                     where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values ('leftovers', 'Leftovers from last night', true, null::uuid) $$, 'and it''s back as Build left it');
update public.plan_nights set quick_pick = null, reason = null, locked = false where id = '00000000-0000-0000-0000-0000000000d2';

-- Every other way a night changes ------------------------------------------------------------
-- An older app's Swap writes meal_id, quick_pick, reason and locked directly, and knows nothing of the link.
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2', quick_pick = null, reason = null, locked = true
where id = '00000000-0000-0000-0000-0000000000d1';
select results_eq($$ select quick_pick::text, leftovers_from, locked from public.plan_nights
                     where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values (null::text, null::uuid, false) $$, 'swapping the doubled dish takes its leftovers night back');

update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', locked = false
where id = '00000000-0000-0000-0000-0000000000d1';
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2', quick_pick = null, locked = true
where id = '00000000-0000-0000-0000-0000000000d2';
select results_eq($$ select meal_id, leftovers_from, leftovers_restore from public.plan_nights
                     where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values ('00000000-0000-0000-0000-0000000002a2'::uuid, null::uuid, null::jsonb) $$,
  'swapping the leftovers night keeps the new pick and ends the link');
select ok(not exists (select 1 from public.plan_nights where leftovers_from = '00000000-0000-0000-0000-0000000000d1'),
  'so Monday no longer reads as doubled');

update public.plan_nights set meal_id = null, locked = false where id = '00000000-0000-0000-0000-0000000000d2';
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
update public.plan_nights set meal_id = null, quick_pick = null, locked = false where id = '00000000-0000-0000-0000-0000000000d1';
select is((select quick_pick::text from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2'), null,
  'clearing the doubled night clears its leftovers night');

-- A dish voted out since it was replaced doesn't come back.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000d1';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2', locked = false where id = '00000000-0000-0000-0000-0000000000d2';
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000002a2', null);
reset role;
update public.meals set status = 'retired' where id = '00000000-0000-0000-0000-0000000002a2';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.undo_double_it('00000000-0000-0000-0000-0000000000d1');
select results_eq($$ select meal_id, quick_pick::text, locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values (null::uuid, null::text, false) $$, 'undo leaves a night empty rather than plan a retired dish');
reset role;
update public.meals set status = 'active' where id = '00000000-0000-0000-0000-0000000002a2';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Away dates: covering the leftovers night ends the link; covering the dish brings the night back.
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03');
select results_eq($$ select quick_pick::text, leftovers_from from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values (null::text, null::uuid) $$, 'away dates over the leftovers night clear it and end the link');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, '22023', null, 'a device that hasn''t heard is refused, as Swap is');
select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03');
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000d1';
select public.double_it('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-02', '2037-11-02');
select results_eq($$ select quick_pick::text, leftovers_from from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values (null::text, null::uuid) $$, 'away dates over the doubled dish bring its leftovers night back to open');
select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-02', '2037-11-02');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000d1';

-- Past nights are history.
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2',
  null, null, null) $$, 'FD001', null, 'a past night can''t be doubled');
reset role;
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000e1';
update public.plan_nights set quick_pick = 'leftovers', leftovers_from = '00000000-0000-0000-0000-0000000000e1'
where id = '00000000-0000-0000-0000-0000000000e2';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000e1';
select results_eq($$ select quick_pick::text, leftovers_from from public.plan_nights where id = '00000000-0000-0000-0000-0000000000e2' $$,
  $$ values ('leftovers', null::uuid) $$,
  'correcting what was eaten long ago keeps the leftovers already eaten and only drops the link');

-- What approve_plan does with a rebuilt line. These strings stand in for what the app builds (doubling itself is
-- tested in DoubleItTests): sent again it's replaced, not added to, and it never touches a line it doesn't own.
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "2 lb (doubled)"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "2 lb (doubled)"}]'::jsonb);
select results_eq($$ select quantity, note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1' $$,
  $$ values ('2 lb (doubled)', null::text) $$, 'a line sent twice is replaced, not added to');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "1 lb"}]'::jsonb);
select results_eq($$ select quantity, note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1' $$,
  $$ values ('1 lb', null::text) $$, 'and a rebuilt line without the doubling replaces it');
insert into public.list_items (household_id, item_id, list, source, quantity)
values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'weekly', 'manual', 'a big can');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "2 cans (doubled)"}]'::jsonb);
select results_eq($$ select quantity, plan_id from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2' $$,
  $$ values ('a big can', null::uuid) $$, 'a line someone added by hand keeps its own amount');
select public.approve_plan('00000000-0000-0000-0000-0000000003a3',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "9 lb"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "2 lb"}]'::jsonb);
select is((select quantity from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1'), '9 lb',
  'and so does a line another approved week wrote');

-- The stash: who reads it ----------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select isnt_empty($$ select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000002a1', '2026-01-01') $$, 'a member adds what they cooked ahead');
select is((select count(*)::int from public.freezer_stash), 1, 'and members read the stash');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.freezer_stash), 1, 'as planners do');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.freezer_stash), 0, 'another household sees none of it');
select throws_ok($$ select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000002a1', '2020-10-01') $$, '42501', null, 'or adds to it');

-- Direct writes are refused, even a planner's.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.freezer_stash (household_id, meal_id, made_on)
  values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '2020-01-01') $$, '42501', null,
  'direct insert refused');
select throws_ok($$ update public.freezer_stash set state = 'used' $$, '42501', null, 'direct update refused');
select throws_ok($$ delete from public.freezer_stash $$, '42501', null, 'direct delete refused');

-- Dates and dishes.
select throws_ok($$ select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000002a1', current_date + 3) $$, '22023', null, 'nothing is cooked in the future');
select throws_ok($$ select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000002b1', '2020-10-01') $$, 'P0002', null, 'a dish from another household isn''t found');

-- Planning from it.
reset role;
insert into public.freezer_stash (id, household_id, meal_id, made_on) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '2037-10-01'),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a3', '2037-10-01');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d4',
  '00000000-0000-0000-0000-0000000005a1', 'From the freezer') $$, '42501', null, 'a member can''t plan a night from it');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d4',
  '00000000-0000-0000-0000-0000000005a1', 'From the freezer') $$, 'P0002', null, 'and another household can''t find the night');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d4',
  '00000000-0000-0000-0000-0000000005a1', 'From the freezer, made Oct 1') $$, 'a planner plans Thursday from it');
select results_eq($$ select meal_id, stash_item_id, locked, reason from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d4' $$,
  $$ values ('00000000-0000-0000-0000-0000000002a2'::uuid, '00000000-0000-0000-0000-0000000005a1'::uuid, true,
             'From the freezer, made Oct 1') $$, 'the night holds the dish, locked, with the item and why');
select is((select state from public.freezer_stash where id = '00000000-0000-0000-0000-0000000005a1'), 'used',
  'and it''s out of the freezer');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d5',
  '00000000-0000-0000-0000-0000000005a1', 'From the freezer') $$, 'FD002', null,
  'someone offered the same item on a stale phone is told it''s gone');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000d5',
  '00000000-0000-0000-0000-0000000002a2', null, null) $$, 'FD001', null, 'a dish from the freezer isn''t doubled');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d5',
  '00000000-0000-0000-0000-0000000005a2', 'From the freezer') $$, 'FD003', null, 'a retired dish isn''t planned from it');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-07', '2037-11-07');
reset role;
insert into public.freezer_stash (id, household_id, meal_id, made_on) values
  ('00000000-0000-0000-0000-0000000005a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '2037-11-06');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d6',
  '00000000-0000-0000-0000-0000000005a3', 'From the freezer') $$, '22023', null, 'nor is an away night');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000005a3', 'From the freezer') $$, 'FD003', null, 'nor a night before it was made');

-- Nights change: the item comes back. An older app's Swap writes the night directly.
update public.plan_nights set meal_id = null, quick_pick = 'takeout', reason = null where id = '00000000-0000-0000-0000-0000000000d4';
select results_eq($$ select state from public.freezer_stash where id = '00000000-0000-0000-0000-0000000005a1' $$,
  $$ values ('in') $$, 'swapping the night puts the item back in the freezer');
select is((select stash_item_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d4'), null,
  'and ends the link');
update public.plan_nights set quick_pick = null, locked = false where id = '00000000-0000-0000-0000-0000000000d4';

-- Used up and archived, never deleted.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'used') $$,
  'a member marks it used up');
select lives_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'in') $$, 'and puts it back');
select lives_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'archived') $$, 'or archives it');
select is((select count(*)::int from public.freezer_stash where id = '00000000-0000-0000-0000-0000000005a1'), 1,
  'the row stays');
select throws_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'used') $$, 'FD002', null,
  'something tossed on another phone can''t be used up');
select throws_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'gone') $$, '22023', null,
  'there are three states');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a2', 'used') $$, 'P0002', null,
  'another household can''t touch an item');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'in');
select public.use_freezer_item('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000005a1', 'From the freezer');
select throws_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a1', 'in') $$, 'FD002', null,
  'an item planned on a night is put back by changing the night');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'freezer_stash'), 4,
  'the export has the whole stash, used and archived included');
select ok((public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'nights') @> '[{"stash_item_id": "00000000-0000-0000-0000-0000000005a1"}]',
  'and the night it''s planned on');

-- A real kid's account: part of the family, not a planner ---------------------------------------
reset role;
insert into auth.users (id, email, aud, role) values
  ('d0000000-0000-0000-0000-00000000000d', 'dee@example.com', 'authenticated', 'authenticated');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Dee', 'member', false, 'kid',
   'd0000000-0000-0000-0000-00000000000d');
-- A week from yesterday on, so "tonight" is real: ...f0 yesterday, ...f1 tonight, ...f2 tomorrow.
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a4', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1);
insert into public.plan_nights (id, household_id, plan_id, date)
select ('00000000-0000-0000-0000-0000000000f' || d)::uuid, '00000000-0000-0000-0000-0000000000a0',
       '00000000-0000-0000-0000-0000000003a4', public.household_today('00000000-0000-0000-0000-0000000000a0') - 1 + d
from generate_series(0, 6) d;
insert into public.freezer_stash (id, household_id, meal_id, made_on) values
  ('00000000-0000-0000-0000-0000000005a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '2020-01-01'),
  ('00000000-0000-0000-0000-0000000005a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '2020-01-01');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000f1';

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ select public.double_it('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2',
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, '42501', null, 'a kid with an account can''t double a night');
select throws_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000f3',
  '00000000-0000-0000-0000-0000000005a4', 'From the freezer') $$, '42501', null, 'or plan one from the freezer');
select isnt_empty($$ select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000002a1', '2026-01-01') $$, 'but adds to the freezer like anyone in the family');
select ok((select count(*) from public.freezer_stash) >= 5, 'and reads it');

-- We had something else writes only the log; a member can make it, and the night has to follow ----
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.double_it('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select public.confirm_dinner('00000000-0000-0000-0000-0000000000f1');
select results_eq($$ select leftovers_from, quick_pick::text from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f2' $$,
  $$ values ('00000000-0000-0000-0000-0000000000f1'::uuid, 'leftovers') $$, 'confirming the dish changes nothing');
update public.meal_logs set meal_id = null, quick_pick = 'takeout' where night_id = '00000000-0000-0000-0000-0000000000f1';
select results_eq($$ select leftovers_from, quick_pick::text, locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f2' $$,
  $$ values (null::uuid, null::text, false) $$, 'tonight''s dish was really takeout: tomorrow''s leftovers night goes back to open');
update public.meal_logs set meal_id = '00000000-0000-0000-0000-0000000002a1', quick_pick = null
where night_id = '00000000-0000-0000-0000-0000000000f1';
select results_eq($$ select leftovers_from, quick_pick::text from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f2' $$,
  $$ values (null::uuid, null::text) $$, 'correcting back leaves the night open: someone may have planned it, so it''s not re-taken');

-- The same correction on a freezer night: the dinner is still in the freezer.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.use_freezer_item('00000000-0000-0000-0000-0000000000f0', '00000000-0000-0000-0000-0000000005a4', 'From the freezer');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.confirm_dinner('00000000-0000-0000-0000-0000000000f0');
update public.meal_logs set meal_id = null, quick_pick = 'takeout' where night_id = '00000000-0000-0000-0000-0000000000f0';
select results_eq($$ select state from public.freezer_stash where id = '00000000-0000-0000-0000-0000000005a4' $$,
  $$ values ('in') $$, 'a freezer night corrected to takeout puts the dinner back in the freezer');
select is((select stash_item_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f0'), null,
  'and the night lets go of it');
select lives_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a4', 'used') $$,
  'so anyone can use it up');
select lives_ok($$ select public.set_freezer_item('00000000-0000-0000-0000-0000000005a4', 'in') $$, 'or put it back');
update public.meal_logs set meal_id = '00000000-0000-0000-0000-0000000002a1', quick_pick = null
where night_id = '00000000-0000-0000-0000-0000000000f0';
select results_eq($$ select state from public.freezer_stash where id = '00000000-0000-0000-0000-0000000005a4' $$,
  $$ values ('used') $$, 'correcting back takes it out again');
select is((select stash_item_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f0'),
  '00000000-0000-0000-0000-0000000005a4'::uuid, 'and the night has it again');
update public.meal_logs set meal_id = null, quick_pick = 'takeout' where night_id = '00000000-0000-0000-0000-0000000000f0';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.use_freezer_item('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000005a4', 'From the freezer');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.meal_logs set meal_id = '00000000-0000-0000-0000-0000000002a1', quick_pick = null
where night_id = '00000000-0000-0000-0000-0000000000f0';
select is((select stash_item_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f3'),
  '00000000-0000-0000-0000-0000000005a4'::uuid, 'unless it''s since gone on another night: that night keeps it');
select is((select stash_item_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f0'), null,
  'and the corrected night doesn''t take it back');

-- Tonight's logged leftovers are history, even though tonight isn't past.
reset role;
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2', stash_item_id = null where id = '00000000-0000-0000-0000-0000000000f0';
update public.plan_nights set meal_id = null, quick_pick = 'leftovers', locked = true,
  leftovers_from = '00000000-0000-0000-0000-0000000000f0',
  leftovers_restore = '{"meal_id": "00000000-0000-0000-0000-0000000002a2", "locked": false}'
where id = '00000000-0000-0000-0000-0000000000f1';
update public.meal_logs set meal_id = null, quick_pick = 'leftovers' where night_id = '00000000-0000-0000-0000-0000000000f1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000f0';
select results_eq($$ select quick_pick::text, meal_id, leftovers_from, locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000f1' $$,
  $$ values ('leftovers', null::uuid, null::uuid, true) $$,
  'swapping yesterday''s dish leaves tonight''s logged leftovers as eaten, and only drops the link');

-- A build over a pair someone unlocked: the write goes through.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', locked = false where id = '00000000-0000-0000-0000-0000000000d2';
update public.plan_nights set quick_pick = 'leftovers', locked = true where id = '00000000-0000-0000-0000-0000000000d3';
select public.double_it('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000002a1', null, 'leftovers');
update public.plan_nights set locked = false where id in ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3');
select lives_ok($$ select public.set_nights('00000000-0000-0000-0000-0000000003a1',
  '[{"id": "00000000-0000-0000-0000-0000000000d2", "meal_id": "00000000-0000-0000-0000-0000000002a2"},
    {"id": "00000000-0000-0000-0000-0000000000d3", "quick_pick": "takeout"}]'::jsonb) $$,
  'rebuilding an unlocked pair saves, instead of failing on the night it just restored');
select results_eq($$ select quick_pick::text, locked, leftovers_from from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d3' $$,
  $$ values ('takeout', false, null::uuid) $$, 'and the second night holds what the build chose');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1' where id = '00000000-0000-0000-0000-0000000000d2';
update public.plan_nights set quick_pick = 'leftovers', locked = true where id = '00000000-0000-0000-0000-0000000000d3';
select public.double_it('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000002a1', null, 'leftovers');
update public.plan_nights set locked = false where id = '00000000-0000-0000-0000-0000000000d3';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a2' where id = '00000000-0000-0000-0000-0000000000d2';
select results_eq($$ select quick_pick::text, locked from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d3' $$,
  $$ values ('leftovers', false) $$, 'and a night someone unlocked stays unlocked when it''s restored');

-- The same dish from the freezer on a doubled night: nothing to cook twice now.
update public.plan_nights set quick_pick = null, reason = null, locked = false where id = '00000000-0000-0000-0000-0000000000d3';
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', locked = false where id = '00000000-0000-0000-0000-0000000000d2';
select public.double_it('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select lives_ok($$ select public.use_freezer_item('00000000-0000-0000-0000-0000000000d2',
  '00000000-0000-0000-0000-0000000005a5', 'From the freezer') $$, 'a stale phone plans the same dish from the freezer');
select results_eq($$ select leftovers_from, quick_pick::text from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d3' $$,
  $$ values (null::uuid, null::text) $$, 'and the doubled pair ends, even though the dish didn''t change');

-- A freezer night under new away dates: the night clears and the dinner goes back.
select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-07', '2037-11-07');
select public.add_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03');
select results_eq($$ select meal_id, stash_item_id from public.plan_nights where id = '00000000-0000-0000-0000-0000000000d2' $$,
  $$ values (null::uuid, null::uuid) $$, 'away dates clear a freezer night');
select is((select state from public.freezer_stash where id = '00000000-0000-0000-0000-0000000005a5'), 'in',
  'and the dinner is back in the freezer');
select public.remove_away_dates('00000000-0000-0000-0000-0000000000a0', '2037-11-03', '2037-11-03');

-- Whether the approved list is behind: every phone reads it from the plan.
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1', quick_pick = null, locked = false where id = '00000000-0000-0000-0000-0000000000d2';
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), false, 'approving settles the list');
select public.double_it('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000d3',
  '00000000-0000-0000-0000-0000000002a1', null, null);
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), true, 'doubling on an approved week puts it behind');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
update public.plan_nights set quick_pick = 'takeout' where id = '00000000-0000-0000-0000-0000000000d3';
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), true,
  'and so does an older app swapping the leftovers night, which only writes the pick');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select public.use_freezer_item('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000005a5', 'From the freezer');
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a1'), true, 'and a freezer pick');
select is((select list_stale from public.plans where id = '00000000-0000-0000-0000-0000000003a4'), false,
  'a week never approved has no list to be behind');
select throws_ok($$ update public.plans set list_stale = false where id = '00000000-0000-0000-0000-0000000003a1' $$,
  '42501', null, 'and nobody writes it directly');

-- A new household table has row-level security.
reset role;
select is((select relrowsecurity from pg_class where oid = 'public.freezer_stash'::regclass), true, 'row-level security is on');

select * from finish();
rollback;
