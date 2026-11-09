-- The new wording in force (#277, PR D: 20261119000000_agreements_in_force.sql). The registry starts as the migration
-- left it. pgTAP can't see the migration's own run of apply_agreement_holds (these fixtures come after it), so this runs
-- the same job on families as they were then: a kid whose consent was given in the app to v1 is held, a household that
-- agreed to allergy-data-v1 can't add allergies until a parent agrees to v2, families already on the current wording are
-- untouched, and the app's renewal request carries what the cron's renewal email does, held or not yet held.
begin;
select plan(25);

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

-- Household A (agreed to allergy-data-v1 in the app): Ann (owner, parent, Apple email, a device); Kit (a kid with an
-- account) and Owen (a kid without one), both consented in the app to parental-invite-v1. Household B, already on the
-- current wording: Carol (parent), Dan (a kid consented to v3 by email plus), allergy agreement to v2.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-ann', 'a0000000-0000-0000-0000-00000000000a',
   '{"sub": "apple-ann", "email": "ann@example.com", "email_verified": true}', 'apple');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'kid', false,
   'd0000000-0000-0000-0000-00000000000d');
insert into public.consents (household_id, member_id, kind, granted_by, granted_at, text_version, method) values
  ('00000000-0000-0000-0000-0000000000a0', null, 'allergy_data', 'a0000000-0000-0000-0000-00000000000a',
   '2026-10-20 12:00+00', 'allergy-data-v1', 'in_app'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'parental',
   'a0000000-0000-0000-0000-00000000000a', '2026-10-21 12:00+00', 'parental-invite-v1', 'in_app'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'parental',
   'a0000000-0000-0000-0000-00000000000a', '2026-10-22 12:00+00', 'parental-invite-v1', 'in_app'),
  ('00000000-0000-0000-0000-0000000000b0', null, 'allergy_data', 'c0000000-0000-0000-0000-00000000000c',
   now(), 'allergy-data-v2', 'in_app'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'parental',
   'c0000000-0000-0000-0000-00000000000c', now(), 'parental-invite-v3', 'email_plus');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'milk'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'peanuts');
insert into public.push_devices (user_id, member_id, household_id, token, environment) values
  ('a0000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0',
   repeat('a1', 32), 'sandbox');

-- What's in force ---------------------------------------------------------------------------------------------------------
select is(array[public.current_agreement_version('allergy_data'), public.current_agreement_version('own_allergy_data'),
                public.current_agreement_version('parental'), public.current_agreement_version('terms'),
                public.current_agreement_version('privacy')],
  array['allergy-data-v2', 'own-allergy-v1', 'parental-invite-v3', 'terms-draft-v1', 'privacy-draft-v1'],
  'the migration put the newest wording of every kind in force');
select ok(not public.agreement_satisfies('allergy-data-v1', 'allergy_data')
          and not public.agreement_satisfies('parental-invite-v1', 'parental')
          and not public.agreement_satisfies('parental-invite-v2', 'parental'),
  'so an agreement to an older wording is outdated');
select is((select count(*)::int from cron.job where jobname = 'apply-agreement-holds'), 1,
  'and the hourly job keeps applying holds after the migration''s own run');

-- Holds: what the migration's run (and every hourly run after it) does ---------------------------------------------------
select pg_temp.as_service();
select is(public.apply_agreement_holds(), 3, 'two kids on v1 and one household on allergy-data-v1 are held');
select is(public.apply_agreement_holds(), 0, 'once');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a2'), null,
  'a kid consented in the app to v1 is signed out');
