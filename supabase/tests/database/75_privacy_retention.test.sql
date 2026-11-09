-- Privacy and retention gaps (#67): any parent turns allergy alerts off, which erases the household's allergies and
-- nobody else's; the daily job anonymizes an adult removed 12 months ago like a kid, and prunes old invites and redeem
-- attempts.
begin;
select plan(26);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Ann (owner, parent), Ben (a parent who isn't the owner), Grace (a planner who isn't a parent), Owen (a kid
-- with a milk allergy), Val (an adult removed 13 months ago, with a peanut allergy), Sam (an adult removed 11 months ago),
-- Ivy and Jo (invited). Household B: Carol (owner, parent) and Dan (a kid with an egg allergy).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'grace@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true, 'active', 'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'active', 'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Val', 'member', 'adult', false, 'removed', null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Sam', 'member', 'adult', false, 'removed', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Ivy', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a0', 'Jo', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Dan', 'member', 'kid', false, 'active', null);
update public.members set avatar = '🐢', attendance_defaults = '{"usually_away": [2]}'
where id in ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a6');
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a5';
update public.members set removed_at = now() - interval '11 months' where id = '00000000-0000-0000-0000-0000000000a6';
insert into public.consents (household_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v2'),
  ('00000000-0000-0000-0000-0000000000b0', 'allergy_data', 'c0000000-0000-0000-0000-00000000000c', 'allergy-data-v2');
insert into public.consent_agreements (household_id, agreed_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', 'a0000000-0000-0000-0000-00000000000a', 'allergy-data-v2');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'milk'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'peanuts'),
  ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b2', 'eggs');

-- Invites, by the last two characters of their id: e1 redeemed 38 days ago, e2 expired 31 days ago, e3 expired 29 days
-- ago, e4 redeemed 29 days ago, e5 revoked 31 days ago (it would have expired 25 days ago), e6 still open.
insert into public.invites (id, household_id, member_id, code_hash, created_by, created_at, expires_at, redeemed_at,
                            revoked_at) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4',
   'hash-e1', 'a0000000-0000-0000-0000-00000000000a', now() - interval '40 days', now() - interval '33 days',
   now() - interval '38 days', null),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4',
   'hash-e2', 'a0000000-0000-0000-0000-00000000000a', now() - interval '38 days', now() - interval '31 days', null, null),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7',
   'hash-e3', 'a0000000-0000-0000-0000-00000000000a', now() - interval '36 days', now() - interval '29 days', null, null),
  ('00000000-0000-0000-0000-0000000000e4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7',
   'hash-e4', 'a0000000-0000-0000-0000-00000000000a', now() - interval '30 days', now() - interval '23 days',
   now() - interval '29 days', null),
  ('00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a8',
   'hash-e5', 'a0000000-0000-0000-0000-00000000000a', now() - interval '32 days', now() - interval '25 days', null,
   now() - interval '31 days'),
  ('00000000-0000-0000-0000-0000000000e6', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a8',
   'hash-e6', 'a0000000-0000-0000-0000-00000000000a', now(), now() + interval '7 days', null, null);
insert into public.invite_redeem_attempts (user_id, attempted_at, succeeded) values
  ('b0000000-0000-0000-0000-00000000000b', now() - interval '25 hours', false),
  ('b0000000-0000-0000-0000-00000000000b', now() - interval '23 hours', true);

-- The daily job --------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.anonymize_expired_profiles() $$, '42501', null, 'clients still can''t run the job');

select pg_temp.as_admin();
select is(public.anonymize_expired_profiles(), 1, 'the job handles the one adult removed over 12 months ago');
select results_eq(
  $$ select first_name, avatar, attendance_defaults, anonymized_at is not null from public.members
     where id = '00000000-0000-0000-0000-0000000000a5' $$,
  $$ values ('Former member', null::text, '{}'::jsonb, true) $$,
  'an adult removed 13 months ago becomes "Former member", like a kid');
select is_empty($$ select 1 from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a5' $$,
  'and their allergies are deleted');
select results_eq(
  $$ select first_name, avatar, anonymized_at is null from public.members
     where id = '00000000-0000-0000-0000-0000000000a6' $$,
  $$ values ('Sam', '🐢'::text, true) $$,
  'an adult removed 11 months ago is left alone');
select is((select first_name from public.members where id = '00000000-0000-0000-0000-0000000000a2'), 'Ben',
  'an adult still in the family is left alone');
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000a4'), 1,
  'a kid still in the family keeps their allergies');
select is((select string_agg(right(id::text, 2), ',' order by id) from public.invites), 'e3,e4,e6',
  'invites go 30 days after they expired, were redeemed or were revoked; newer and open ones stay');
select is((select count(*)::int from public.invite_redeem_attempts where attempted_at < now() - interval '1 day'), 0,
  'redeem attempts older than a day go');
select is((select count(*)::int from public.invite_redeem_attempts), 1, 'and a newer one stays');
select is(public.anonymize_expired_profiles(), 0, 'the job doesn''t touch a profile twice');

-- Allergy alerts off ---------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.revoke_allergy_consent(uuid)', 'execute'),
  'signed-out callers can''t turn allergy alerts off');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Grace
select throws_ok($$ select public.revoke_allergy_consent('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'a planner who isn''t a parent can''t turn allergy alerts off');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select throws_ok($$ select public.revoke_allergy_consent('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'another household''s parent can''t either');

select pg_temp.as_admin();
select is((select count(*)::int from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000a0'),
  1, 'so the household''s allergies are still there');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select lives_ok($$ select public.revoke_allergy_consent('00000000-0000-0000-0000-0000000000a0') $$,
  'any parent turns allergy alerts off, not only the owner');

select pg_temp.as_admin();
select is_empty(
  $$ select 1 from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  'every allergy recorded for the household is erased');
select is((select count(*)::int from public.member_allergies where household_id = '00000000-0000-0000-0000-0000000000b0'),
  1, 'another household''s allergies stay');
select results_eq(
  $$ select count(*) filter (where revoked_at is null)::int, count(*) filter (where revoked_at is not null)::int
     from public.consents where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data' $$,
  $$ values (0, 1) $$,
  'the consent is revoked, and the log keeps it');
select is((select count(*)::int from public.consent_agreements
           where household_id = '00000000-0000-0000-0000-0000000000a0'), 1,
  'the record of who agreed stays');
select is((select count(*)::int from public.consents
           where household_id = '00000000-0000-0000-0000-0000000000b0' and revoked_at is null), 1,
  'another household''s consent stays');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select throws_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['milk']::public.allergen[],
                                         array[]::text[]) $$,
  '42501', null, 'with alerts off, nobody can add an allergy');
select lives_ok($$ select public.revoke_allergy_consent('00000000-0000-0000-0000-0000000000a0') $$,
  'turning them off again changes nothing');
select lives_ok($$ select public.grant_allergy_consent('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v2') $$,
  'agreeing again turns them back on');
select lives_ok(
  $$ select public.set_member_allergies('00000000-0000-0000-0000-0000000000a4', array['eggs']::public.allergen[],
                                         array[]::text[]) $$,
  'and allergies can be added again');

select pg_temp.as_admin();
select is((select count(*)::int from public.consents
           where household_id = '00000000-0000-0000-0000-0000000000a0' and kind = 'allergy_data'), 2,
  'turning them back on starts a new consent, and the revoked one stays in the log');

select * from finish();
rollback;
