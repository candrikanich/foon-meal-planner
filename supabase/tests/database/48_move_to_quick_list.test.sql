-- "Couldn't find it" moves a line to the quick list in one step, from the line as it is now (#196).
begin;
select plan(21);

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
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.items (id, household_id, canonical_name, category) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'milk', 'dairy_eggs'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'beef', 'meat_seafood'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'eggs', 'dairy_eggs'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'flour', 'pantry'),
  ('00000000-0000-0000-0000-0000000001a5', '00000000-0000-0000-0000-0000000000a0', 'rice', 'pantry'),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-0000000000b0', 'rice', 'pantry');
insert into public.list_items (id, household_id, item_id, list, note, quantity) values
  -- Milk gained an allergy note after the phone last looked.
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
   'weekly', 'Get dairy-free (Nora)', '1 gal'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2',
   'weekly', 'Get halal (Sam)', null),
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3',
   'weekly', null, null),
  ('00000000-0000-0000-0000-0000000002a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4',
   'weekly', 'Gluten-free (Ty)', null),
  ('00000000-0000-0000-0000-0000000002a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4',
   'quick', 'For Sunday', null),
  ('00000000-0000-0000-0000-0000000002a6', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a5',
   'weekly', 'Get nut-free (Nora)', null);

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

-- The move, by a member.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a1', 'Couldn''t find it last trip', '00000000-0000-0000-0000-0000000003a1') $$, 'a member moves a line');
select is_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000002a1' $$, 'the weekly line is gone');
select is((select list::text from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'), 'quick', 'it''s on the quick list');
select ok((select note from public.list_items where id = '00000000-0000-0000-0000-0000000003a1') like '%Get dairy-free (Nora)%',
  'with a note the phone never saw');
select ok((select note from public.list_items where id = '00000000-0000-0000-0000-0000000003a1') like '%Couldn''t find it last trip%',
  'and why it moved');
select is((select quantity from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'), '1 gal', 'and the amount');

-- The first try's answer never arrived.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a1', 'Couldn''t find it last trip', '00000000-0000-0000-0000-0000000003a1') $$, 'trying again is fine');
select is((select count(*)::int from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1'), 1, 'one line');
select is((select char_length(note) from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'),
  char_length('Get dairy-free (Nora); Couldn''t find it last trip'), 'and nothing said twice');

-- A note the phone's text already quotes isn't repeated.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a2', 'Couldn''t find it last trip; Get halal (Sam)', '00000000-0000-0000-0000-0000000003a2') $$, 'a phone that knew the note');
select is((select note from public.list_items where id = '00000000-0000-0000-0000-0000000003a2'),
  'Couldn''t find it last trip; Get halal (Sam)', 'says it once');

-- A refused add leaves the line where it was.
select throws_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-00000000dead', 'Couldn''t find it last trip', '00000000-0000-0000-0000-0000000003a3') $$, '23503', null, 'no such item');
select isnt_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000002a3' $$, 'and the line stays');

-- Someone already has a quick line for it: both notes stay.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a4', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a4', 'Couldn''t find it last trip', '00000000-0000-0000-0000-0000000003a4') $$, 'onto an open quick line');
select ok((select note from public.list_items where id = '00000000-0000-0000-0000-0000000002a5') like '%For Sunday%'
  and (select note from public.list_items where id = '00000000-0000-0000-0000-0000000002a5') like '%Gluten-free (Ty)%', 'keeps both notes');

-- Bought since the tap.
reset role;
update public.list_items set checked_at = now() where id = '00000000-0000-0000-0000-0000000002a3';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a3', 'Couldn''t find it last trip', '00000000-0000-0000-0000-0000000003a5') $$, 'P0001', null,
  'what''s been bought stays bought');

-- Another household.
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a2', 'Mine now', '00000000-0000-0000-0000-0000000003a6') $$, '42501', null,
  'another household can''t move a line');

-- Carol's own household and item, with the other family's line: she gets a line of her own, and learns and changes nothing.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a6', '00000000-0000-0000-0000-0000000000b0',
  '00000000-0000-0000-0000-0000000001b1', 'Mine now', '00000000-0000-0000-0000-0000000003a7') $$, 'naming another family''s line does nothing to it');
select is((select note from public.list_items where id = '00000000-0000-0000-0000-0000000003a7'), 'Mine now',
  'their note isn''t copied');
reset role;
select is((select note from public.list_items where id = '00000000-0000-0000-0000-0000000002a6'), 'Get nut-free (Nora)',
  'their line keeps its note');
select is((select list::text from public.list_items where id = '00000000-0000-0000-0000-0000000002a6'), 'weekly',
  'and stays where it was');

select * from finish();
rollback;
