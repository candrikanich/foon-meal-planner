-- Delete everything about a child, now (#278): any parent in the kid's family deletes the kid's profile, everything
-- about them and their sign-in account at once. The family's plans, dishes, dinners and list lines stay, without naming
-- them, and nobody else can do it.
begin;
select plan(41);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Every public column that holds this id: uuid columns equal to it, jsonb columns (settings, schedules, push args)
-- containing it. A new table or column that points at a member is covered without changing this test.
create function pg_temp.mentions(target uuid) returns text[] language plpgsql as $$
declare
  col record;
  hit boolean;
  hits text[] := '{}';
begin
  for col in select c.table_name, c.column_name, c.data_type from information_schema.columns c
             join information_schema.tables t using (table_schema, table_name)
             where c.table_schema = 'public' and t.table_type = 'BASE TABLE' and c.data_type in ('uuid', 'jsonb')
             order by 1, 2
  loop
    if col.data_type = 'uuid' then
      execute format('select exists (select 1 from public.%I where %I = $1)', col.table_name, col.column_name)
        into hit using target;
    else
      execute format('select exists (select 1 from public.%I where %I::text like $1)', col.table_name, col.column_name)
        into hit using '%' || target::text || '%';
    end if;
    if hit then hits := hits || (col.table_name || '.' || col.column_name); end if;
  end loop;
  return hits;
end;
$$;

-- Household A: Ann (owner, parent, planner), Ben (a parent who isn't the owner), Grace (a planner who isn't a parent),
-- Kit (a kid with their own account) and Owen (a kid without one). Household B: Carol (owner, parent) and Dan (a kid).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'planner', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'kid', false, null);

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
select pg_temp.as_admin();

create temporary table nights as
  select id, row_number() over (order by date) as n from public.plan_nights
  where household_id = '00000000-0000-0000-0000-0000000000a0';

-- A meal photo Kit uploaded: Storage records the uploader, and that mustn't stop their account from going.
insert into storage.objects (bucket_id, name, owner) values
  ('household-photos', '00000000-0000-0000-0000-0000000000a0/meals/kits-pizza.jpg', 'e0000000-0000-0000-0000-00000000000e');

insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', null, 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-invite-v2'),
  ('00000000-0000-0000-0000-0000000000b0', null, 'allergy_data', 'c0000000-0000-0000-0000-00000000000c', 'allergy-data-v1');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'milk'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'peanuts'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'eggs');
insert into public.invites (household_id, member_id, code_hash, created_by, redeemed_at, redeemed_by) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'hash-kit',
   'a0000000-0000-0000-0000-00000000000a', now(), 'e0000000-0000-0000-0000-00000000000e');
insert into public.invite_redeem_attempts (user_id, attempted_at, succeeded) values
  ('e0000000-0000-0000-0000-00000000000e', now(), true);

-- Tacos: Kit's dish, cooked by Kit on night 1 and thanked by Ann. Salad: cooked by Ann on night 2, which Kit rated
-- (with a hidden comment), thanked her for, and rated for Owen too.
insert into public.meals (id, household_id, name, made_by_member_id) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos',
   '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Salad', null);
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id, confirmed_by_member_id) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 1),
   '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 2),
   '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1');
