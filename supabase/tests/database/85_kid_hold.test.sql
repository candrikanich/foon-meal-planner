-- A kid's parental-consent hold (#277). Once a new parental wording is in force, a kid whose consent agreed to an older
-- one is held: signed out, invites revoked, profile kept, consent left active (so no erase clock and pushes still name
-- them), and every parent with a device hears about it. A parent renews by email plus, which links the kid's account
-- back; a No keeps them held. Withdrawing, removing and delete_kid work during a hold; the export shows it.
begin;
select plan(44);

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
create function pg_temp.request(setting text) returns uuid language sql as $$
  select (current_setting(setting)::jsonb ->> 'request_id')::uuid;
$$;
create function pg_temp.send(setting text) returns bigint language sql as $$
  select (current_setting(setting)::jsonb ->> 'send_id')::bigint;
$$;

-- Household A: Ann (owner, parent) and Ben (parent), both with Apple emails and devices; Grace (an adult who isn't a
-- parent, with a device); kids Kit, Nora and Lia (each with their own account), Owen and Max (without). Every kid's
-- consent was given in the app to parental-invite-v1. Household B: Carol and Dan, whose consent is to v3.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'nora@example.com', 'authenticated', 'authenticated'),
  ('10000000-0000-0000-0000-000000000001', 'lia@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-ann', 'a0000000-0000-0000-0000-00000000000a',
   '{"sub": "apple-ann", "email": "ann@example.com", "email_verified": true}', 'apple'),
  ('apple-ben', 'b0000000-0000-0000-0000-00000000000b',
   '{"sub": "apple-ben", "email": "ben@example.com", "email_verified": true}', 'apple');
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
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false,
   'f0000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Lia', 'member', 'kid', false,
   '10000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a0', 'Max', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'kid', false, null);
insert into public.consents (household_id, member_id, kind, granted_by, text_version)
select '00000000-0000-0000-0000-0000000000a0', kid, 'parental', 'a0000000-0000-0000-0000-00000000000a',
       'parental-invite-v1'
from unnest(array['00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a5',
                  '00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a7',
                  '00000000-0000-0000-0000-0000000000a8']::uuid[]) as kid;
insert into public.consents (household_id, member_id, kind, granted_by, text_version, method) values
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'parental',
   'c0000000-0000-0000-0000-00000000000c', 'parental-invite-v3', 'email_plus');
insert into public.push_devices (user_id, member_id, household_id, token, environment) values
  ('a0000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0',
   repeat('a1', 32), 'sandbox'),
  ('b0000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0',
   repeat('a2', 32), 'sandbox'),
  ('d0000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0',
   repeat('a3', 32), 'sandbox');

-- Replays the rollout from the dormant state #277 shipped in: PR D (20261119000000_agreements_in_force.sql) put these
-- in force, so they're taken back out here and each step below puts back what it tests. 89 tests the state PR D leaves.
select pg_temp.as_admin();
update public.agreement_versions set effective_at = null
 where version in ('allergy-data-v2', 'own-allergy-v1', 'parental-invite-v2', 'parental-invite-v3', 'terms-draft-v1',
                   'privacy-draft-v1');

-- Dormant -------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann invites Owen while nothing is in force
select public.create_invite('00000000-0000-0000-0000-0000000000a5');
select pg_temp.as_admin();
select ok(public.has_current_parental_consent('00000000-0000-0000-0000-0000000000a4'),
  'dormant, a consent given in the app is current');
select pg_temp.as_service();
select is(public.apply_agreement_holds(), 0, 'and nobody is held');

-- v3 in force: every kid on an older wording is held -------------------------------------------------------------------
select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version in ('parental-invite-v2', 'parental-invite-v3');
select ok(public.has_parental_consent('00000000-0000-0000-0000-0000000000a4')
          and not public.has_current_parental_consent('00000000-0000-0000-0000-0000000000a4'),
  'once v3 is in force, a consent to v1 is active but outdated');
select ok(public.has_current_parental_consent('00000000-0000-0000-0000-0000000000b2'),
  'and one to v3 is current');
select pg_temp.as_service();
select is(public.apply_agreement_holds(), 5, 'the job holds every kid on an older wording');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a4'), null,
  'a held kid is signed out');
