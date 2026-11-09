-- The new wording in force (#277, PR D: 20261119000000_agreements_in_force.sql). The registry starts as the migration
-- left it. pgTAP can't see the migration's own run of apply_agreement_holds (these fixtures come after it), so this runs
-- the same job on families as they were then: a kid whose consent was given in the app to v1 is held, a household that
-- agreed to allergy-data-v1 can't add allergies until a parent agrees to v2, families already on the current wording are
-- untouched, and the app's renewal request carries what the cron's renewal email does, held or not yet held.
begin;
select plan(37);

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
-- The registry's "what changed" for these versions, joined as the emails join them.
create function pg_temp.changed(variadic versions text[]) returns text language sql as $$
  select string_agg(v.summary, ' ' order by v.ordinal) from public.agreement_versions v where v.version = any(versions);
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
-- current wording: Carol (parent), Dan (a kid consented to v3 by email plus) and Eli (a kid without an account, also
-- v3), allergy agreement to v2. Household C:
-- Cleo (parent, Apple email) and Pia (a kid without an account), consented in the app to parental-invite-v2.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dan@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'cleo@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-ann', 'a0000000-0000-0000-0000-00000000000a',
   '{"sub": "apple-ann", "email": "ann@example.com", "email_verified": true}', 'apple'),
  ('apple-cleo', 'f0000000-0000-0000-0000-00000000000f',
   '{"sub": "apple-cleo", "email": "cleo@example.com", "email_verified": true}', 'apple');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000c0', 'Cruzes', 'f0000000-0000-0000-0000-00000000000f');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'kid', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000b0', 'Eli', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c0', 'Cleo', 'planner', 'adult', true,
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c0', 'Pia', 'member', 'kid', false, null);
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
   'c0000000-0000-0000-0000-00000000000c', now(), 'parental-invite-v3', 'email_plus'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b3', 'parental',
   'c0000000-0000-0000-0000-00000000000c', now(), 'parental-invite-v3', 'email_plus'),
  ('00000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000c2', 'parental',
   'f0000000-0000-0000-0000-00000000000f', '2026-10-23 12:00+00', 'parental-invite-v2', 'in_app');
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
select is(public.apply_agreement_holds(), 4,
  'two kids on v1, one on v2 and one household on allergy-data-v1 are held');
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
                     'summary', pg_temp.changed('parental-invite-v2', 'parental-invite-v3'),
                     'agreed_before', '2026-10-21T12:00:00+00:00', 'held', true, 'was_linked', true),
  'a renewal asked for in the app carries what changed since v1 (v2, then v3), when a parent agreed, and that Kit '
  || 'is held and had signed in');
select pg_temp.as_admin();
select is((select hold_id is not null from public.parental_consent_requests
           where id = (current_setting('test.kit')::jsonb ->> 'request_id')::uuid),
  true, 'and the request belongs to the hold');

-- The /consent page reads the same from the link.
select pg_temp.as_service();
select public.parental_consent_mark_sent((current_setting('test.kit')::jsonb ->> 'request_id')::uuid,
                                         (current_setting('test.kit')::jsonb ->> 'send_id')::bigint,
                                         'hash-kit', 'parental-invite-v3');
select is(public.parental_consent_lookup('hash-kit') ->> 'summary',
  pg_temp.changed('parental-invite-v2', 'parental-invite-v3'), 'Kit''s link''s page says what changed in v2, then v3');
select is((public.parental_consent_lookup('hash-kit') -> 'was_linked')::boolean, true,
  'and that Kit had signed in');

select pg_temp.as_admin();
insert into public.agreement_versions (version, kind, ordinal, summary)
values ('parental-invite-v4', 'parental', 4, 'A later wording, for this test.');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a3', null, 'parental-invite-v4')
            ->> 'summary',
  pg_temp.changed('parental-invite-v2', 'parental-invite-v3', 'parental-invite-v4'),
  'a function deployed ahead gets what changed up to its own wording');
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000b2') $$, '42501', null,
  'another household''s kid can''t be asked about');
select pg_temp.as_admin();
delete from public.parental_consent_sends;
delete from public.parental_consent_requests;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select set_config('test.owen', public.request_parental_consent('00000000-0000-0000-0000-0000000000a3', null,
                                                               'not-a-wording')::text, true);