insert into public.reactions (id, household_id, meal_log_id, member_id, reaction, comment, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   '00000000-0000-0000-0000-0000000000a4', 'good', null, '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000006a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   '00000000-0000-0000-0000-0000000000a5', 'favorite', null, '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   '00000000-0000-0000-0000-0000000000a1', 'good', 'Crunchy', '00000000-0000-0000-0000-0000000000a1');
insert into public.hidden_comments (reaction_id, household_id, comment) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-0000000000a0', 'Too many onions');
insert into public.chef_thanks (household_id, meal_log_id, from_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a4');
insert into public.serving_notes (household_id, meal_id, member_id, note, written_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a4',
   'No cheese on his', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a5',
   'Owen likes extra salsa', '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a1',
   'Dressing on the side', '00000000-0000-0000-0000-0000000000a1');

-- Requests: r1 Kit's own, with Ann's me-too; r2 Owen's, which Kit entered for him; r3 Ann's, with Kit's me-too.
insert into public.requests (id, household_id, requested_by_member_id, title, note, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4',
   'Crab legs', 'For my birthday week', '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5',
   'Pancakes', 'Owen asked at breakfast', '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000007a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'Curry', null, '00000000-0000-0000-0000-0000000000a1');
insert into public.request_plus_ones (household_id, request_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000007a3', '00000000-0000-0000-0000-0000000000a4',
   '00000000-0000-0000-0000-0000000000a4');

insert into public.night_claims (household_id, night_id, member_id, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 3), '00000000-0000-0000-0000-0000000000a4',
   '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 4), '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1');
insert into public.polls (id, household_id, night_id, started_by, options, closes_at) values
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 5),
   '00000000-0000-0000-0000-0000000000a4', '[{"quick_pick":"takeout"},{"quick_pick":"leftovers"}]', now());
insert into public.poll_votes (poll_id, member_id, household_id, choice, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 0,
   '00000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 1,
   '00000000-0000-0000-0000-0000000000a1');
insert into public.plan_changes (household_id, night_id, actor_member_id, kind, before_locked, after_locked) values
  ('00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 6), '00000000-0000-0000-0000-0000000000a4',
   'pick', false, false),
  ('00000000-0000-0000-0000-0000000000a0', (select id from nights where n = 6), '00000000-0000-0000-0000-0000000000a1',
   'pick', false, false);

insert into public.notification_log (id, household_id, member_id, type, night_id, scheduled_for) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4',
   'after_dinner', (select id from nights where n = 2), now()),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'after_dinner', (select id from nights where n = 2), now());
insert into public.push_devices (user_id, member_id, household_id, token, environment) values
  ('e0000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0',
   repeat('ab', 32), 'sandbox');
-- 5a1 to Kit, 5a2 to Ann about something Kit marked for tonight, 5a3 Ann's digest naming Kit.
insert into public.push_outbox (id, household_id, member_id, kind, about_member_id, args, not_before) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4',
   'plan_set', null, '{}', now()),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'urgent_item', '00000000-0000-0000-0000-0000000000a4', '{"name": "Kit"}', now()),
  ('00000000-0000-0000-0000-0000000005a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'new_requests', '00000000-0000-0000-0000-0000000000a4', '{"name": "Kit", "count": 1}', now());
insert into public.store_runs (household_id, started_by, ends_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', now() + interval '10 minutes');

-- A line Kit checked off and marked for tonight. The second update leaves checked_at alone, so the stamp keeps Kit.
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Milk');
insert into public.list_items (id, household_id, item_id, list) values
  ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
   'quick');
update public.list_items set checked_at = now() where id = '00000000-0000-0000-0000-0000000008a1';
update public.list_items set checked_by = '00000000-0000-0000-0000-0000000000a4',
                             urgent_by = '00000000-0000-0000-0000-0000000000a4'
where id = '00000000-0000-0000-0000-0000000008a1';

insert into public.attendance_templates (household_id, name, schedules) values
  ('00000000-0000-0000-0000-0000000000a0', 'School year',
   '{"00000000-0000-0000-0000-0000000000a4": {"usually_away": [2]}, "00000000-0000-0000-0000-0000000000a1": {}}');
update public.households
set settings = settings || '{"dinner_jobs": {"jobs": ["set_table"], "left_out": ["00000000-0000-0000-0000-0000000000a4",
                                                                                 "00000000-0000-0000-0000-0000000000a1"]}}'
where id = '00000000-0000-0000-0000-0000000000a0';

select ok(cardinality(pg_temp.mentions('00000000-0000-0000-0000-0000000000a4')) >= 20,
  'before: Kit is named across the household''s tables');

-- Who can ---------------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.delete_kid(uuid)', 'execute'), 'signed-out callers can''t');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select throws_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a4') $$, '42501', null,
  'a planner who isn''t a parent can''t');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Kit