select is((select (held_user_id, was_linked, held_version, required_version)::text
           from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a4'),
  '(e0000000-0000-0000-0000-00000000000e,t,parental-invite-v1,parental-invite-v3)',
  'the hold keeps their account to link back, and what was agreed and is needed');
select is((select count(*)::int from public.consents
           where member_id = '00000000-0000-0000-0000-0000000000a4' and kind = 'parental' and revoked_at is null), 1,
  'nothing is withdrawn');
select ok(public.push_may_name('00000000-0000-0000-0000-0000000000a4'),
  'so no erase clock starts, and pushes still name them');
select is((select count(*)::int from public.invites
           where member_id = '00000000-0000-0000-0000-0000000000a5' and redeemed_at is null and revoked_at is null), 0,
  'open invites are revoked');
select is((select array_agg(member_id::text order by member_id::text) from public.push_outbox
           where kind = 'agreement_hold' and about_member_id = '00000000-0000-0000-0000-0000000000a4'),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2'],
  'every parent with a device hears about it, and nobody else');
select is((select args ->> 'name' from public.push_outbox
           where kind = 'agreement_hold' and about_member_id = '00000000-0000-0000-0000-0000000000a4'
             and member_id = '00000000-0000-0000-0000-0000000000a1'),
  'Kit', 'by the kid''s first name');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Kit
select is(public.my_access_hold() - 'held_at', '{"household_name": "Andersons", "first_name": "Kit"}'::jsonb,
  'the kid''s device can say they''re waiting for a parent');
select is((select count(*)::int from public.members), 0, 'and reaches nothing in the family');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a8') $$, '22023', null,
  'a held kid isn''t invited');
select is(jsonb_array_length(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'kids_held'), 5,
  'parents see every held kid');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select is(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'kids_held', '[]'::jsonb,
  'an adult who isn''t a parent doesn''t');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is((select count(*)::int from public.agreement_holds), 0, 'nor does another household');

-- A parent renews by email plus ------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann, for Kit
select set_config('test.kit', public.request_parental_consent('00000000-0000-0000-0000-0000000000a4')::text, true);
select is(current_setting('test.kit')::jsonb ->> 'reason', 'renewal', 'a parent asks again by email');
select is(current_setting('test.kit')::jsonb ->> 'text_version', 'parental-invite-v3', 'for the wording in force');
select pg_temp.as_service();
select is(pg_temp.error_of(format('select public.parental_consent_mark_sent(%L, %s, %L, %L)', pg_temp.request('test.kit'),
                                  pg_temp.send('test.kit'), 'hash-k0', 'parental-invite-v2')),
  '22023', 'an outdated wording isn''t recorded as sent');
select public.parental_consent_mark_sent(pg_temp.request('test.kit'), pg_temp.send('test.kit'), 'hash-k1',
                                         'parental-invite-v3');
select is(public.parental_consent_lookup('hash-k1') - 'expires_at' - 'agreed_before',
  jsonb_build_object('outcome', 'pending', 'reason', 'renewal', 'first_name', 'Kit', 'summary',
    'Foon now confirms a parent''s consent by email, and names the services that store and send your kid''s information.'),
  'the page says it''s a renewal and what changed');
select ok((public.parental_consent_lookup('hash-k1') ->> 'agreed_before') is not null,
  'and when a parent agreed before');
select public.parental_consent_decide('hash-k1', 'agree');
select is(public.activate_parental_consent(pg_temp.request('test.kit'), 'whash-k'), 'confirmed',
  'with the confirming email out, the renewal is active');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a4'),
  'e0000000-0000-0000-0000-00000000000e'::uuid, 'the kid''s account is linked back');
