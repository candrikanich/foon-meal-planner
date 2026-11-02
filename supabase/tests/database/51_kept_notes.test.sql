-- A week's Update the list rebuilds its own lines' notes without losing notes that came from elsewhere (#197).
begin;
select plan(8);

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
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Flour');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', current_date - 1),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0', current_date + 6);

create function pg_temp.milk_note() returns text language sql as $$
  select note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a1' and checked_at is null;
$$;

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "note": "Get dairy-free (Nora)"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a2',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "note": "Get dairy-free (Owen)"}]'::jsonb);
select is(pg_temp.milk_note(), 'Get dairy-free (Owen); Get dairy-free (Nora)', 'next week''s note joins this week''s line');

select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1"}]'::jsonb);
select is(pg_temp.milk_note(), 'Get dairy-free (Owen)',
  'updating this week drops its own old note and keeps next week''s');

select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "note": "Get dairy-free (Nora)"}]'::jsonb);
select is(pg_temp.milk_note(), 'Get dairy-free (Nora); Get dairy-free (Owen)', 'and its own new note goes on top');

select public.approve_plan('00000000-0000-0000-0000-0000000003a2',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1", "note": "Get dairy-free (Nora)"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1"}]'::jsonb);
select is(pg_temp.milk_note(), 'Get dairy-free (Nora); Get dairy-free (Owen)',
  'a note both weeks wrote stays when one of them drops it');

select public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1', 'weekly',
                          item_note => 'the big jug');
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a1"}]'::jsonb);
select ok(pg_temp.milk_note() like 'the big jug; %', 'a note added by hand survives the week''s update');

select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a2", "note": "Get gluten-free (Nora)"}]'::jsonb);
select public.approve_plan('00000000-0000-0000-0000-0000000003a1',
  '[{"item_id": "00000000-0000-0000-0000-0000000001a2"}]'::jsonb);
select is((select note from public.list_items where item_id = '00000000-0000-0000-0000-0000000001a2' and checked_at is null),
  null, 'a line with only its own week''s note still loses it when the dish goes');

select is((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'quick',
                               item_note => 'Couldn''t find it')).kept_note,
  'Couldn''t find it', 'a line add_to_list starts keeps its note as its own');

select throws_ok($$ insert into public.list_items (household_id, item_id, list, kept_note) values
    ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a2', 'weekly', repeat('x', 401)) $$,
  '23514', null, 'a kept note past the limit is refused');

select * from finish();
rollback;
