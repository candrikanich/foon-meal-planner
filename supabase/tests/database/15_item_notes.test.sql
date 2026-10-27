-- Non-food items, item notes and brands (#33).
begin;
select plan(11);

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
insert into public.members (id, household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'c0000000-0000-0000-0000-00000000000c');
insert into public.items (id, household_id, canonical_name, category) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Yogurt', 'dairy_eggs');

select ok('personal_care' = any(enum_range(null::public.item_category)::text[]), 'personal care is an item category');
select has_column('public', 'items', 'note', 'items carry a standing note or brand preference');

-- A planner adds non-food items, including staples ------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ insert into public.items (id, household_id, canonical_name, category, keep_on_hand, stock_state, note) values
       ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Toothpaste',
        'personal_care', true, 'low', 'the kids'' bubblegum one') $$,
  'a personal care item can be a keep-on-hand staple with a note');
select is((public.ensure_item('00000000-0000-0000-0000-0000000000a0', 'Paper towels', 'household')).category::text,
  'household', 'household items are created like any other');

-- Anyone at home sets a note; only planners recategorize -------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok(
  $$ update public.items set note = 'Vanilla, not plain' where id = '00000000-0000-0000-0000-0000000001a1' $$,
  'a member sets an item''s note');
select is((select note from public.items where id = '00000000-0000-0000-0000-0000000001a1'), 'Vanilla, not plain',
  'the note is saved');
select throws_ok(
  $$ update public.items set category = 'personal_care' where id = '00000000-0000-0000-0000-0000000001a1' $$,
  '42501', null, 'a member still cannot recategorize an item');
select lives_ok(
  $$ update public.items set note = null where id = '00000000-0000-0000-0000-0000000001a1' $$,
  'a note can be cleared');
select throws_ok(
  $$ update public.items set note = repeat('x', 81) where id = '00000000-0000-0000-0000-0000000001a1' $$,
  '23514', null, 'notes stay short');
select throws_ok(
  $$ update public.items set note = '   ' where id = '00000000-0000-0000-0000-0000000001a1' $$,
  '23514', null, 'a blank note is cleared, not stored');

-- Another household sees and changes nothing -------------------------------------------------
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
update public.items set note = 'hacked' where id = '00000000-0000-0000-0000-0000000001a1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select note from public.items where id = '00000000-0000-0000-0000-0000000001a1'), null,
  'another household cannot set a note');

select * from finish();
rollback;
