-- Hidden comments are really hidden (#149): selecting reactions.comment gets a non-planner no hidden text, whichever way
-- they ask, and everything that clears a comment clears the hidden text too.
begin;
select plan(31);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_admin() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'kira@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
-- Alice plans. Bob's a member. Kira's a kid with her own phone. Owen's a kid with no account. Carol runs another household.
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Kira', 'member', false, 'kid',
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Chili');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2);
insert into public.plan_nights (id, household_id, plan_id, date, meal_id) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') - 2, '00000000-0000-0000-0000-0000000002a1');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', 'good');
update public.reactions set comment = 'Too spicy for me' where member_id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a5', 'good');
update public.reactions set comment = 'Yum' where member_id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a7', 'good');
update public.reactions set comment = 'Owen says more please' where member_id = '00000000-0000-0000-0000-0000000000a7';

select pg_temp.as_admin();
create temp table bobs on commit drop as
  select id from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a2';
grant select on bobs to authenticated;

-- Before it's hidden: the family reads it, and another household doesn't. A kid's comment is the same.
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is((select comment from public.reactions where id = (select id from bobs)), 'Too spicy for me',
  'a comment the family can see is on the reaction');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select comment from public.meal_comments where member_id = '00000000-0000-0000-0000-0000000000a5'), 'Yum',
  'a kid''s comment reaches their family');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.reactions where comment = 'Yum'), 0,
  'not another household, through the table');
select is((select count(*)::int from public.meal_comments), 0, 'or the view');

-- Hide it.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(format($$ select public.set_comment_hidden(%L, true) $$, (select id from bobs)), 'a planner hides it');
select lives_ok(format($$ select public.set_comment_hidden(%L, true) $$, (select id from bobs)),
  'hiding it twice changes nothing');
select is((select comment from public.hidden_comments where reaction_id = (select id from bobs)), 'Too spicy for me',
  'twice keeps the text');

-- The point of the ticket: nobody but a planner gets the text, however they select it.
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is((select comment from public.reactions where id = (select id from bobs)), null,
  'a non-planner selecting comment from reactions gets no hidden text');
select is((select count(*)::int from public.hidden_comments), 0, 'and reads nothing from the hidden table');
select is((select count(*)::int from public.meal_comments where id = (select id from bobs)), 0, 'or the view');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select comment from public.reactions where id = (select id from bobs)), null, 'nor does the person who wrote it');
select is((select to_jsonb(r) ? 'comment_hidden_at' from public.reactions r where id = (select id from bobs)), false,
  'and the reaction doesn''t say it was hidden');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.hidden_comments), 0, 'another household''s planner reads none of it');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select comment from public.meal_comments where id = (select id from bobs)), 'Too spicy for me',
  'a planner still reads it through the view');
select is((select hidden from public.meal_comments where id = (select id from bobs)), true, 'marked hidden');
select is((select comment from public.reactions where id = (select id from bobs)), null,
  'and even for a planner the reaction itself holds no text');

-- Nobody writes the table, not even a planner.
select throws_ok(format($$ insert into public.hidden_comments (reaction_id, household_id, comment)
  values (%L, '00000000-0000-0000-0000-0000000000a0', 'Nope') $$, (select id from bobs)), '42501', null, 'no one adds to it');
select throws_ok($$ update public.hidden_comments set comment = 'Nope' $$, '42501', null, 'or changes it');
select throws_ok($$ delete from public.hidden_comments $$, '42501', null, 'or removes from it');

-- Changing a hidden comment keeps it hidden: the new words don't land where the family can read them.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
update public.reactions set comment = 'Still too spicy' where id = (select id from bobs);
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is((select comment from public.reactions where id = (select id from bobs)), null,
  'new words on a hidden comment aren''t on the reaction');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select comment from public.meal_comments where id = (select id from bobs)), 'Still too spicy',
  'planners read the new words, still hidden');

-- Changing the rating leaves the hidden text alone.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.react_to_dinner('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a2', 'favorite');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select comment from public.meal_comments where id = (select id from bobs)), 'Still too spicy',
  'changing the rating doesn''t touch the words');

-- The length limit holds on both sides of hiding.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(format($$ update public.reactions set comment = repeat('x', 141) where id = %L $$, (select id from bobs)),
  '23514', null, 'a hidden comment can''t go past 140 characters');
update public.reactions set comment = 'Bob wrote this' where member_id = '00000000-0000-0000-0000-0000000000a5';
select is((select comment from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a5'), 'Yum',
  'nobody writes someone else''s comment');

-- Bringing it back.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok(format($$ select public.set_comment_hidden(%L, false) $$, (select id from bobs)), 'a planner brings it back');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is((select comment from public.reactions where id = (select id from bobs)), 'Still too spicy',
  'and the words are back on the reaction');

-- Someone who eats separately isn't asked about the food, so they don't comment on it either.
select pg_temp.as_admin();
update public.members set eats_separately = true where id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select throws_ok($$ update public.reactions set comment = 'Mine' where member_id = '00000000-0000-0000-0000-0000000000a5' $$,
  'FD004', null, 'someone who eats separately can''t comment');
select pg_temp.as_admin();
update public.members set eats_separately = false where id = '00000000-0000-0000-0000-0000000000a5';

-- Retention: everything that clears a comment clears the hidden text, through the same update as ever.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_comment_hidden(id, true) from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a7';
select pg_temp.as_admin();
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a7';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a7';
select public.anonymize_expired_profiles();
select is((select count(*)::int from public.hidden_comments h join public.reactions r on r.id = h.reaction_id
           where r.member_id = '00000000-0000-0000-0000-0000000000a7'), 0, 'a removed kid''s hidden comment goes with their name');

-- A withdrawn kid's own rating is erased, and its hidden text with it.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_comment_hidden(id, true) from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_admin();
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-v1', now() - interval '60 days', now() - interval '31 days');
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a5';
select public.anonymize_expired_profiles();
select is((select count(*)::int from public.reactions where member_id = '00000000-0000-0000-0000-0000000000a5'), 0,
  'a withdrawn kid''s own rating is erased');
select is((select count(*)::int from public.hidden_comments h where h.comment = 'Yum'), 0, 'and its hidden text');

-- Deleting the household takes whatever's left.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_comment_hidden((select id from bobs), true);
select pg_temp.as_admin();
select public.erase_household('00000000-0000-0000-0000-0000000000a0');
select is((select count(*)::int from public.hidden_comments where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'erasing the household erases hidden comments');

select * from finish();
rollback;
