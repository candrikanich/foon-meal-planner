-- Delete household: the owner erases the household and everything in it, for everyone, and keeps their account.
-- Only the delete-account Edge Function (service role) calls it, after removing the household's photos.
begin;
select plan(12);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

-- Household tables with no rows for this household. Seeding every one before the erase is what makes rows_left
-- meaningful: a new household table fails this test until it's seeded here (and then until erase_household empties it).
create function pg_temp.empty_tables(target uuid) returns text[] language plpgsql as $$
declare
  t record;
  n int;
  empty text[] := '{}';
begin
  for t in select c.table_name from information_schema.columns c
           join information_schema.tables tb using (table_schema, table_name)
           where c.table_schema = 'public' and c.column_name = 'household_id' and tb.table_type = 'BASE TABLE'
           order by 1
  loop
    execute format('select count(*) from public.%I where household_id = $1', t.table_name) into n using target;
    if n = 0 then empty := empty || t.table_name::text; end if;
  end loop;
  return empty;
end;
$$;

-- Rows left in any household table after an erase.
create function pg_temp.rows_left(target uuid) returns int language plpgsql as $$
declare
  t record;
  n int;
  total int := 0;
begin
  for t in select c.table_name from information_schema.columns c
           join information_schema.tables tb using (table_schema, table_name)
           where c.table_schema = 'public' and c.column_name = 'household_id' and tb.table_type = 'BASE TABLE'
  loop
    execute format('select count(*) from public.%I where household_id = $1', t.table_name) into n using target;
    total := total + n;
  end loop;
  return total;
end;
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Sample Family', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'planner', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Gran', 'member', false, 'adult', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'eggs');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Taco shells');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Salad'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Paella');
insert into public.meal_sides (household_id, meal_id, side_meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   '00000000-0000-0000-0000-0000000002a2');
insert into public.consents (household_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'test-v1');
insert into public.meal_ingredients (household_id, meal_id, item_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   '00000000-0000-0000-0000-0000000001a1');
insert into public.traditions (household_id, weekday, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', 2, '00000000-0000-0000-0000-0000000002a1');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
insert into public.list_items (household_id, item_id, list, source) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'manual');
select public.make_request('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3',
  '00000000-0000-0000-0000-0000000002a1', null, null, 'Nora wants', null);
select public.set_serving_note('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a3',
  'No beans');
select public.toggle_me_too((select id from public.requests limit 1), '00000000-0000-0000-0000-0000000000a1');
select public.create_invite('00000000-0000-0000-0000-0000000000a4');
select public.save_attendance_template('00000000-0000-0000-0000-0000000000a0', 'School year');
select public.add_to_freezer('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '2026-01-01');
-- A stash item planned on a night: the erase has to clear the night before the item.
select public.use_freezer_item((select id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0'
                                order by date desc limit 1),
                               (select id from public.freezer_stash limit 1), 'From the freezer');
reset role;
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   (select id from public.plan_nights where household_id = '00000000-0000-0000-0000-0000000000a0' limit 1),
   '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a2');
insert into public.reactions (household_id, meal_log_id, member_id, reaction) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   '00000000-0000-0000-0000-0000000000a1', 'good');
insert into public.chef_thanks (household_id, meal_log_id, from_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   '00000000-0000-0000-0000-0000000000a1');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Clients never call it, not even the owner: it goes through the Edge Function, which removes photos first.
select throws_ok($$ select public.delete_household_data('a0000000-0000-0000-0000-00000000000a') $$, '42501', null,
  'clients can''t call delete_household_data');
select throws_ok($$ select public.erase_household('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'or erase_household');

reset role;
select is(pg_temp.empty_tables('00000000-0000-0000-0000-0000000000a0'), '{}'::text[],
  'every household table has a row to erase (seed a new table here)');
select ok(pg_temp.rows_left('00000000-0000-0000-0000-0000000000a0') > 10, 'the household has data to erase');
select is(public.delete_household_data('b0000000-0000-0000-0000-00000000000b'), 'not_owner',
  'a planner who isn''t the owner can''t delete it');
select is(public.delete_household_data('c0000000-0000-0000-0000-00000000000c'), 'household_deleted',
  'the owner deletes theirs');
select is_empty($$ select 1 from public.households where id = '00000000-0000-0000-0000-0000000000b0' $$,
  'the Carters are gone');
select is(public.delete_household_data('a0000000-0000-0000-0000-00000000000a'), 'household_deleted',
  'Alice deletes the sample family');
select is(pg_temp.rows_left('00000000-0000-0000-0000-0000000000a0'), 0,
  'every household table is empty for it, members and requests included');
select is((select count(*)::int from auth.users where id in ('a0000000-0000-0000-0000-00000000000a',
  'b0000000-0000-0000-0000-00000000000b')), 2, 'Alice and Bob keep their accounts');
select is(public.delete_household_data('a0000000-0000-0000-0000-00000000000a'), 'not_owner',
  'running it again is safe: nothing left to delete');

-- Account deletion uses the same erase.
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a9', 'Real Family', 'a0000000-0000-0000-0000-00000000000a');
select is(public.delete_account_data('a0000000-0000-0000-0000-00000000000a'), 'household_deleted',
  'deleting the owner''s account still deletes their household');

select * from finish();
rollback;
