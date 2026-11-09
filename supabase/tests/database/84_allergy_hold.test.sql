-- Allergy agreements and the allergy hold (#277). Dormant, a parent's agreement works as before and set_member_allergies
-- changes only what changed. Once a new wording is in force: existing allergies keep flagging, nobody adds one until a
-- parent agrees again, removing still works, and an adult who isn't a parent agrees for their own before adding to it.
-- The hold is a log: parents read it, nobody else does, and it goes with the household.
begin;
select plan(47);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role": "service_role"}', true),
         set_config('role', 'service_role', true);
$$;
-- 'ok', or the error's SQLSTATE and hint: the hint is what the app reads.
create function pg_temp.error_of(statement text) returns text language plpgsql as $$
declare
  state text;
  hint text;
begin
  execute statement;
  return 'ok';
exception when others then
  get stacked diagnostics state = returned_sqlstate, hint = pg_exception_hint;
  return state || coalesce(' ' || nullif(hint, ''), '');
end;
$$;
create function pg_temp.allergies(person uuid) returns int language sql as $$
  select count(*)::int from public.member_allergies where member_id = person;
$$;

-- Household A: Ann (owner, parent), Grace (an adult who isn't a parent, signed in) and Ivy (a kid). Household B: Carol.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Ivy', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c');

-- Dormant -------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select throws_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'made-up-v9') $$,
  '22023', null, 'a wording nobody registered isn''t accepted');
select lives_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v1') $$,
  'a registered one is');
select is((select (a.kind, a.member_id is null, a.consent_id = c.id, a.method)::text
           from public.consent_agreements a, public.consents c
           where a.household_id = '00000000-0000-0000-0000-0000000000a0' and c.household_id = a.household_id
             and c.kind = 'allergy_data' and c.revoked_at is null),
  '(allergy_data,t,t,in_app)', 'the agreement is logged in its consent cycle');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk}', '{kiwi}') $$,
  'a parent adds allergies as before');
select set_config('test.milk', (select id::text from public.member_allergies
                                where member_id = '00000000-0000-0000-0000-0000000000a3' and category = 'milk'), true);
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk,eggs}', '{kiwi}') $$,
  'and one more');
select is((select id::text from public.member_allergies
           where member_id = '00000000-0000-0000-0000-0000000000a3' and category = 'milk'),
  current_setting('test.milk'), 'a row that stayed is kept: only what changed is written');
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a3'), 3, 'and the new one is added');

-- A new wording in force: nobody adds until a parent agrees -----------------------------------------------------------
select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version = 'allergy-data-v2';
select ok(not public.household_allergy_agreement_current('00000000-0000-0000-0000-0000000000a0'),
  'an agreement to v1 is outdated once v2 is in force');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(pg_temp.error_of($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3',
                                                                  '{milk,eggs,soy}', '{kiwi}') $$),
  '42501 agreement_outdated', 'nobody adds an allergy until a parent agrees again');
select is(pg_temp.error_of($$ insert into public.member_allergies (household_id, member_id, category) values
                                ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'soy') $$),
  '42501 agreement_outdated', 'not even a row at a time');
select is(pg_temp.error_of($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3',
                                                                  '{milk,eggs}', '{kiwi}') $$),
  'ok', 'saving the same list still works');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk}', '{kiwi}') $$,
  'and so does removing one');
select is(pg_temp.allergies('00000000-0000-0000-0000-0000000000a3'), 2, 'the rest stay, and keep flagging dishes');
select is(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'allergy' ->> 'household_current', 'false',
  'the app hears the agreement is outdated');
select is(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'allergy' ->> 'current', 'allergy-data-v2',
  'and which wording to show');

-- The hold: a log parents read ------------------------------------------------------------------------------------------
select pg_temp.as_service();
select is(public.apply_agreement_holds(), 1, 'the hourly job opens a hold');
select is(public.apply_agreement_holds(), 0, 'once');
select pg_temp.as_admin();
select is((select (held_version, required_version, held_user_id is null, released_at is null)::text
           from public.agreement_holds where household_id = '00000000-0000-0000-0000-0000000000a0'),
  '(allergy-data-v1,allergy-data-v2,t,t)', 'it says what was agreed to and what''s needed now');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'allergy' ->> 'held', 'true',
  'a parent''s app sees the hold');