select throws_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a4') $$, '42501', null,
  'nor can the kid (their own Delete my account is separate)');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select throws_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a4') $$, '42501', null,
  'nor another household''s parent');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select throws_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a3') $$, '22023', null,
  'a parent can''t delete an adult this way');
-- Or by making them a kid first: someone who signed in as an adult stays one.
select throws_ok($$ update public.members set age_group = 'kid' where id = '00000000-0000-0000-0000-0000000000a3' $$,
  '42501', 'someone who signed in as an adult stays an adult', 'a parent can''t make a signed-in adult a kid');
select throws_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a3') $$, '22023', null,
  'so they still can''t be deleted this way');
select throws_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000ff') $$, 'P0002', null,
  'a profile that isn''t there says so');

select pg_temp.as_admin();
select is((select count(*)::int from public.members where id = '00000000-0000-0000-0000-0000000000a4'), 1,
  'so Kit is still there');

-- Deleting Kit ----------------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select lives_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a4') $$,
  'any parent in the family can, not only the owner');

select pg_temp.as_admin();
select is_empty($$ select 1 from public.members where id = '00000000-0000-0000-0000-0000000000a4' $$,
  'the profile is deleted, not anonymized');
select is_empty($$ select 1 from auth.users where id = 'e0000000-0000-0000-0000-00000000000e' $$,
  'and so is the sign-in account');
select isnt_empty($$ select 1 from storage.objects where name like '%/meals/kits-pizza.jpg' $$,
  'a photo Kit uploaded stays the family''s');
select is(pg_temp.mentions('00000000-0000-0000-0000-0000000000a4'), '{}'::text[],
  'no row anywhere names Kit''s profile');
select is(pg_temp.mentions('e0000000-0000-0000-0000-00000000000e'), '{}'::text[],
  'or Kit''s account');
select is_empty($$ select 1 from public.hidden_comments where reaction_id = '00000000-0000-0000-0000-0000000006a1' $$,
  'Kit''s hidden comment went with the rating');
select is_empty($$ select 1 from public.chef_thanks where household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  'thanks Kit sent and thanks for the dinner Kit cooked are deleted');
select is_empty($$ select 1 from public.requests where id = '00000000-0000-0000-0000-0000000007a1' $$,
  'Kit''s request is deleted, with its me-toos');
select is_empty($$ select 1 from public.consents where kind = 'parental' $$, 'and the record of consent for Kit');

-- What stays ------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0'), 7,
  'the week''s nights stay');
select is((select count(*)::int from public.night_attendance
           where member_id = '00000000-0000-0000-0000-0000000000a1'), 7, 'and Ann''s attendance');
select results_eq(
  $$ select name, made_by_member_id from public.meals where household_id = '00000000-0000-0000-0000-0000000000a0'
     order by name $$,
  $$ values ('Salad'::text, null::uuid), ('Tacos', null) $$,
  'the dishes stay, no longer saying Kit makes one');
select results_eq(
  $$ select id, cooked_by_member_id, confirmed_by_member_id from public.meal_logs
     where household_id = '00000000-0000-0000-0000-0000000000a0' order by id $$,
  $$ values ('00000000-0000-0000-0000-0000000003a1'::uuid, null::uuid, null::uuid),
            ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a1',
             '00000000-0000-0000-0000-0000000000a1') $$,
  'the dinners stay; the one Kit cooked and confirmed names nobody');
select results_eq(
  $$ select member_id, entered_by_member_id, comment from public.reactions
     where household_id = '00000000-0000-0000-0000-0000000000a0' order by member_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, '00000000-0000-0000-0000-0000000000a1'::uuid, 'Crunchy'::text),
            ('00000000-0000-0000-0000-0000000000a5', null, null) $$,
  'Ann''s rating stays, and Owen''s, which Kit entered, stays Owen''s');
