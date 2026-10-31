-- Family tab (#47): no schema of its own. This proves what the screens offer is what the server allows, for the owner, a
-- parent who isn't the owner, a planner who isn't a parent, a kid with their own account, and another household.
begin;
select plan(54);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true);
$$;

create function pg_temp.away_days(person uuid) returns jsonb language sql as $$
  select attendance_defaults -> 'usually_away' from public.members where id = person;
$$;

create function pg_temp.settings() returns jsonb language sql as $$
  select settings from public.households where id = '00000000-0000-0000-0000-0000000000a0';
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'owner@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'parent@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'planner@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kid@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'other@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner, settings) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a',
   '{"dinner_time": "18:00", "week_start": 7, "onboarded": true, "time_zone": "America/Chicago",
     "missing_equipment": ["grill"]}'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c', '{}');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c');

-- Usual schedules: everyone their own, parents anyone's ---------------------------------------------------------------
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select lives_ok($$ update public.members set attendance_defaults = '{"usually_away": [1]}'
                   where id = '00000000-0000-0000-0000-0000000000a4' $$, 'a kid changes their own schedule');
select is(pg_temp.away_days('00000000-0000-0000-0000-0000000000a4'), '[1]'::jsonb, 'and it saves');
select throws_ok($$ update public.members set status = 'away' where id = '00000000-0000-0000-0000-0000000000a4' $$,
  '42501', null, 'but not their own status, so the editor doesn''t offer it');
update public.members set attendance_defaults = '{"usually_away": [2]}' where id = '00000000-0000-0000-0000-0000000000a5';
select is(pg_temp.away_days('00000000-0000-0000-0000-0000000000a5'), null, 'nor another kid''s schedule');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ update public.members set attendance_defaults = '{"usually_away": [3]}'
                   where id = '00000000-0000-0000-0000-0000000000a3' $$, 'a planner changes their own schedule');
select throws_ok($$ update public.members set attendance_defaults = '{"usually_away": [2]}'
                    where id = '00000000-0000-0000-0000-0000000000a5' $$,
  '42501', null, 'planning rights don''t reach someone else''s schedule');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ update public.members set attendance_defaults = '{"usually_away": [4]}'
                   where id = '00000000-0000-0000-0000-0000000000a4' $$, 'a parent overrides a kid''s schedule');
select is(pg_temp.away_days('00000000-0000-0000-0000-0000000000a4'), '[4]'::jsonb, 'and it saves');
select lives_ok($$ update public.members set attendance_defaults = '{"usually_away": [5]}'
                   where id = '00000000-0000-0000-0000-0000000000a1' $$, 'and the owner''s');
select throws_ok($$ update public.members set status = 'away' where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '42501', null, 'but only the owner changes the owner''s status');
select lives_ok($$ update public.members set status = 'away', away_until = '2026-12-20'
                   where id = '00000000-0000-0000-0000-0000000000a5' $$, 'a parent sends someone away, with a return date');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
update public.members set attendance_defaults = '{"usually_away": [6]}' where id = '00000000-0000-0000-0000-0000000000a4';
select pg_temp.as_admin();
select is(pg_temp.away_days('00000000-0000-0000-0000-0000000000a4'), '[4]'::jsonb, 'another household changes nothing');

-- Rhythm and planning mix: planners, and only the keys sent ------------------------------------------------------------
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"notification_preset": "light", "new_dishes_per_week": 2}') $$, 'a planner who isn''t a parent saves the rhythm');
select is(pg_temp.settings() ->> 'notification_preset', 'light', 'the preset saved');
select is(pg_temp.settings() ->> 'dinner_time', '18:00', 'a key not sent stays what it was');
select is(pg_temp.settings() -> 'missing_equipment', '["grill"]'::jsonb, 'the kitchen''s too');
select is(pg_temp.settings() ->> 'time_zone', 'America/Chicago', 'and the time zone');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"dinner_time": "17:30"}') $$, 'the owner saves too');
select is(pg_temp.settings() ->> 'notification_preset', 'light', 'another planner''s preset survives their save');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"dinner_time": "19:00"}') $$, '42501', null, 'a parent who isn''t a planner can''t, so Family doesn''t offer it');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"dinner_time": "19:00"}') $$, '42501', null, 'nor a kid');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.update_household_settings('00000000-0000-0000-0000-0000000000a0',
  '{"dinner_time": "19:00"}') $$, '42501', null, 'nor another household');

