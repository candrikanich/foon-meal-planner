-- A line a staple put on the quick list stops being the staple's once something else is added to it (#203).
begin;
select plan(4);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a');
insert into public.items (id, household_id, canonical_name, category) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'milk', 'dairy_eggs'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'bread', 'bakery');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Milk ran out, then tonight's swap needs it.
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'whenever', 'staple',
  null, '00000000-0000-0000-0000-0000000002a1');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'quick', 'tonight', 'pivot',
  'Get dairy-free (Sam)', '00000000-0000-0000-0000-0000000002a2', '1 cup');
select is((select source::text from public.list_items where id = '00000000-0000-0000-0000-0000000002a1'), 'pivot',
  'a pivot merged into a staple''s line makes it the pivot''s');

-- Marking milk back in only takes off what a staple put there.
delete from public.list_items where id = '00000000-0000-0000-0000-0000000002a1' and source = 'staple' and checked_at is null;
select isnt_empty($$ select 1 from public.list_items where id = '00000000-0000-0000-0000-0000000002a1' $$,
  'so marking it back in leaves tonight''s need and its note');

-- Bread was added by hand, then ran out: it stays the hand-added line.
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick', 'whenever', 'manual',
  null, '00000000-0000-0000-0000-0000000002b1');
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick', 'whenever', 'staple',
  null, '00000000-0000-0000-0000-0000000002b2');
select is((select source::text from public.list_items where id = '00000000-0000-0000-0000-0000000002b1'), 'manual',
  'a staple merged into another line doesn''t take it over');
select is((select count(*)::int from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2'), 1, 'one line');

select * from finish();
rollback;
