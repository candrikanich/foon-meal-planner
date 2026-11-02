-- A week that drops an item hands its line to another week that also listed it, rather than deleting that need (#209).
begin;
select plan(13);

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
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Cheese'),
  ('00000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000a0', 'Flour'),
  ('00000000-0000-0000-0000-0000000001a4', '00000000-0000-0000-0000-0000000000a0', 'Eggs');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', current_date - 1),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', current_date + 6);

create function pg_temp.line(item text) returns public.list_items language sql as $$
  select * from public.list_items where item_id = item::uuid and checked_at is null;
$$;

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "1 gallon", "note": "Get dairy-free (Nora)"},
  {"item_id": "00000000-0000-0000-0000-0000000001a2", "quantity": "8 oz"},
  {"item_id": "00000000-0000-0000-0000-0000000001a3"},
  {"item_id": "00000000-0000-0000-0000-0000000001a4"}
]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "note": "Get dairy-free (Owen)"},
  {"item_id": "00000000-0000-0000-0000-0000000001a4"}
]'::jsonb);
select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'weekly',
                          item_note => 'the sharp one');

-- Next week drops eggs before this week does, so eggs isn't handed to it.
select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "note": "Get dairy-free (Owen)"}
]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);

select is((pg_temp.line('00000000-0000-0000-0000-0000000001a1')).plan_id, '00000000-0000-0000-0000-0000000003a2'::uuid,
  'a line next week also needs goes to next week');
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a1')).note, 'Get dairy-free (Owen)',
  'with next week''s note and not this week''s');
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a1')).quantity, null, 'and no amount, which was this week''s');
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a2')).plan_id, null, 'a line with a hand-added note stays');
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a2')).note, 'the sharp one', 'as a hand-added line with that note');
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a2')).source::text, 'manual', 'that reads as added by hand');
select is_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3' and checked_at is null $$,
  'a line only this week needed goes');
select is_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a4' and checked_at is null $$,
  'one next week stopped needing goes too');

select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "2 cups", "note": "Get dairy-free (Owen)"}
]'::jsonb);
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a1')).quantity, '2 cups', 'next week''s update makes it its own');

select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[
  {"item_id": "00000000-0000-0000-0000-0000000001a1", "quantity": "2 cups"}
]'::jsonb);
select is((pg_temp.line('00000000-0000-0000-0000-0000000001a1')).note, null,
  'and can take its own note off once it owns the line');
select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[]'::jsonb);
select is_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1' and checked_at is null $$,
  'a line handed on goes when that week drops it too');

-- The other order: next week drops a noted item first, then this week does.
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a3"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a2',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a3", "note": "Get gluten-free (Owen)"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a2', '[]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a1', '[]'::jsonb);
select is_empty($$ select 1 from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a3' and checked_at is null $$,
  'another week''s note alone doesn''t keep a line no week needs');

select is((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a4', 'quick',
                               item_note => 'brown')).hand_note, 'brown', 'a note added by hand is recorded as one');

select * from finish();
rollback;
