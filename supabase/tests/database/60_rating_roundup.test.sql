-- The weekly rating roundup (#47): a device logs it like any reminder, and it stays its own and its household's.
begin;
select plan(4);

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
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    jsonb_build_object('id', '00000000-0000-0000-0000-0000000004a1', 'type', 'rating_roundup',
                       'scheduled_for', '2037-11-07T19:30:00Z', 'sent_at', '2037-11-07T19:30:00Z'))) $$,
  'a device logs a weekly roundup');
select results_eq($$ select type, member_id from public.notification_log $$,
  $$ values ('rating_roundup', '00000000-0000-0000-0000-0000000000a1'::uuid) $$,
  'kept, under whoever sent it, not dropped as a type the log doesn''t know');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*) from public.notification_log), 0::bigint, 'another household can''t read it');
select throws_ok($$ insert into public.notification_log (id, household_id, member_id, type, scheduled_for)
                    values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a0',
                            '00000000-0000-0000-0000-0000000000a1', 'rating_roundup', now()) $$,
  '42501', null, 'or write one for it');

select * from finish();
rollback;
