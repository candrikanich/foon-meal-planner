-- The day-of check-in (#41): for yourself (or a profile nobody has claimed), for tonight only.
begin;
select plan(22);

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
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0')),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1);
insert into public.night_attendance (household_id, plan_night_id, member_id, expected) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1', false),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true);

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false) $$,
  'Bob says he won''t be home tonight, though only planners can edit attendance');
select results_eq(
  $$ select expected, checked_in_at is not null from public.night_attendance
     where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values (false, true) $$, 'so he''s out, and the row says he said so');
select lives_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true) $$,
  'he can change his mind');
select results_eq(
  $$ select expected, checked_in_at is not null from public.night_attendance
     where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values (true, true) $$, 'home again, and still answered');
select lives_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3', false) $$,
  'passing the phone, he can say for Nora, who has no account (and no row yet)');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1', false) $$,
  '42501', null, 'not for someone with their own account');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a2', false) $$,
  '22023', null, 'and only for tonight');
select throws_ok($$ update public.night_attendance set checked_in_at = now()
                    where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'nobody writes the column directly');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false) $$,
  '42501', null, 'a planner doesn''t answer for someone with their own account');
select lives_ok($$ update public.night_attendance set expected = false
                   where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  'but can mark them out');
select results_eq(
  $$ select checked_in_at is null from public.night_attendance
     where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values (true) $$, 'and then the row no longer says Bob said so, so it isn''t news');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true) $$,
  'FD016', null, 'and "home" doesn''t overrule the planner');
select lives_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false) $$,
  'saying "not home" first is fine');
select results_eq(
  $$ select expected, checked_in_at is null from public.night_attendance
     where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values (false, true) $$, 'but stamps nothing, since it''s still the planner''s no');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true) $$,
  'FD016', null, 'so it can''t be a way round them');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3', false) $$,
  'P0002', null, 'another household can''t find the night');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000c1', false) $$,
  'P0002', null, 'or put its own people on it');
select is_empty($$ select 1 from public.night_attendance where plan_night_id = '00000000-0000-0000-0000-0000000004a1' $$,
  'or read anyone''s answer');

reset role;
select set_config('request.jwt.claims', '', true);
insert into public.meal_logs (id, household_id, night_id, cooked_by_member_id)
values ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0',
        '00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2');
update public.night_attendance set expected = true
where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2';

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', false) $$,
  'a late "not home" lands on a dinner already logged');
select is((select cooked_by_member_id from public.meal_logs where id = '00000000-0000-0000-0000-0000000005a1'), null::uuid,
  'and they didn''t cook a dinner they weren''t home for');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.night_attendance set expected = false
where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2';
select results_eq(
  $$ select expected, checked_in_at is null from public.night_attendance
     where plan_night_id = '00000000-0000-0000-0000-0000000004a1' and member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  $$ values (false, true) $$, 'a planner marking out someone who already said no makes it the planner''s no');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', true) $$,
  'FD016', null, 'so they can''t take that one back either');

select * from finish();
rollback;