select is((select (released_reason, relinked, held_user_id is null)::text
           from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a4'),
  '(renewed,t,t)', 'the hold ends, and forgets the account');
select is((select count(*)::int from public.consents
           where member_id = '00000000-0000-0000-0000-0000000000a4' and kind = 'parental'), 1,
  'on the same consent: none is added');
select is((select (method, request_id = pg_temp.request('test.kit'))::text from public.consent_agreements
           where member_id = '00000000-0000-0000-0000-0000000000a4' and text_version = 'parental-invite-v3'),
  '(email_plus,t)', 'the renewal is logged with its method and request');
select ok(public.has_current_parental_consent('00000000-0000-0000-0000-0000000000a4'), 'Kit is current again');

-- A parent says no: still held, nothing revoked ------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben, for Owen
select set_config('test.owen', public.request_parental_consent('00000000-0000-0000-0000-0000000000a5')::text, true);
select pg_temp.as_service();
select public.parental_consent_mark_sent(pg_temp.request('test.owen'), pg_temp.send('test.owen'), 'hash-o1',
                                         'parental-invite-v3');
select is(public.parental_consent_decide('hash-o1', 'refuse'), '{"outcome": "refused"}'::jsonb, 'a parent says no');
select pg_temp.as_admin();
select ok(exists (select 1 from public.agreement_holds
                  where member_id = '00000000-0000-0000-0000-0000000000a5' and released_at is null)
          and public.has_parental_consent('00000000-0000-0000-0000-0000000000a5'),
  'Owen stays held, and nothing is withdrawn');

-- Withdrawing during a hold ------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann withdraws Owen's consent in the app
update public.consents set revoked_at = now()
where member_id = '00000000-0000-0000-0000-0000000000a5' and kind = 'parental';
select pg_temp.as_admin();
select is((select released_reason from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a5'),
  'withdrawn', 'withdrawing ends the hold');
select ok(not public.push_may_name('00000000-0000-0000-0000-0000000000a5'), 'and starts the erase clock, as before');

-- The kid's account was deleted while held -----------------------------------------------------------------------------
delete from auth.users where id = 'f0000000-0000-0000-0000-00000000000f';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann, for Nora
select set_config('test.nora', public.request_parental_consent('00000000-0000-0000-0000-0000000000a6')::text, true);
select pg_temp.as_service();
select public.parental_consent_mark_sent(pg_temp.request('test.nora'), pg_temp.send('test.nora'), 'hash-n1',
                                         'parental-invite-v3');
select public.parental_consent_decide('hash-n1', 'agree');
select is(public.activate_parental_consent(pg_temp.request('test.nora'), 'whash-n'), 'confirmed',
  'a renewal still goes through after the kid''s account is gone');
select pg_temp.as_admin();
select is((select (released_reason, relinked)::text from public.agreement_holds
           where member_id = '00000000-0000-0000-0000-0000000000a6'),
  '(account_gone,f)', 'but there''s no account to link back: a parent invites them again');

-- A held kid who turns out to be an adult -------------------------------------------------------------------------------
savepoint grown_up;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann corrects the profile
update public.members set age_group = 'adult' where id = '00000000-0000-0000-0000-0000000000a8';
select pg_temp.as_admin();
select is((select (released_reason, held_user_id is null)::text from public.agreement_holds
           where member_id = '00000000-0000-0000-0000-0000000000a8'),
  '(not_a_kid,t)', 'parental consent no longer applies, so the hold ends: they''re invited like any adult');
rollback to savepoint grown_up;

-- Removing a held kid ---------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a8';
select pg_temp.as_admin();
select is((select released_reason from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a8'),
  'removed', 'removing a held kid ends their hold');

-- Deleting a held kid --------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.delete_kid('00000000-0000-0000-0000-0000000000a7') $$, 'a parent deletes a held kid');
select pg_temp.as_admin();
select is_empty($$ select 1 from auth.users where id = '10000000-0000-0000-0000-000000000001' $$,
  'their account goes too, though the hold had unlinked it');
select is_empty($$ select 1 from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a7'
                   union all
                   select 1 from public.consent_agreements where member_id = '00000000-0000-0000-0000-0000000000a7' $$,
  'and so do their hold and agreements');

-- Export ----------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'agreement_holds'), 4,
  'the export has the holds');
select ok(not exists (select 1 from jsonb_array_elements(
            public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'parental_consent_requests') as r (row)
          where not row ? 'reason'),
  'and why each consent email went');

-- The renewal's withdraw link -----------------------------------------------------------------------------------------
select pg_temp.as_service();
select is(public.withdraw_parental_consent('whash-k'), 'withdrawn', 'the renewal''s withdraw link withdraws the consent');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a4'), null,
  'which signs the kid out, as before');

select * from finish();
rollback;
