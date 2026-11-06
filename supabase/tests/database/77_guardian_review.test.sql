-- Every parent can review a kid's data (#279): a parent who isn't a planner reads the household's kids' reminder log and
-- hidden comments, and exports. Other adults' log and hidden comments stay with planners, and an adult who isn't a
-- parent, a kid, or another household's parent gets nothing new.
begin;
select plan(22);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Ann (owner, planner, parent), Ben (a parent who isn't a planner), Grace (a planner who isn't a parent),
-- Bob (an adult who's neither), Kim (a kid with her own account) and Owen (a kid without one). Household B: Carol (owner,
-- parent) and Dan (a kid).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'bob@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'adult', false,
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'kid', false, null);

-- A reminder for everyone in A but Ann, and one for Dan in B.
insert into public.notification_log (id, household_id, member_id, type, scheduled_for)
select gen_random_uuid(), household_id, id, 'after_dinner', now() from public.members
where id in ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3',
             '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a5',
             '00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000b2');

-- A dinner two days ago that Bob, Kim and Owen (through Ann's phone) commented on, and Ann hid all three.
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2);
insert into public.plan_nights (id, household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2, '00000000-0000-0000-0000-0000000002a1');

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', 'good');
update public.reactions set comment = 'Bob secret' where member_id = '00000000-0000-0000-0000-0000000000a4';
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a5', 'good');
update public.reactions set comment = 'Kim words' where member_id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a6', 'good');
update public.reactions set comment = 'Owen words' where member_id = '00000000-0000-0000-0000-0000000000a6';
select public.set_comment_hidden(id, true) from public.reactions where household_id = '00000000-0000-0000-0000-0000000000a0';

-- The reminder log -----------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select is((select string_agg(right(member_id::text, 2), ',' order by member_id) from public.notification_log),
  'a2,a5,a6', 'a parent who isn''t a planner reads their own log and the kids'', not other adults''');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Bob
select is((select string_agg(right(member_id::text, 2), ',' order by member_id) from public.notification_log),
  'a4', 'an adult who isn''t a parent still reads only their own');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is((select string_agg(right(member_id::text, 2), ',' order by member_id) from public.notification_log),
  'a2,a3,a4,a5,a6', 'a planner still reads the whole household''s');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Kim
select is((select string_agg(right(member_id::text, 2), ',' order by member_id) from public.notification_log),
  'a5', 'a kid reads only her own');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is((select string_agg(right(member_id::text, 2), ',' order by member_id) from public.notification_log),
  'b2', 'another household''s parent reads only their own kid''s');

-- Hidden comments ------------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select is((select string_agg(comment, ',' order by comment) from public.hidden_comments), 'Kim words,Owen words',
  'a parent who isn''t a planner reads the kids'' hidden comments, not an adult''s');
select is((select string_agg(comment, ',' order by comment) from public.meal_comments where hidden),
  'Kim words,Owen words', 'and sees them on the dish, marked hidden');
select throws_ok(format($$ select public.set_comment_hidden(%L, false) $$,
                        (select id from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a5')),
  '42501', null, 'but can''t show one again: that''s still a planner''s');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Bob
select is_empty($$ select 1 from public.hidden_comments $$, 'an adult who isn''t a parent reads no hidden comments');
select is_empty($$ select 1 from public.meal_comments where hidden $$, 'and none reach the dish');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Kim
select is_empty($$ select 1 from public.hidden_comments $$, 'a kid can''t read hidden comments, her own included');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is_empty($$ select 1 from public.hidden_comments $$, 'another household''s parent reads none of them');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is((select count(*)::int from public.hidden_comments), 3, 'a planner still reads all of them');

-- Export ---------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select lives_ok($$ select public.export_household('00000000-0000-0000-0000-0000000000a0') $$,
  'a parent who isn''t a planner exports the household');
select is((select string_agg(right(l ->> 'member_id', 2), ',' order by l ->> 'member_id')
           from jsonb_array_elements(public.export_household('00000000-0000-0000-0000-0000000000a0')
                                     -> 'notification_log') l),
  'a2,a5,a6', 'with their own reminder log and the kids''');
select is((select string_agg(c ->> 'comment', ',' order by c ->> 'comment')
           from jsonb_array_elements(public.export_household('00000000-0000-0000-0000-0000000000a0')
                                     -> 'hidden_comments') c),
  'Kim words,Owen words', 'and the kids'' hidden comments');
select ok(position('Bob secret' in public.export_household('00000000-0000-0000-0000-0000000000a0')::text) = 0,
  'but not an adult''s hidden comment, anywhere in the file');

select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Bob
select throws_ok($$ select public.export_household('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'an adult who isn''t a parent or a planner can''t export');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Kim
select throws_ok($$ select public.export_household('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'a kid can''t export');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select throws_ok($$ select public.export_household('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'another household''s parent can''t export it');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'notification_log'), 5,
  'a planner''s export still has the whole household''s log');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'hidden_comments'), 3,
  'and every hidden comment');

select * from finish();
rollback;