-- Allergies: parents edit, everyone sees, and consent comes first -----------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['milk']::public.allergen[], '{}') $$,
  '42501', null, 'a household that said no to allergies has no consent: the sentence comes first');
select lives_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  'a parent agrees');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['milk']::public.allergen[], array['kiwi']) $$,
  'then a parent who isn''t the owner adds them');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a4'), 2,
  'a kid sees them');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  '42501', null, 'but can''t change their own');
select throws_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  '42501', null, 'or agree');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  '42501', null, 'planning rights don''t include allergies');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  'the owner takes them all away');
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a4'), 0,
  'and they''re gone');

-- Another household reaches none of it ---------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['eggs']::public.allergen[], '{}');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  'P0002', null, 'another household can''t even find the member to change their allergies');
select throws_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  '42501', null, 'or agree for this household');
select is((select count(*)::int from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'and can''t read its allergies');
select pg_temp.as_admin();
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a4'), 1,
  'which are still there');

-- Who agreed: every parent's agreement to each wording is on the record, without a second active consent -----------------
select has_table('public', 'consent_agreements', 'agreements have their own record');
select is((select count(*)::int from public.consent_agreements where household_id = '00000000-0000-0000-0000-0000000000a0'
             and agreed_by = 'b0000000-0000-0000-0000-00000000000b' and text_version = 'allergy-data-v1'), 1,
  'the first parent''s agreement is recorded');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1');
select is((select count(*)::int from public.consent_agreements where household_id = '00000000-0000-0000-0000-0000000000a0'), 2,
  'so is a second parent''s, to the same wording');
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1');
select is((select count(*)::int from public.consent_agreements where household_id = '00000000-0000-0000-0000-0000000000a0'), 2,
  'agreeing again to the same wording adds nothing');
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v2');
select is((select count(*)::int from public.consent_agreements where household_id = '00000000-0000-0000-0000-0000000000a0'
             and text_version = 'allergy-data-v2'), 1, 'a new wording is recorded');
select is((select count(*)::int from public.consents where household_id = '00000000-0000-0000-0000-0000000000a0'
             and kind = 'allergy_data' and revoked_at is null), 1, 'and there''s still one active consent');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((select count(*)::int from public.consent_agreements), 3, 'everyone in the family can read who agreed');
select throws_ok($$ insert into public.consent_agreements (household_id, text_version)
                    values ('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  '42501', null, 'a kid can''t add an agreement');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ insert into public.consent_agreements (household_id, agreed_by, text_version)
                    values ('00000000-0000-0000-0000-0000000000a0', 'a0000000-0000-0000-0000-00000000000a', 'other') $$,
  '42501', null, 'a parent can''t agree in someone else''s name');
select throws_ok($$ delete from public.consent_agreements $$, '42501', null, 'and the record can''t be deleted');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.consent_agreements where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'another household can''t read it');

-- A sample family's consent says nobody read the sentence. A parent who then does is on the record.
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000b0', 'sample-family-v1');
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000b0', 'allergy-data-v1');
select is((select array_agg(text_version order by text_version) from public.consent_agreements
           where household_id = '00000000-0000-0000-0000-0000000000b0'),
  array['allergy-data-v1', 'sample-family-v1'], 'a parent agreeing in a sample family is recorded beside it');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from jsonb_array_elements(
             public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'consent_agreements')), 3,
  'the export includes it');
select ok(not exists (select 1 from jsonb_array_elements(
            public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'consent_agreements') as a (row)
          where row ? 'agreed_by'), 'without account ids, like consents');

-- Clearing never needs consent: "parents can delete them anytime" ----------------------------------------------------
select pg_temp.as_admin();
update public.consents set revoked_at = now()
where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data';
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  'with consent revoked, a parent can still clear');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['custom']::public.allergen[], array['  ']) $$,
  'a list with nothing real in it counts as clearing');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['milk']::public.allergen[], '{}') $$,
  '42501', null, 'but adding still needs consent');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', array['kiwi']) $$,
  '42501', null, 'Other too');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', '{}', '{}') $$,
  '42501', null, 'and clearing is still a parent''s');

select pg_temp.as_admin();
select * from finish();
rollback;