select is((select count(*)::int from public.agreement_holds), 1, 'a parent reads the household''s holds');
select throws_ok($$ select held_user_id from public.agreement_holds $$, '42501', null, 'but never an account id');
select throws_ok($$ update public.agreement_holds set released_at = now() $$, '42501', null,
  'and nobody ends a hold by hand');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is((select count(*)::int from public.agreement_holds), 0, 'an adult who isn''t a parent doesn''t read holds');
select throws_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v2') $$,
  '42501', null, 'or agree for the household');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is((select count(*)::int from public.agreement_holds), 0, 'another household reads none of it');

-- A parent agrees again --------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v2') $$,
  'a parent agrees to the new wording');
select ok(public.household_allergy_agreement_current('00000000-0000-0000-0000-0000000000a0'),
  'the household is current again');
select is((select released_reason from public.agreement_holds
           where household_id = '00000000-0000-0000-0000-0000000000a0'), 'renewed', 'and the hold ends');
select is((select count(distinct consent_id)::int from public.consent_agreements
           where household_id = '00000000-0000-0000-0000-0000000000a0'), 1,
  'both agreements belong to the one consent: nothing was revoked');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a3', '{milk,soy}', '{kiwi}') $$,
  'adding works again');

-- An adult's own allergies -------------------------------------------------------------------------------------------------
select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version = 'own-allergy-v1';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{milk}', '{}') $$,
  'a parent still adds to another adult''s profile');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a1', '{sesame}', '{}') $$,
  'and to their own: a parent''s agreement covers it');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is(pg_temp.error_of($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2',
                                                                  '{milk,peanuts}', '{}') $$),
  '42501 own_agreement_needed', 'an adult who isn''t a parent agrees for themselves before adding to their own');
select is(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'allergy' ->> 'own_current', 'false',
  'and their app hears it');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{}', '{}') $$,
  'removing their own still works');
select throws_ok($$ select public.agree_to_own_allergies('00000000-0000-0000-0000-0000000000a2', 'made-up-v1') $$,
  '22023', null, 'an unknown wording is refused');
select throws_ok($$ select public.agree_to_own_allergies('00000000-0000-0000-0000-0000000000a3', 'own-allergy-v1') $$,
  '42501', null, 'nobody agrees for someone else');
select lives_ok($$ select public.agree_to_own_allergies('00000000-0000-0000-0000-0000000000a2', 'own-allergy-v1') $$,
  'she agrees for herself');
select lives_ok($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2', '{peanuts}', '{}') $$,
  'and adds her own');
select pg_temp.as_admin();
select is((select (kind, member_id, agreed_by)::text from public.consent_agreements where kind = 'own_allergy_data'),
  '(own_allergy_data,00000000-0000-0000-0000-0000000000a2,d0000000-0000-0000-0000-00000000000d)',
  'her agreement is logged as hers');

-- A sample family ---------------------------------------------------------------------------------------------------------
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000b0', 'sample-family-v1');
select ok(not public.household_allergy_agreement_current('00000000-0000-0000-0000-0000000000b0'),
  'a sample family''s consent is outdated once v2 is in force, once it''s no longer a sample');
select pg_temp.as_admin();
update public.households set settings = settings || '{"sample": true}' where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select ok(public.household_allergy_agreement_current('00000000-0000-0000-0000-0000000000b0'),
  'but counts while the household is still a sample');
select pg_temp.as_admin();
update public.households set settings = settings - 'sample' where id = '00000000-0000-0000-0000-0000000000b0';
select pg_temp.as_service();
select is(public.apply_agreement_holds(), 1, 'so the job holds it');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol turns allergy alerts off
update public.consents set revoked_at = now()
where household_id = '00000000-0000-0000-0000-0000000000b0' and kind = 'allergy_data';
select pg_temp.as_admin();
select is((select released_reason from public.agreement_holds where household_id = '00000000-0000-0000-0000-0000000000b0'),
  'withdrawn', 'turning allergy alerts off ends the hold');

-- Export and erase -----------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'agreement_holds'), 1,
  'the export has the household''s holds');
select ok(not exists (select 1 from jsonb_array_elements(
            public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'agreement_holds') as h (row)
          where row ? 'held_user_id' or row ? 'emailed_at'),
  'without account ids or email bookkeeping');
select pg_temp.as_admin();
select public.erase_household('00000000-0000-0000-0000-0000000000b0');
select is_empty($$ select 1 from public.agreement_holds where household_id = '00000000-0000-0000-0000-0000000000b0' $$,
  'erasing a household erases its holds');

select * from finish();
rollback;
