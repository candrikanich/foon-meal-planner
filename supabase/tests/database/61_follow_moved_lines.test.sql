-- A check-off queued against a line "Couldn't find it" moved follows it to the quick list (#201). And items never merge, so a
-- queued stock change reaches the item it was made for, by whatever name.
begin;
select plan(19);

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
insert into public.items (id, household_id, canonical_name, category, keep_on_hand, stock_state) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'milk', 'dairy_eggs', true, 'out'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'flour', 'pantry', false, null),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'eggs', 'dairy_eggs', false, null);
insert into public.list_items (id, household_id, item_id, list, note) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
   'weekly', 'Get dairy-free (Nora)'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2',
   'weekly', 'Gluten-free (Ty)'),
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2',
   'quick', 'For Sunday'),
  ('00000000-0000-0000-0000-0000000002a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3',
   'weekly', null);

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Alice couldn't find milk: it moves to the quick list under a new id, and remembers where it came from.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a1', 'Couldn''t find it', '00000000-0000-0000-0000-0000000003a1') $$, 'the move');
select is((select moved_from from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'),
  '00000000-0000-0000-0000-0000000002a1'::uuid, 'the quick line knows the line it came from');

-- Her phone never heard back and tries again: the line it came from is gone by then, and stays remembered.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a1', 'Couldn''t find it', '00000000-0000-0000-0000-0000000003a1') $$, 'a retry');
select is((select moved_from from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'),
  '00000000-0000-0000-0000-0000000002a1'::uuid, 'still remembered');

-- Flour moves onto the quick line someone already added.
select lives_ok($$ select public.move_to_quick_list('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000001a2', 'Couldn''t find it', '00000000-0000-0000-0000-0000000003a2') $$, 'a move that merges');
select is((select moved_from from public.list_items where id = '00000000-0000-0000-0000-0000000002a3'),
  '00000000-0000-0000-0000-0000000002a2'::uuid, 'the line it merged into knows too');

-- Carol, in another household, can't see where a line came from, or follow it.
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.list_items where moved_from = '00000000-0000-0000-0000-0000000002a2' $$,
  'another household can''t see it');
select is_empty($$ update public.list_items set checked_at = now()
  where moved_from = '00000000-0000-0000-0000-0000000002a2' and checked_at is null returning id $$,
  'or check it off by following it');
reset role;
select is((select checked_at from public.list_items where id = '00000000-0000-0000-0000-0000000002a3'), null,
  'so flour''s still on the list');

-- Bob checked milk off offline before the move. His update finds the weekly line gone and follows it, as the app does.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is_empty($$ update public.list_items set checked_at = now()
  where id = '00000000-0000-0000-0000-0000000002a1' returning id $$, 'the weekly line is gone');
select results_eq($$ update public.list_items set checked_at = now()
  where moved_from = '00000000-0000-0000-0000-0000000002a1' and checked_at is null returning id $$,
  $$ values ('00000000-0000-0000-0000-0000000003a1'::uuid) $$, 'so the check-off follows it to the quick line');
select is((select checked_by from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'checked off by Bob');

-- Alice's own queued check-off follows too, after Bob's: the line's bought already, so it matches nothing and keeps Bob's stamp.
reset role;
create temp table bought as select checked_at, checked_by from public.list_items where id = '00000000-0000-0000-0000-0000000003a1';
grant select on bought to authenticated;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is_empty($$ update public.list_items set checked_at = now()
  where moved_from = '00000000-0000-0000-0000-0000000002a1' and checked_at is null returning id $$,
  'a line bought since has nothing to follow onto');
select is((select checked_at from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'),
  (select checked_at from bought), 'when it was bought stays');
select is((select checked_by from public.list_items where id = '00000000-0000-0000-0000-0000000003a1'),
  (select checked_by from bought), 'and who bought it');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

-- A line taken off another way left nothing behind to follow.
delete from public.list_items where id = '00000000-0000-0000-0000-0000000002a4';
select is_empty($$ select 1 from public.list_items where moved_from = '00000000-0000-0000-0000-0000000002a4' $$,
  'a removed line has nowhere to go');

-- Items: renaming keeps the id, so a queued stock change still reaches it, and no rename merges two items.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.items set canonical_name = 'Whole milk' where id = '00000000-0000-0000-0000-0000000001a1';
select results_eq($$ update public.items set stock_state = 'in', keep_on_hand = true
  where id = '00000000-0000-0000-0000-0000000001a1' returning canonical_name $$,
  $$ values ('Whole milk'::text) $$, 'a restock queued before a rename reaches the renamed item');
select throws_ok($$ update public.items set canonical_name = 'Flour' where id = '00000000-0000-0000-0000-0000000001a1' $$,
  '23505', null, 'a rename onto another item''s name is refused, so items never merge');
select is((select count(*)::int from public.items where household_id = '00000000-0000-0000-0000-0000000000a0'), 3,
  'and every item is still there');

select * from finish();
rollback;