select is(current_setting('test.owen')::jsonb ->> 'summary',
  pg_temp.changed('parental-invite-v2', 'parental-invite-v3'),
  'an unknown wording (or an older function that sends none) gets what changed up to the one in force');
select is((current_setting('test.owen')::jsonb -> 'was_linked')::boolean, false,
  'and Owen, who never signed in, isn''t said to be signed out');
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a3') ->> 'outcome', 'rate_limited',
  'the two-argument call still works');
select pg_temp.as_service();
select public.parental_consent_mark_sent((current_setting('test.owen')::jsonb ->> 'request_id')::uuid,
                                         (current_setting('test.owen')::jsonb ->> 'send_id')::bigint,
                                         'hash-owen', 'parental-invite-v3');
select is((public.parental_consent_lookup('hash-owen') -> 'was_linked')::boolean, false,
  'Owen''s link''s page doesn''t say he''s signed out either');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');  -- Cleo
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000c2', null, 'parental-invite-v3')
            ->> 'summary', pg_temp.changed('parental-invite-v3'),
  'a kid agreed to v2 gets only v3''s what changed');

-- The cron's renewal emails carry the same --------------------------------------------------------------------------------
-- Nobody's link is fresh, so every held kid's parents are owed one.
select pg_temp.as_admin();
delete from public.parental_consent_sends;
delete from public.parental_consent_requests;
select pg_temp.as_service();
select set_config('test.claims', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select is((select c ->> 'summary' from jsonb_array_elements(current_setting('test.claims')::jsonb) c
            where c ->> 'first_name' = 'Kit'),
  pg_temp.changed('parental-invite-v2', 'parental-invite-v3'),
  'the cron''s email for a v1 kid says what changed in v2, then v3');
select is((select jsonb_object_agg(c ->> 'first_name', c -> 'was_linked')
             from jsonb_array_elements(current_setting('test.claims')::jsonb) c),
  '{"Kit": true, "Owen": false, "Pia": false}'::jsonb, 'and whether each kid had signed in');
select is((select c ->> 'summary' from jsonb_array_elements(current_setting('test.claims')::jsonb) c
            where c ->> 'first_name' = 'Pia'),
  pg_temp.changed('parental-invite-v3'), 'and for a v2 kid, only v3');
select pg_temp.as_admin();
select is(public.parental_changes_since('parental-invite-v1', 'parental-invite-v3'),
  pg_temp.changed('parental-invite-v2', 'parental-invite-v3'), 'from v1 to v3, both, in order');
update public.agreement_versions set requires_reagreement = false where version = 'parental-invite-v3';
select is(public.parental_changes_since('parental-invite-v2', 'parental-invite-v3'),
  pg_temp.changed('parental-invite-v3'), 'a typo fix alone still says what the sent wording is');
update public.agreement_versions set requires_reagreement = true where version = 'parental-invite-v3';

-- A newer wording comes into force and the hourly job hasn't run yet: Dan's family renews before he's held.
select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version = 'parental-invite-v4';
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol, no Apple email
select set_config('test.dan', public.request_parental_consent('00000000-0000-0000-0000-0000000000b2',
                                                              'carol@example.com', 'parental-invite-v4')::text, true);
select is(current_setting('test.dan')::jsonb -> 'held', 'false'::jsonb,
  'a renewal asked for before the hold opens says the kid isn''t held yet');
select is(current_setting('test.dan')::jsonb -> 'was_linked', 'true'::jsonb,
  'and Dan, signed in now, will be signed out');
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000b3', 'carol@example.com',
                                          'parental-invite-v4') - 'request_id' - 'send_id' - 'summary'
                                          - 'agreed_before' - 'email' - 'email_source' - 'first_name',
  '{"outcome": "send", "reason": "renewal", "text_version": "parental-invite-v4", "held": false,
    "was_linked": false}'::jsonb,
  'Eli, not held yet and never signed in, won''t be said to be signed out');
select pg_temp.as_admin();
select ok((select hold_id is null and reason = 'renewal' from public.parental_consent_requests
           where id = (current_setting('test.dan')::jsonb ->> 'request_id')::uuid),
  'and the request is a renewal belonging to no hold');

select * from finish();
rollback;