select results_eq(
  $$ select member_id, written_by_member_id from public.serving_notes
     where household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'notes about Kit and notes Kit wrote are deleted; Ann''s stays');
select results_eq(
  $$ select id, note, entered_by_member_id from public.requests
     where household_id = '00000000-0000-0000-0000-0000000000a0' order by id $$,
  $$ values ('00000000-0000-0000-0000-0000000007a2'::uuid, null::text, null::uuid),
            ('00000000-0000-0000-0000-0000000007a3', null, '00000000-0000-0000-0000-0000000000a1') $$,
  'Owen''s request stays without Kit''s words; Ann''s stays');
select is((select count(*)::int from public.request_plus_ones
           where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'Kit''s me-too and the me-toos on Kit''s request are deleted');
select results_eq(
  $$ select member_id from public.night_claims where household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'Kit''s offer to cook is deleted; Ann''s stays');
select results_eq(
  $$ select p.started_by, (select array_agg(v.member_id) from public.poll_votes v where v.poll_id = p.id)
     from public.polls p where p.household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values (null::uuid, array['00000000-0000-0000-0000-0000000000a1'::uuid]) $$,
  'the poll stays with Ann''s vote, and no longer says Kit started it');
select is((select count(*)::int from public.plan_changes where household_id = '00000000-0000-0000-0000-0000000000a0'), 1,
  'the plan change Kit made is deleted; Ann''s stays');
select results_eq(
  $$ select checked_at is not null, checked_by, urgent_by from public.list_items
     where id = '00000000-0000-0000-0000-0000000008a1' $$,
  $$ values (true, null::uuid, null::uuid) $$,
  'the list line stays, checked, naming nobody');
select results_eq(
  $$ select id, args from public.push_outbox
     where id in ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000005a2',
                  '00000000-0000-0000-0000-0000000005a3') $$,
  $$ values ('00000000-0000-0000-0000-0000000005a3'::uuid, '{"count": 1}'::jsonb) $$,
  'pushes to or about Kit are deleted; Ann''s digest stays without the name');
select results_eq(
  $$ select settings -> 'dinner_jobs' -> 'left_out' from public.households
     where id = '00000000-0000-0000-0000-0000000000a0' $$,
  $$ values ('["00000000-0000-0000-0000-0000000000a1"]'::jsonb) $$,
  'the dinner jobs keep leaving Ann out');
select results_eq(
  $$ select kind::text, count(*)::int from public.consents where household_id = '00000000-0000-0000-0000-0000000000a0'
     group by kind $$,
  $$ values ('allergy_data'::text, 1) $$,
  'the household''s allergy consent stays');
select results_eq(
  $$ select household_id, category::text from public.member_allergies order by household_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a0'::uuid, 'peanuts'::text),
            ('00000000-0000-0000-0000-0000000000b0', 'eggs') $$,
  'Kit''s allergy is deleted; Ann''s and another household''s stay');
select results_eq(
  $$ select first_name from public.members where household_id = '00000000-0000-0000-0000-0000000000b0' order by first_name $$,
  $$ values ('Carol'::text), ('Dan') $$,
  'another household is untouched');

-- A kid without an account -------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a5') $$,
  'a kid with no account of their own can be deleted too');
select pg_temp.as_admin();
select is(pg_temp.mentions('00000000-0000-0000-0000-0000000000a5'), '{}'::text[], 'and nothing names Owen');

-- Someone who says they're an adult can't claim a kid's profile ------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('f0000000-0000-0000-0000-00000000000f', 'ada@example.com', 'authenticated', 'authenticated');
insert into public.members (id, household_id, first_name, age_group) values
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Ada', 'kid');
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-invite-v1');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select set_config('test.ada', public.create_invite('00000000-0000-0000-0000-0000000000a6'), true);
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is(public.redeem_invite(current_setting('test.ada'), 'adult'), 'age_mismatch',
  'someone who says they''re an adult can''t claim a kid''s profile');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a6'), null::uuid,
  'so the profile stays unclaimed');

select * from finish();
rollback;
