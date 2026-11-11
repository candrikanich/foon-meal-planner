-- Renewal sends (#277, 20261118000000): the Edge Function may send any registered parental wording that satisfies the
-- one in force, so one deployed ahead keeps sending and an outdated one never does; claiming reserves nothing for a
-- wording that doesn't; a hold's round clock starts only when an email is recorded as sent; and agreeing tells the
-- function whether it was a renewal.
begin;
select plan(21);

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
begin
  execute statement;
  return null;
exception when others then
  return sqlstate;
end;
$$;
create function pg_temp.first(setting text) returns jsonb language sql as $$
  select current_setting(setting)::jsonb -> 0;
$$;
create function pg_temp.hold() returns public.agreement_holds language sql security definer as $$
  select * from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a4';
$$;

-- Ann, a parent who signs in with Apple; Kit, her kid with an account, whose consent was given in the app (v1).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-ann', 'a0000000-0000-0000-0000-00000000000a',
   '{"sub": "apple-ann", "email": "ann@example.com", "email_verified": true}', 'apple');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e');
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-invite-v1');

-- Replays the rollout from the dormant state #277 shipped in: PR D (20261119000000_agreements_in_force.sql) put these
-- in force, so they're taken back out here and each step below puts back what it tests. 89 tests the state PR D leaves.
select pg_temp.as_admin();
update public.agreement_versions set effective_at = null
 where version in ('allergy-data-v2', 'own-allergy-v1', 'parental-invite-v2', 'parental-invite-v3', 'terms-draft-v1',
                   'privacy-draft-v1', 'privacy-draft-v2', 'weekly-plan-email-v1', 'founding-updates-v1');

-- Which wording may be sent ------------------------------------------------------------------------------------------------
select pg_temp.as_service();
select ok(public.parental_wording_ok('parental-invite-v3') and public.parental_wording_ok('parental-invite-v1'),
  'while nothing is in force, any registered parental wording may be sent');
select ok(not public.parental_wording_ok('parental-invite-v9') and not public.parental_wording_ok('allergy-data-v1'),
  'never an unknown one, or another kind''s');

select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version = 'parental-invite-v2';
select pg_temp.as_service();
select ok(public.parental_wording_ok('parental-invite-v3'),
  'a newer registered wording than the one in force may be sent (a function deployed ahead)');
select ok(not public.parental_wording_ok('parental-invite-v1'), 'an outdated one may not');
select public.apply_agreement_holds();
select is((pg_temp.hold()).required_version, 'parental-invite-v2', 'Kit is held for the wording in force');

-- Claiming ------------------------------------------------------------------------------------------------------------------
select is(pg_temp.error_of($$ select public.claim_consent_renewal_emails(10, 'parental-invite-v1') $$), '22023',
  'claiming for an outdated wording is refused');
select pg_temp.as_admin();
select is((select count(*)::int from public.parental_consent_requests) + (select count(*)::int from public.parental_consent_sends),
  0, 'and reserves nothing');
select pg_temp.as_service();
select set_config('test.c1', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select is(pg_temp.first('test.c1') ->> 'email', 'ann@example.com', 'a newer wording than the hold''s still claims');
select is(pg_temp.first('test.c1') ->> 'summary',
  (select summary from public.agreement_versions where version = 'parental-invite-v2') || ' ' || (select summary from public.agreement_versions where version = 'parental-invite-v3'),
  'and what changed covers every wording since the one agreed to (v1), up to the one sent (v3), in order');
select ok((pg_temp.hold()).emailed_at is null, 'reserving doesn''t start the round clock');

-- A send that fails ---------------------------------------------------------------------------------------------------------
select public.parental_consent_release_send((pg_temp.first('test.c1') ->> 'request_id')::uuid,
                                            (pg_temp.first('test.c1') ->> 'send_id')::bigint);
select ok((pg_temp.hold()).emailed_at is null, 'a released send leaves the hold as it was');
select set_config('test.c2', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select is(pg_temp.first('test.c2') ->> 'email', 'ann@example.com', 'and the parent is claimed again on the next run');

-- A send that goes out ------------------------------------------------------------------------------------------------------
select is(pg_temp.error_of(format('select public.parental_consent_mark_sent(%L, %s, %L, %L)',
                                  pg_temp.first('test.c2') ->> 'request_id', pg_temp.first('test.c2') ->> 'send_id',
                                  'hash-a0', 'parental-invite-v1')),
  '22023', 'an outdated wording isn''t recorded as sent');
select ok(public.parental_consent_mark_sent((pg_temp.first('test.c2') ->> 'request_id')::uuid,
                                            (pg_temp.first('test.c2') ->> 'send_id')::bigint, 'hash-a1',
                                            'parental-invite-v3'),
  'a newer one is');
select ok((pg_temp.hold()).emailed_at is not null and (pg_temp.hold()).reminded_at is null,
  'recording the email starts the round clock');

-- The reminder ----------------------------------------------------------------------------------------------------------------
select pg_temp.as_admin();
update public.agreement_holds set emailed_at = emailed_at - interval '8 days'
where member_id = '00000000-0000-0000-0000-0000000000a4';
update public.parental_consent_requests
set created_at = created_at - interval '8 days', token_sent_at = token_sent_at - interval '8 days';
select pg_temp.as_service();
select set_config('test.c3', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select ok((pg_temp.first('test.c3') ->> 'reminder')::boolean and (pg_temp.hold()).reminded_at is null,
  'a week on, the reminder is claimed without marking the hold');
select public.parental_consent_mark_sent((pg_temp.first('test.c3') ->> 'request_id')::uuid,
                                         (pg_temp.first('test.c3') ->> 'send_id')::bigint, 'hash-a2',
                                         'parental-invite-v3');
select ok((pg_temp.hold()).reminded_at is not null and (pg_temp.hold()).emailed_at < now() - interval '7 days',
  'recording it marks the reminder, and leaves the first email''s time');

-- Agreeing --------------------------------------------------------------------------------------------------------------------
select is(public.parental_consent_decide('hash-a2', 'agree') ->> 'reason', 'renewal',
  'agreeing says it was a renewal, for the confirming email');

-- Who can do this, and the old signature ------------------------------------------------------------------------------------
select hasnt_function('public', 'claim_consent_renewal_emails', array['integer'], 'the one-argument claim is gone');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select throws_ok($$ select public.claim_consent_renewal_emails(10, 'parental-invite-v3') $$, '42501', null,
  'a parent can''t claim emails');
select throws_ok($$ select public.parental_wording_ok('parental-invite-v3') $$, '42501', null,
  'or call the wording check');

select * from finish();
rollback;
