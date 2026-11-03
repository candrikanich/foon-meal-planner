-- Deleting a kid's own account (#187): the serving notes they wrote and the notes on requests they made themselves go;
-- what a parent wrote for them, and the rest of their history, stays.
begin;
select plan(8);

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'nora@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Salad');
insert into public.serving_notes (household_id, meal_id, member_id, note, written_by_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a3',
   'No cheese on mine', '00000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a3',
   'Dressing on the side', '00000000-0000-0000-0000-0000000000a1');
insert into public.requests (id, household_id, requested_by_member_id, title, note, entered_by_member_id) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3',
   'Crab legs', 'For my birthday week', '00000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3',
   'Pancakes', 'She asked at breakfast', '00000000-0000-0000-0000-0000000000a1');

select is(public.delete_account_data('e0000000-0000-0000-0000-00000000000e'), 'unlinked', 'a kid''s account is unlinked');

select is((select count(*)::int from public.serving_notes where written_by_member_id = '00000000-0000-0000-0000-0000000000a3'),
  0, 'the serving note she wrote goes');
select is((select note from public.serving_notes where meal_id = '00000000-0000-0000-0000-0000000002a2'),
  'Dressing on the side', 'the one her parent wrote for her stays');
select is((select note from public.requests where id = '00000000-0000-0000-0000-0000000007a1'), null,
  'the note on a request she made herself is cleared');
select is((select title from public.requests where id = '00000000-0000-0000-0000-0000000007a1'), 'Crab legs',
  'the request itself stays');
select is((select note from public.requests where id = '00000000-0000-0000-0000-0000000007a2'), 'She asked at breakfast',
  'a request her parent entered for her keeps its note');
select is((select first_name from public.members where id = '00000000-0000-0000-0000-0000000000a3'), 'Nora',
  'the profile her parents entered stays');
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a3'), null,
  'with no account linked');

select * from finish();
rollback;
