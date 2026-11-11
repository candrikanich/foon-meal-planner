-- Privacy Policy v2 in force (#48 PR D: 20261126000000_privacy_v2_in_force.sql). The registry starts as the migration
-- left it: privacy-draft-v2 and the two email opt-in wordings are in force, an adult who agreed to v1 is asked again
-- (and only asked: nothing is held), and agreeing to v2 clears it.
begin;
select plan(16);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;

-- Ann is an adult who agreed to v1 before v2 came in; Kit is her kid.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false, null);
insert into public.account_agreements (user_id, kind, text_version, context) values
  ('a0000000-0000-0000-0000-00000000000a', 'terms', 'terms-draft-v1', 'create_household'),
  ('a0000000-0000-0000-0000-00000000000a', 'privacy', 'privacy-draft-v1', 'create_household');

-- What's in force -------------------------------------------------------------------------------------------------------
select is(public.current_agreement_version('privacy'), 'privacy-draft-v2', 'privacy v2 is in force');
select is(public.current_agreement_version('terms'), 'terms-draft-v1', 'the Terms are unchanged');
select is(public.current_agreement_version('weekly_plan_email'), 'weekly-plan-email-v1',
  'the weekly plan email''s wording is in force with it');
select is(public.current_agreement_version('founding_updates'), 'founding-updates-v1',
  'and so is founding-family updates''');
select ok((select requires_reagreement from public.agreement_versions where version = 'privacy-draft-v2'),
  'v2 asks everyone again: it adds what Foon emails');
select ok(not public.agreement_satisfies('privacy-draft-v1', 'privacy'), 'so an agreement to v1 no longer counts');
select ok(public.agreement_satisfies('privacy-draft-v2', 'privacy'), 'and one to v2 does');
select is((select summary from public.agreement_versions where version = 'privacy-draft-v2'),
  'The Privacy Policy now lists the emails Foon sends adults (account notices, plus a weekly plan email and '
  || 'founding-family updates only if you turn them on), and that Foon counts finished shopping trips, never what was '
  || 'bought.',
  'what changed, in one plain sentence for the app''s gate');

-- An adult who agreed to v1 ----------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(public.my_agreements() -> 'privacy' ->> 'satisfied', 'false', 'Ann, who agreed to v1, is asked again');
select is(public.my_agreements() -> 'privacy' ->> 'current', 'privacy-draft-v2', 'to v2');
select is(public.my_agreements() -> 'privacy' ->> 'agreed', 'privacy-draft-v1', 'knowing she agreed to v1');
select is(public.my_agreements() -> 'terms' ->> 'satisfied', 'true', 'the Terms she agreed to still count');
select is(public.my_access_hold(), null, 'she isn''t held: the gate is the app''s');

select pg_temp.as_admin();
select public.apply_agreement_holds();
select is((select count(*)::int from public.agreement_holds where household_id = '00000000-0000-0000-0000-0000000000a0'),
  0, 'and the hold job holds nothing for a privacy change');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select lives_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v2', 'changed', 'Foon 1.5 (90)') $$,
  'Ann agrees to v2');
select is(public.my_agreements() -> 'privacy' ->> 'satisfied', 'true', 'and isn''t asked again');

select * from finish();
rollback;
