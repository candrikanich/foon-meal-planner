-- Onboarding (#17): the allergy consent sentence, a member's allergies saved in one go, and settings merged.
begin;
select plan(19);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"week_start": 7, "future_key": true}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
insert into public.members (id, household_id, first_name, role, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true,
   'c0000000-0000-0000-0000-00000000000c');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

-- Allergies need the household's consent first ----------------------------------------------
select throws_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk}', '{}') $$,
  '42501', null, 'no allergies before the household agrees to keep them');
select lives_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  'a parent agrees with the one plain sentence');
select lives_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  'agreeing again is fine');
select is((select count(*)::int from public.consents where kind = 'allergy_data' and revoked_at is null), 1,
  'one active consent');

select lives_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk,tree_nuts}', '{" kiwi ",""}') $$,
  'a parent sets a member''s allergies');
select results_eq(
  $$ select category::text, custom_text from public.member_allergies
     where member_id = '00000000-0000-0000-0000-0000000000a3' order by category::text $$,
  $$ values ('custom', 'kiwi'), ('milk', null::text), ('tree_nuts', null) $$,
  'standard allergens and trimmed Other text; blanks dropped');
select lives_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{eggs}', '{}') $$,
  'and changes them');
select results_eq(
  $$ select category::text from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a3' $$,
  $$ values ('eggs') $$, 'the old ones are replaced');
select lives_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{}', '{}') $$, 'or clears them');

-- Settings merge -------------------------------------------------------------------------------
select lives_ok(
  $$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
       '{"dinner_time": "17:30", "onboarded": true}') $$,
  'a planner updates settings');
select is((select settings from public.households where id = '00000000-0000-0000-0000-0000000000a0'),
  '{"week_start": 7, "future_key": true, "dinner_time": "17:30", "onboarded": true}'::jsonb,
  'keys merge; nothing else is lost');
select throws_ok(
  $$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '["not", "an", "object"]') $$,
  '22023', null, 'settings must be an object');

-- Who can ------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk}', '{}') $$,
  '42501', null, 'only parents set allergies');
select throws_ok(
  $$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0', '{"onboarded": false}') $$,
  '42501', null, 'only planners change settings');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk}', '{}') $$,
  'P0002', null, 'another household''s member is not found');
select throws_ok(
  $$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  '42501', null, 'another household cannot consent');

-- A new household starts with onboarding's flags, in the same transaction ----------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select is((public.create_household('Daltons', null, 'Dave', '{"onboarded": false, "sample_pending": true}')).settings,
  '{"onboarded": false, "sample_pending": true}'::jsonb, 'the household is created with its starting settings');
select throws_ok($$ select public.create_household('Daltons 2', null, 'Dave', '[]') $$,
  '22023', null, 'starting settings must be an object');
select is((select count(*)::int from public.households), 1, 'and a refused create leaves nothing behind');

select * from finish();
rollback;
