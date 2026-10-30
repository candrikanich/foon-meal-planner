-- Cook credit (#46, part 1): Thanks, chef.
begin;
select plan(15);

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
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'kid',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili');
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, now()),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 30, now());
insert into public.plan_nights (id, household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, '00000000-0000-0000-0000-0000000002a1'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 30, '00000000-0000-0000-0000-0000000002a1');
insert into public.meal_logs (id, household_id, night_id, meal_id, cooked_by_member_id, leftovers) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1',
   '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a1', false),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a2',
   '00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a1', false);
insert into public.plan_nights (id, household_id, plan_id, date, quick_pick) values
  ('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0'), 'takeout');
insert into public.meal_logs (id, household_id, night_id, quick_pick, cooked_by_member_id, leftovers) values
  ('00000000-0000-0000-0000-0000000005a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a3',
   'takeout', '00000000-0000-0000-0000-0000000000a1', false);

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.thank_the_chef('00000000-0000-0000-0000-0000000005a1') $$, 'Bob thanks Alice for the chili');
select lives_ok($$ select public.thank_the_chef('00000000-0000-0000-0000-0000000005a1') $$, 'twice is fine');
select results_eq($$ select from_member_id from public.chef_thanks $$,
  $$ values ('00000000-0000-0000-0000-0000000000a2'::uuid) $$, 'once, from Bob''s own profile');
select throws_ok($$ select public.thank_the_chef('00000000-0000-0000-0000-0000000005a2') $$, '22023', null,
  'not for a dinner from a month ago');
select throws_ok($$ insert into public.chef_thanks (household_id, meal_log_id, from_member_id) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'nobody writes thanks directly (or in someone else''s name)');
select throws_ok($$ delete from public.chef_thanks $$, '42501', null, 'thanks are never taken back');
select throws_ok($$ select public.thank_the_chef('00000000-0000-0000-0000-0000000005a3') $$, '22023', null,
  'takeout isn''t a cooked dish');
select throws_ok($$ update public.meal_logs set cooked_by_member_id = '00000000-0000-0000-0000-0000000000a2'
  where id = '00000000-0000-0000-0000-0000000005a1' $$, 'FD011', null,
  'once thanked, the cook can''t be changed to someone else (here, Bob himself)');
select lives_ok($$ update public.meal_logs set leftovers = true where id = '00000000-0000-0000-0000-0000000005a1' $$,
  'leftovers can still be answered');
select lives_ok($$ update public.meal_logs set cooked_by_member_id = '00000000-0000-0000-0000-0000000000a2'
  where id = '00000000-0000-0000-0000-0000000005a2' $$, 'an unthanked dinner''s cook can still be corrected');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.thank_the_chef('00000000-0000-0000-0000-0000000005a1') $$, '22023', null,
  'no thanking yourself');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.chef_thanks $$, 'another household sees no thanks');
select throws_ok($$ select public.thank_the_chef('00000000-0000-0000-0000-0000000005a1') $$, 'P0002', null,
  'or thanks anyone in it');

-- Retention: a withdrawn kid's own thanks go.
reset role;
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-v1', now() - interval '60 days', now() - interval '31 days');
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a2';
select public.anonymize_expired_profiles();
select is_empty($$ select 1 from public.chef_thanks where from_member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  'a withdrawn kid''s thanks are erased with their other contributions');

select public.delete_account_data('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.meal_logs where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'and deleting the household takes everything with it');

select * from finish();
rollback;
