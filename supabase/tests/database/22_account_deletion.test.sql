-- Account deletion and export (#29): what deleting an account does to the data, and the planner's export.
begin;
select plan(19);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'nora@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.consents (household_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v1');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'milk'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'eggs');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Taco shells'),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'Saffron');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Salad');
insert into public.meal_sides (household_id, meal_id, side_meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   '00000000-0000-0000-0000-0000000002a2');
insert into public.traditions (household_id, weekday, meal_id) values
  ('00000000-0000-0000-0000-0000000000a0', 2, '00000000-0000-0000-0000-0000000002a1');
insert into public.invite_redeem_attempts (user_id, succeeded) values ('b0000000-0000-0000-0000-00000000000b', false);
insert into public.meal_ingredients (household_id, meal_id, item_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   '00000000-0000-0000-0000-0000000001a1');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
create temp table week on commit drop as
  select * from public.create_week('00000000-0000-0000-0000-0000000000a0', '2026-11-01');
update public.plan_nights set meal_id = '00000000-0000-0000-0000-0000000002a1'
  where plan_id = (select id from week) and date = '2026-11-02';
insert into public.list_items (household_id, item_id, list, source) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'manual');

-- Export ----------------------------------------------------------------------------------------
create temp table export on commit drop as
  select public.export_household('00000000-0000-0000-0000-0000000000a0') as data;
grant select on export to authenticated, service_role;
select is((select data -> 'household' ->> 'name' from export), 'Andersons', 'a planner exports the household');
select is((select jsonb_array_length(data -> 'members') from export), 3, 'with everyone in it');
select ok((select not exists (select 1 from jsonb_array_elements(data -> 'members') m where m ? 'user_id')
           and not (data -> 'household' ? 'owner')
           and not exists (select 1 from jsonb_array_elements(data -> 'consents') c where c ? 'granted_by') from export),
  'without account ids');
select is((select jsonb_array_length(data -> 'nights') from export), 7, 'and the week');
select ok((select data -> 'meals' @> '[{"name": "Tacos"}]' and jsonb_array_length(data -> 'list_items') = 1
           and jsonb_array_length(data -> 'allergies') = 2 from export), 'meals, lists, and allergies too');

select throws_ok($$ select public.delete_account_data('a0000000-0000-0000-0000-00000000000a') $$,
  '42501', null, 'the app cannot call account deletion directly');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.export_household('00000000-0000-0000-0000-0000000000a0') $$,
  '42501', null, 'only planners export');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.export_household('00000000-0000-0000-0000-0000000000a0') $$,
  '42501', null, 'another household cannot export it');

-- Deletion (the delete-account Edge Function, as the service role) ------------------------------
select set_config('request.jwt.claims', '', true);
set local role service_role;

select is(public.delete_account_data('b0000000-0000-0000-0000-00000000000b'), 'profile_anonymized',
  'an adult''s profile is anonymized');
select results_eq(
  $$ select first_name, status::text, user_id, avatar, anonymized_at is not null from public.members
     where id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values ('Former member', 'removed', null::uuid, null::text, true) $$,
  'removed, unlinked, and nameless; their history stays with the profile');
select is_empty($$ select 1 from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  'and their allergies are gone');
select is_empty($$ select 1 from public.invite_redeem_attempts where user_id = 'b0000000-0000-0000-0000-00000000000b' $$,
  'and their invite attempts');

select is(public.delete_account_data('e0000000-0000-0000-0000-00000000000e'), 'unlinked', 'a kid''s account is unlinked');
select results_eq(
  $$ select first_name, status::text, user_id from public.members where id = '00000000-0000-0000-0000-0000000000a3' $$,
  $$ values ('Nora', 'active', null::uuid) $$,
  'the profile their parent entered stays with the family');

select is(public.delete_account_data('d0000000-0000-0000-0000-00000000000d'), 'no_household',
  'someone without a household has nothing to erase');

select is(public.delete_account_data('a0000000-0000-0000-0000-00000000000a'), 'household_deleted',
  'the owner''s household is deleted');
select is(
  (select count(*)::int from (
     select household_id from public.members union all select household_id from public.meals
     union all select household_id from public.items union all select household_id from public.plans
     union all select household_id from public.plan_nights union all select household_id from public.night_attendance
     union all select household_id from public.list_items union all select household_id from public.consents
     union all select household_id from public.member_allergies union all select household_id from public.meal_ingredients
     union all select id from public.households) rows
   where household_id = '00000000-0000-0000-0000-0000000000a0'),
  0, 'with everything in it');
-- Every table with a household_id, including ones added later: a new table needs its own delete line.
create function pg_temp.rows_left(target uuid) returns int language plpgsql as $f$
declare
  t text;
  total int := 0;
  n int;
begin
  for t in select table_name from information_schema.columns c
           join information_schema.tables using (table_schema, table_name)
           where c.table_schema = 'public' and c.column_name = 'household_id' and table_type = 'BASE TABLE' loop
    execute format('select count(*)::int from public.%I where household_id = $1', t) into n using target;
    total := total + n;
  end loop;
  return total;
end;
$f$;
select is(pg_temp.rows_left('00000000-0000-0000-0000-0000000000a0'), 0, 'no household table keeps a row');
select results_eq(
  $$ select (select count(*)::int from public.households where id = '00000000-0000-0000-0000-0000000000b0'),
            (select count(*)::int from public.members where household_id = '00000000-0000-0000-0000-0000000000b0'),
            (select count(*)::int from public.items where household_id = '00000000-0000-0000-0000-0000000000b0') $$,
  $$ values (1, 1, 1) $$, 'another household is untouched');

select * from finish();
rollback;
