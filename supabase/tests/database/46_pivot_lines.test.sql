-- What a pivot puts on the quick list (#44): notes merge rather than being lost, amounts come along, and Update the list
-- doesn't list again what a pivot line already bought.
begin;
select plan(23);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult', 'a0000000-0000-0000-0000-00000000000a');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Milk'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Tomatoes'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Cheese'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'Rice'),
  ('00000000-0000-0000-0000-0000000001a5', '00000000-0000-0000-0000-0000000000a0', 'Beans'),
  ('00000000-0000-0000-0000-0000000001a6', '00000000-0000-0000-0000-0000000000a0', 'Beef'),
  ('00000000-0000-0000-0000-0000000001a7', '00000000-0000-0000-0000-0000000000a0', 'Cereal'),
  ('00000000-0000-0000-0000-0000000001a8', '00000000-0000-0000-0000-0000000000a0', 'Onions'),
  ('00000000-0000-0000-0000-0000000001a9', '00000000-0000-0000-0000-0000000000a0', 'Yogurt');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', current_date - 1),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', current_date + 6);

create function pg_temp.add(item text, note text, urgency public.list_urgency default 'whenever', quantity text default null,
                            plan uuid default '00000000-0000-0000-0000-0000000003a1')
returns public.list_items language sql as $$
  select public.add_to_list('00000000-0000-0000-0000-0000000000a0', item::uuid, 'quick', urgency, 'pivot', note,
                            null, quantity, plan);
$$;

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Notes
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a1', 'Couldn''t find it last trip')).note,
  'Couldn''t find it last trip', 'a new line keeps its note');
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a1', 'Get dairy-free (Nora)')).note,
  'Get dairy-free (Nora); Couldn''t find it last trip', 'a different note joins the one there, newest first');
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a1', 'Get dairy-free (Nora)')).note,
  'Get dairy-free (Nora); Couldn''t find it last trip', 'the same note isn''t repeated');
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a1', null)).note,
  'Get dairy-free (Nora); Couldn''t find it last trip', 'no note leaves what''s there');
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a1', 'Get dairy-free (Nora, Owen)')).note,
  'Get dairy-free (Nora, Owen); Get dairy-free (Nora); Couldn''t find it last trip', 'someone new on an allergy note is kept');
select is(public.merge_line_notes(repeat('a', 140), repeat('b', 140)), repeat('b', 140) || '; ' || repeat('a', 140),
  'two full notes fit');
select is(char_length(public.merge_line_notes(repeat('a', 400), 'b')), 400, 'past the limit the oldest text is cut');
select ok(public.merge_line_notes(repeat('a', 400), 'Get dairy-free (Nora)') like 'Get dairy-free (Nora); %…',
  'with the newest note whole and the cut showing');

-- Amounts
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a2', null, 'whenever', '2 cans')).quantity, '2 cans', 'a line takes an amount');
select is((pg_temp.add('00000000-0000-0000-0000-0000000001a2', null, 'tonight', '5 cans')).quantity, '2 cans', 'and keeps it on a merge');
select is((select urgency::text from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2'), 'tonight',
  'urgency still goes up');

-- Update the list
update public.list_items set checked_at = now() where item_id = '00000000-0000-0000-0000-0000000001a2';
select pg_temp.add('00000000-0000-0000-0000-0000000001a4', null);
update public.list_items set checked_at = now() where item_id = '00000000-0000-0000-0000-0000000001a4';
select pg_temp.add('00000000-0000-0000-0000-0000000001a6', null, 'whenever', '1 lb');
select pg_temp.add('00000000-0000-0000-0000-0000000001a7', null);
select pg_temp.add('00000000-0000-0000-0000-0000000001a8', null, 'whenever', null, null);
select pg_temp.add('00000000-0000-0000-0000-0000000001a9', null);
update public.list_items set checked_at = now()
  where item_id in ('00000000-0000-0000-0000-0000000001a6', '00000000-0000-0000-0000-0000000001a7',
                    '00000000-0000-0000-0000-0000000001a8');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "2 cans"},
  {"item_id": "00000000-0000-0000-0000-0000000001a4", "note": "Check for sesame (Owen)"},
  {"item_id": "00000000-0000-0000-0000-0000000001a5", "quantity": "1 can"},
  {"item_id": "00000000-0000-0000-0000-0000000001a6", "quantity": "2 lb (doubled)"},
  {"item_id": "00000000-0000-0000-0000-0000000001a7", "staple": true},
  {"item_id": "00000000-0000-0000-0000-0000000001a8"}
]'::jsonb);
select is_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2' and list = 'weekly' $$,
  'what a pivot line already bought this week isn''t listed again');
select is((select note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a4' and list = 'weekly'),
  'Check for sesame (Owen)', 'unless there''s an allergy note the bought line didn''t have');
select is((select quantity from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a5' and list = 'weekly'),
  '1 can', 'anything else goes on as usual');

select is((select quantity from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a6' and list = 'weekly'),
  '2 lb (doubled)', 'a pivot line that bought less doesn''t cover the rest');
select isnt_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a7' and list = 'weekly' $$,
  'a staple that''s run low again goes back on');
select isnt_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a8' and list = 'weekly' $$,
  'a line with no plan says nothing about this week');
select isnt_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a9' and list = 'quick' and checked_at is null $$,
  'the week''s clear-out leaves an open pivot line alone');

update public.list_items set checked_at = now()
  where item_id = '00000000-0000-0000-0000-0000000001a5' and list = 'weekly';
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a5", "quantity": "1 can", "note": "Check for sesame (Owen)"}
]'::jsonb);
select is((select note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a5' and list = 'weekly' and checked_at is null),
  'Check for sesame (Owen)', 'a weekly line already bought goes back on for an allergy note it didn''t have');

select public.approve_plan('00000000-0000-0000-0000-0000000003a2',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "2 cans"}]'::jsonb);
select is((select plan_id from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2' and checked_at is null),
  '00000000-0000-0000-0000-0000000003a2'::uuid, 'next week still needs it, whenever the pivot line was bought');

-- A line approve_plan doesn't own
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a3', 'weekly',
                          item_note => 'the sharp one');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a3", "note": "Get dairy-free (Nora)"}]'::jsonb);
select is((select note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3'),
  'Get dairy-free (Nora); the sharp one', 'a hand-added line gains an allergy note and keeps its own');
select is((select plan_id from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3'), null,
  'and stays hand-added');

-- The limit
select throws_ok($$ insert into public.list_items (household_id, item_id, list, note) values
    ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a5', 'quick', repeat('x', 401)) $$,
  '23514', null, 'a note past the limit is refused');

select * from finish();
rollback;
