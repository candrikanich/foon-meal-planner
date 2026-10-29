-- Serving notes (#46, part 2).
begin;
select plan(21);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'eve@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'kid',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Dan', 'planner', false, 'adult',
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Eve', 'member', false, 'adult',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a2', '  No beans, please ') $$, 'Bob writes his own note');
select results_eq($$ select note, written_by_member_id from public.serving_notes $$,
  $$ values ('No beans, please', '00000000-0000-0000-0000-0000000000a2'::uuid) $$, 'trimmed, and Bob is the writer');
select throws_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a3', 'Plain') $$, '42501', null, 'a kid doesn''t write notes for others');
select throws_ok($$ insert into public.serving_notes (household_id, meal_id, member_id, note) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a1',
   'Extra spicy') $$, '42501', null, 'not by writing the table either');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a3', 'Keep everything separate before mixing') $$,
  'a parent writes one for Nora, who has no phone');
select lives_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a2', 'No beans; cheese on the side') $$, 'and can change Bob''s');
select is((select count(*)::int from public.serving_notes), 2, 'one note per person per dish');
select throws_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a3', repeat('x', 121)) $$, '23514', null, 'up to 120 characters');
select lives_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a3', '   ') $$, 'a blank note clears it');
select is((select count(*)::int from public.serving_notes where member_id = '00000000-0000-0000-0000-0000000000a3'), 0,
  'Nora''s note is gone');

select results_eq($$ select written_by_member_id from public.serving_notes
     where member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid) $$, 'rewriting Bob''s note makes Alice the writer');

-- A planner who isn't a parent writes only their own.
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a3', 'Plain') $$, '42501', null, 'planning rights aren''t parent rights');
select lives_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000a4', 'Extra hot sauce') $$, 'Dan writes his own');

-- Bob, a kid, can't touch anyone else's note directly.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select results_eq($$ with gone as (delete from public.serving_notes
     where member_id = '00000000-0000-0000-0000-0000000000a4' returning 1) select count(*)::int from gone $$,
  $$ values (0) $$, 'deleting Dan''s note does nothing');
select results_eq($$ with changed as (update public.serving_notes set note = 'x'
     where member_id = '00000000-0000-0000-0000-0000000000a4' returning 1) select count(*)::int from changed $$,
  $$ values (0) $$, 'nor does changing it');
select throws_ok($$ update public.serving_notes set written_by_member_id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'and the writer can''t be claimed');

select is((select jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'serving_notes')), 2,
  'a planner''s export includes the notes') from (select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a')) x;

-- Retention.
reset role;
insert into public.serving_notes (household_id, meal_id, member_id, note, written_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a5',
   'Mild', '00000000-0000-0000-0000-0000000000a5');
select public.delete_account_data('e0000000-0000-0000-0000-00000000000e');
select is_empty($$ select 1 from public.serving_notes where member_id = '00000000-0000-0000-0000-0000000000a5' $$,
  'deleting Eve''s account deletes notes about her');
-- Bob writes his own, then his parent writes one for him on another dish; his own-device consent is later withdrawn.
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Tacos');
update public.serving_notes set written_by_member_id = '00000000-0000-0000-0000-0000000000a2'
  where member_id = '00000000-0000-0000-0000-0000000000a2';
insert into public.serving_notes (household_id, meal_id, member_id, note, written_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a2',
   'No onions', '00000000-0000-0000-0000-0000000000a1');
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-v1', now() - interval '60 days', now() - interval '31 days');
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a2';
select public.anonymize_expired_profiles();
select results_eq($$ select note from public.serving_notes where member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values ('No onions') $$, 'a withdrawn kid''s own note goes; the one a parent wrote stays');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.serving_notes $$, 'another household sees no notes');
select throws_ok($$ select public.set_serving_note('00000000-0000-0000-0000-0000000002a1',
  '00000000-0000-0000-0000-0000000000c1', 'Hi') $$, 'P0002', null, 'or writes on its dishes');

select * from finish();
rollback;
