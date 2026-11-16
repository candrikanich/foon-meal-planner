-- A list line remembers which nights' dishes it's for (#337): approve_plan writes list_item_nights from each line's night_ids.
begin;
select plan(14);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult', 'c0000000-0000-0000-0000-00000000000c');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Milk'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Cheese'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Eggs');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2026-11-01'),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', '2026-11-08');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000b0', '2026-11-01');
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1', '2026-11-03'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1', '2026-11-06'),
  ('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2', '2026-11-10'),
  ('00000000-0000-0000-0000-0000000004b1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000003b1', '2026-11-03');

create function pg_temp.line(item text) returns uuid language sql as $$
  select id from public.list_items where item_id = item::uuid and checked_at is null;
$$;
create function pg_temp.nights(item text) returns text[] language sql as $$
  select coalesce(array_agg(n.plan_night_id::text order by n.plan_night_id), '{}')
  from public.list_item_nights n where n.list_item_id = pg_temp.line(item);
$$;

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Milk is for two nights, cheese for one, eggs for none. Milk also names next week's night, which isn't this plan's.
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1",
   "night_ids": ["00000000-0000-0000-0000-0000000004a1", "00000000-0000-0000-0000-0000000004a2", "00000000-0000-0000-0000-0000000004a3"]},
  {"item_id": "00000000-0000-0000-0000-0000000001a2", "night_ids": ["00000000-0000-0000-0000-0000000004a1"]},
  {"item_id": "00000000-0000-0000-0000-0000000001a3"}
]'::jsonb);

select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a1'),
  array['00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000004a2'],
  'approve links a line to its nights and ignores a night from another plan');
select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a2'), array['00000000-0000-0000-0000-0000000004a1'],
  'each line gets its own nights');
select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a3'), '{}'::text[], 'a line with no night_ids has none');

-- Update the list again: milk now only for the second night, cheese dropped, eggs gains a night; a repeated id is one row.
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "night_ids": ["00000000-0000-0000-0000-0000000004a2"]},
  {"item_id": "00000000-0000-0000-0000-0000000001a3",
   "night_ids": ["00000000-0000-0000-0000-0000000004a1", "00000000-0000-0000-0000-0000000004a1"]}
]'::jsonb);

select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a1'), array['00000000-0000-0000-0000-0000000004a2'],
  'approving again replaces this week''s rows');
select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a3'), array['00000000-0000-0000-0000-0000000004a1'],
  'a line gaining a night gets it once');
select is_empty($$ select 1 from public.list_item_nights where plan_night_id = '00000000-0000-0000-0000-0000000004a1'
                   and list_item_id not in (select id from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3') $$,
  'an item the week dropped loses its rows');

-- Next week lists milk too, so it merges into this week's line. Its rows for next week's night sit beside this week's.
select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "night_ids": ["00000000-0000-0000-0000-0000000004a3"]}
]'::jsonb);
select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a1'),
  array['00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000004a3'],
  'another week''s approve leaves this week''s rows alone');

select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1"}
]'::jsonb);
select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a1'), array['00000000-0000-0000-0000-0000000004a3'],
  'this week''s update clears only this week''s nights');

-- Another household sees and writes nothing.
create temp table milk on commit drop as select pg_temp.line('00000000-0000-0000-0000-0000000001a1') as id;
grant select on milk to authenticated;

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.list_item_nights $$, 'another household can''t read the rows');
select throws_ok($$ insert into public.list_item_nights (household_id, list_item_id, plan_night_id)
    select '00000000-0000-0000-0000-0000000000a0', id, '00000000-0000-0000-0000-0000000004a1' from milk $$,
  '42501', null, 'or add a row to another household''s line');
select throws_ok($$ insert into public.list_item_nights (household_id, list_item_id, plan_night_id)
    select '00000000-0000-0000-0000-0000000000b0', id, '00000000-0000-0000-0000-0000000004b1' from milk $$,
  '23503', null, 'or pair its own household with another household''s line');

-- A row can't join a line to a night from another household.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.list_item_nights (household_id, list_item_id, plan_night_id)
    select '00000000-0000-0000-0000-0000000000a0', id, '00000000-0000-0000-0000-0000000004b1' from milk $$,
  '23503', null, 'a row can''t pair a line with another household''s night');

-- Deleting a line or a night takes its rows with it.
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1",
   "night_ids": ["00000000-0000-0000-0000-0000000004a1", "00000000-0000-0000-0000-0000000004a2"]}
]'::jsonb);
reset role;
delete from public.plan_nights where id = '00000000-0000-0000-0000-0000000004a1';
select is(pg_temp.nights('00000000-0000-0000-0000-0000000001a1'),
  array['00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000004a3'],
  'deleting a night removes its rows');
delete from public.list_items where id = (select id from milk);
select is_empty($$ select 1 from public.list_item_nights $$, 'deleting a line removes its rows');

select * from finish();
rollback;