select is((select (held_user_id, was_linked, held_version, required_version)::text
           from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a2'),
  '(e0000000-0000-0000-0000-00000000000e,t,parental-invite-v1,parental-invite-v3)',
  'their hold keeps the account to link back');
select is((select was_linked from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a3'),
  false, 'a kid who never signed in is held without an account');
select ok(public.has_parental_consent('00000000-0000-0000-0000-0000000000a2'),
  'nothing is withdrawn, so no erase clock starts');
select is((select count(*)::int from public.push_outbox
           where kind = 'agreement_hold' and member_id = '00000000-0000-0000-0000-0000000000a1'), 2,
  'the parent with a device is told about each held kid through the push queue');
select is((select (held_version, required_version)::text from public.agreement_holds
           where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data'
             and released_at is null),
  '(allergy-data-v1,allergy-data-v2)', 'the allergy-data-v1 household is held');
select is((select count(*)::int from public.agreement_holds where household_id = '00000000-0000-0000-0000-0000000000b0'),
  0, 'a family already on the current wording isn''t');
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000b2'),
  'd0000000-0000-0000-0000-00000000000d'::uuid, 'and their kid stays signed in');

-- An allergy-data-v1 household can't add ---------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(pg_temp.error_of($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2',
                                                                  '{milk,peanuts,soy}', '{}') $$),
  '42501 agreement_outdated', 'an allergy-data-v1 household can''t add an allergy');
select is(pg_temp.error_of($$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a2',
                                                                  '{peanuts}', '{}') $$),
  'ok', 'removing one still works');
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a2'),
  1, 'and the rest keep flagging dishes');

-- What the app reads -----------------------------------------------------------------------------------------------------
select is((select jsonb_agg(jsonb_build_object('name', k ->> 'first_name', 'was_linked', k -> 'was_linked')
                            order by k ->> 'first_name')
           from jsonb_array_elements(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'kids_held') k),
  '[{"name": "Kit", "was_linked": true}, {"name": "Owen", "was_linked": false}]'::jsonb,
  'parents see each held kid, and whether they had signed in on their own device');

-- The app's renewal request ------------------------------------------------------------------------------------------------
select set_config('test.kit', public.request_parental_consent('00000000-0000-0000-0000-0000000000a2', null,
                                                              'parental-invite-v3')::text, true);
select is(current_setting('test.kit')::jsonb - 'request_id' - 'send_id',
  jsonb_build_object('outcome', 'send', 'email', 'ann@example.com', 'email_source', 'account', 'first_name', 'Kit',
                     'reason', 'renewal', 'text_version', 'parental-invite-v3',
                     'summary', (select summary from public.agreement_versions where version = 'parental-invite-v3'),
                     'agreed_before', '2026-10-21T12:00:00+00:00', 'held', true),
  'a renewal asked for in the app carries what changed in the wording sent, when a parent agreed, and that Kit is held');
select pg_temp.as_admin();
select is((select hold_id is not null from public.parental_consent_requests
           where id = (current_setting('test.kit')::jsonb ->> 'request_id')::uuid),
  true, 'and the request belongs to the hold');
insert into public.agreement_versions (version, kind, ordinal, summary)
values ('parental-invite-v4', 'parental', 4, 'A later wording, for this test.');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a3', null, 'parental-invite-v4')
            ->> 'summary',
  'A later wording, for this test.', 'a function deployed ahead gets its own wording''s summary');
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000b2') $$, '42501', null,
  'another household''s kid can''t be asked about');
select pg_temp.as_admin();
delete from public.parental_consent_sends;
delete from public.parental_consent_requests;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a3', null, 'not-a-wording') ->> 'summary',
  (select summary from public.agreement_versions where version = 'parental-invite-v3'),
  'an unknown wording (or an older function that sends none) gets the summary of the one in force');
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a3') ->> 'outcome', 'rate_limited',
  'the two-argument call still works');

-- A newer wording comes into force and the hourly job hasn't run yet: Dan's family renews before he's held.
select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version = 'parental-invite-v4';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol, no Apple email
select set_config('test.dan', public.request_parental_consent('00000000-0000-0000-0000-0000000000b2',
                                                              'carol@example.com', 'parental-invite-v4')::text, true);
select is((current_setting('test.dan')::jsonb ->> 'held')::boolean, false,
  'a renewal asked for before the hold opens says the kid isn''t held yet');
select pg_temp.as_admin();
select ok((select hold_id is null and reason = 'renewal' from public.parental_consent_requests
           where id = (current_setting('test.dan')::jsonb ->> 'request_id')::uuid),
  'and the request is a renewal belonging to no hold');

select * from finish();
rollback;
