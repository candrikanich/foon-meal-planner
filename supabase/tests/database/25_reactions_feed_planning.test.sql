-- Reactions feed planning (#42, part 3): history from logs, current verdicts, likes, and the two-dislike rule.
begin;
select plan(19);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Pops', 'member', false, 'adult', null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili'),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0', 'Liver'),
  ('00000000-0000-0000-0000-0000000002a3', '00000000-0000-0000-0000-0000000000a0', 'Kale');
insert into public.plans (id, household_id, week_start, approved_at) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 6, now()),
  ('00000000-0000-0000-0000-0000000003a2', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 200, now());
insert into public.plan_nights (id, household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 6, '00000000-0000-0000-0000-0000000002a1'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 4, '00000000-0000-0000-0000-0000000002a1'),
  ('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2, '00000000-0000-0000-0000-0000000002a2'),
  ('00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 1, '00000000-0000-0000-0000-0000000002a3'),
  ('00000000-0000-0000-0000-0000000004a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a2',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 200, '00000000-0000-0000-0000-0000000002a1');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
-- Chili twice: Alice loved it, then tired of it; Nora said good. Liver: Nora and Owen, not for them.
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a1', 'favorite');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', 'good');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a1', 'tired_of_it');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a2', 'not_for_me');

select results_eq(
  $$ select m.first_name, v.reaction::text from public.meal_verdicts v join public.members m on m.id = v.member_id
     where v.meal_id = '00000000-0000-0000-0000-0000000002a1' order by m.first_name $$,
  $$ values ('Alice', 'tired_of_it'), ('Nora', 'good') $$, 'each person''s latest word on the chili');
select is((select likes from public.meal_likes where meal_id = '00000000-0000-0000-0000-0000000002a1'), 2,
  'the chili''s favorite and good count as likes, ever');
select results_eq(
  $$ select times_made, last_made - public.household_today(household_id) from public.meal_history
     where meal_id = '00000000-0000-0000-0000-0000000002a1' $$,
  $$ values (3, -4) $$, 'history counts the two logged dinners, and one from long ago that was never logged');

select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'active',
  'one dislike doesn''t retire the liver');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a3', 'not_for_me');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'retired',
  'two do');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a1'), 'active',
  'and nothing else is touched');
select lives_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a3',
  '00000000-0000-0000-0000-0000000000a3', 'good') $$, 'Owen changes his mind about the liver');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'retired',
  'but a retired dish stays retired');

-- A planner may bring it back; a member may not. The next Not for me retires it again.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.meals set status = 'active' where id = '00000000-0000-0000-0000-0000000002a2';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'retired',
  'Bob, a member, can''t bring it back');
update public.meals set status = 'active' where id = '00000000-0000-0000-0000-0000000002a2';
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'active',
  'Alice, a planner, brings the liver back');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a3', '00000000-0000-0000-0000-0000000000a3', 'not_for_me');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a2'), 'retired',
  'Owen says not for me again, and it''s retired again');

-- A removed member's old dislike doesn't count toward retiring.
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a4', 'not_for_me');
reset role;
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a4';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a4', '00000000-0000-0000-0000-0000000000a2', 'not_for_me');
select is((select status::text from public.meals where id = '00000000-0000-0000-0000-0000000002a3'), 'active',
  'Pops left the family, so the kale has one dislike, not two');
select is_empty($$ select 1 from public.meal_verdicts where member_id = '00000000-0000-0000-0000-0000000000a4' $$,
  'and his verdicts aren''t shown');

-- Ratings reach back a week, no further.
select throws_ok($$ select public.react_to_dinner('00000000-0000-0000-0000-0000000004a5',
  '00000000-0000-0000-0000-0000000000a2', 'not_for_me') $$, '22023', null,
  'a dinner from months ago can''t be rated now');

-- History still counts approved nights nobody logged (before logs existed).
reset role;
delete from public.reactions where meal_log_id in (select id from public.meal_logs
  where night_id = '00000000-0000-0000-0000-0000000004a2');
delete from public.meal_logs where night_id = '00000000-0000-0000-0000-0000000004a2';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select times_made from public.meal_history where meal_id = '00000000-0000-0000-0000-0000000002a1'), 3,
  'an approved night with no log still counts, once');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.meal_verdicts $$, 'another household sees no verdicts');
select is_empty($$ select 1 from public.meal_likes $$, 'or likes');
select is_empty($$ select 1 from public.meal_history $$, 'or history');

select ok(not has_table_privilege('authenticated', 'public.meal_verdicts', 'insert')
  and not has_table_privilege('authenticated', 'public.meal_likes', 'delete')
  and has_table_privilege('authenticated', 'public.meal_verdicts', 'select'), 'the views are read-only');

select * from finish();
rollback;
