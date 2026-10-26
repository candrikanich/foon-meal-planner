-- Offline sync support (#11): add_to_list accepts the line id the device already uses, and
-- item stock changes stream over Realtime.
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
insert into public.members (household_id, first_name, role, user_id) values
  ('00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'a0000000-0000-0000-0000-00000000000a');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Milk');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
                              'quick', line_id => '5ee00000-0000-0000-0000-000000000001')).id,
  '5ee00000-0000-0000-0000-000000000001'::uuid, 'a new line keeps the id the device chose offline');
select is((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
                              'quick', 'tonight', line_id => '5ee00000-0000-0000-0000-000000000002')).id,
  '5ee00000-0000-0000-0000-000000000001'::uuid, 'adding again merges into the open line and returns its id');
select isnt((public.add_to_list('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000001a1',
                                'weekly')).id, null, 'without a device id the server picks one');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'items'),
  'item stock changes stream over Realtime');

select * from finish();
rollback;
