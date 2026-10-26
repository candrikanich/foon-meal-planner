-- Parental consent and retention (#12): kids join only with a parent's recorded consent; revoking it
-- unlinks the kid; removed or un-consented kid profiles are anonymized on a schedule (COPPA retention).
begin;
select plan(22);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Household A: Alice (owner, parent). Profiles: Nora, Owen (kids), Ben (adult), all unclaimed;
-- Kim (kid, claimed, with consent). Retention fixtures: Rita, Sam (removed kids), Tia, Uma (kids
-- whose consent was withdrawn 31 and 29 days ago), Val (removed adult), Wes (kid with two consent
-- cycles, latest withdrawn yesterday).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'erin@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'frank@example.com', 'authenticated', 'authenticated'),
  ('70000000-0000-0000-0000-000000000007', 'kim@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false, 'active', '70000000-0000-0000-0000-000000000007'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a0', 'Rita', 'member', 'kid', false, 'removed', null),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a0', 'Sam', 'member', 'kid', false, 'removed', null),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a0', 'Tia', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000a0', 'Uma', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000a0', 'Val', 'member', 'adult', false, 'removed', null),
  ('00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-0000000000a0', 'Wes', 'member', 'kid', false, 'active', null);
update public.members set declared_age_band = 'under_13' where first_name = 'Tia';
update public.members set removed_at = now() - interval '13 months' where first_name in ('Rita', 'Val');
update public.members set removed_at = now() - interval '11 months' where first_name = 'Sam';
insert into public.consents (household_id, member_id, kind, granted_by, granted_at, revoked_at, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'parental', 'a0000000-0000-0000-0000-00000000000a', now(), null, 'v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b3', 'parental', 'a0000000-0000-0000-0000-00000000000a', now() - interval '60 days', now() - interval '31 days', 'v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b4', 'parental', 'a0000000-0000-0000-0000-00000000000a', now() - interval '60 days', now() - interval '29 days', 'v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b6', 'parental', 'a0000000-0000-0000-0000-00000000000a', now() - interval '90 days', now() - interval '60 days', 'v1'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b6', 'parental', 'a0000000-0000-0000-0000-00000000000a', now() - interval '40 days', now() - interval '1 day', 'v1'),
  ('00000000-0000-0000-0000-0000000000a0', null, 'allergy_data', 'a0000000-0000-0000-0000-00000000000a', now(), null, 'v1');
insert into public.member_allergies (household_id, member_id, category) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b1', 'milk'),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b3', 'peanuts');

-- A kid's profile is invited only with a parent's consent ----------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a2') $$,
  '22023', null, 'a kid''s profile needs parental consent before an invite');
insert into public.consents (household_id, member_id, kind, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'parental', 'parental-invite-v1');
select set_config('test.nora', public.create_invite('00000000-0000-0000-0000-0000000000a2'), true);
select set_config('test.ben', public.create_invite('00000000-0000-0000-0000-0000000000a4'), true);
select ok(current_setting('test.ben') <> '', 'an adult''s profile needs no parental consent');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Dave
select is(public.redeem_invite(current_setting('test.nora'), 'under_13'), 'claimed',
  'a kid with a parent''s consent joins');
select is((select declared_age_band::text from public.members where id = '00000000-0000-0000-0000-0000000000a2'),
  'under_13', 'only the age band is kept');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Erin
select is(public.redeem_invite(current_setting('test.ben'), '13_15'), 'age_mismatch',
  'a minor''s account cannot claim an adult profile');
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a4'), null,
  'the adult profile stays unclaimed');
select is(public.redeem_invite(current_setting('test.ben')), 'claimed',
  'without an age signal (older app or unsupported region) the claim goes ahead');

-- Consent revoked between invite and claim --------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
insert into public.consents (household_id, member_id, kind, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'parental', 'parental-invite-v1');
select set_config('test.owen', public.create_invite('00000000-0000-0000-0000-0000000000a3'), true);
update public.consents set revoked_at = now()
where member_id = '00000000-0000-0000-0000-0000000000a3' and kind = 'parental';
select is((select count(*)::int from public.invites
           where member_id = '00000000-0000-0000-0000-0000000000a3' and revoked_at is null), 0,
  'revoking a kid''s consent cancels their open invite');

-- Revoking consent for a kid who already joined unlinks them -------------------------------
update public.consents set revoked_at = now()
where member_id = '00000000-0000-0000-0000-0000000000a5' and kind = 'parental';
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a5'), null,
  'revoking consent unlinks the kid''s account at once');
select is((select first_name from public.members where id = '00000000-0000-0000-0000-0000000000a5'), 'Kim',
  'the profile and its history stay');
select pg_temp.as_user('70000000-0000-0000-0000-000000000007');  -- Kim
select is_empty($$ select 1 from public.members $$, 'the kid loses access');

-- Removal timestamps -------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a4';
select pg_temp.as_admin();
select ok((select removed_at > now() - interval '1 minute' from public.members
           where id = '00000000-0000-0000-0000-0000000000a4'), 'removal is timestamped');
update public.members set status = 'active' where id = '00000000-0000-0000-0000-0000000000a4';
select is((select removed_at from public.members where id = '00000000-0000-0000-0000-0000000000a4'), null,
  'restoring a profile clears the removal time');

-- Retention ----------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.anonymize_expired_profiles() $$, '42501', null,
  'clients cannot run the retention job');

select pg_temp.as_admin();
select is(public.anonymize_expired_profiles(), 2, 'the retention job handles the two expired kid profiles');
select results_eq(
  $$ select first_name, avatar, anonymized_at is not null from public.members
     where id = '00000000-0000-0000-0000-0000000000b1' $$,
  $$ values ('Former member', null::text, true) $$,
  'a kid removed 13 months ago is anonymized');
select is_empty($$ select 1 from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000b1' $$,
  'an anonymized profile''s allergies are deleted');
select results_eq(
  $$ select first_name, declared_age_band, own_data_erased_at is not null, anonymized_at is null
     from public.members where id = '00000000-0000-0000-0000-0000000000b3' $$,
  $$ values ('Tia', null::public.age_band, true, true) $$,
  '30 days after consent is withdrawn, the kid''s own data and age band are erased, and the profile stays');
select is((select count(*)::int from public.member_allergies where member_id = '00000000-0000-0000-0000-0000000000b3'), 1,
  'a kid still in the family keeps their allergies');
select is((select string_agg(first_name, ',' order by first_name) from public.members
           where own_data_erased_at is null and anonymized_at is null
             and id in ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b4',
                        '00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-0000000000b6')),
  'Sam,Uma,Val,Wes',
  'removed 11 months ago, withdrawn 29 days ago, an adult, and a second withdrawal yesterday are all left alone');
select is(public.anonymize_expired_profiles(), 0, 'the job does not touch a profile twice');
select is((select count(*)::int from cron.job where jobname = 'anonymize-expired-profiles'), 1,
  'the retention job runs daily');

select * from finish();
rollback;
