-- Agreement registry (#277): the wordings, which one is in force, and whether an agreement still counts. It ships
-- dormant: nothing is in force, so every agreement counts. Nobody writes the registry or the agreement log directly.
begin;
select plan(25);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role": "anon"}', true), set_config('role', 'anon', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a');

-- Dormant -------------------------------------------------------------------------------------------------------------
select has_table('public', 'agreement_versions', 'the registry has its own table');
select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.agreement_versions'::regclass, 'public.agreement_holds'::regclass,
                         'public.account_agreements'::regclass)),
  'row-level security on every new table');
select is((select array_agg(schedule order by jobname) from cron.job
           where jobname in ('apply-agreement-holds', 'kick-consent-renewals')),
  array['11 * * * *', '*/15 * * * *'], 'holds are applied hourly and renewal emails checked every 15 minutes');
select is((select count(*)::int from public.agreement_versions), 8, 'eight wordings are registered');
select is_empty($$ select 1 from public.agreement_versions where effective_at is not null $$,
  'none is in force: it ships dormant');
select is(public.current_agreement_version('parental'), null, 'so no wording is current');
select ok(public.agreement_satisfies('anything-v9', 'parental'), 'and every agreement counts, even an unknown one');
select is((select summary from public.agreement_versions where version = 'parental-invite-v3'),
  'Foon now confirms a parent''s consent by email, and names the services that store and send your kid''s information.',
  'v3 says what changed in plain words');

-- Who reads and writes it -----------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.agreement_versions), 8, 'anyone signed in reads the wordings');
select throws_ok($$ insert into public.agreement_versions (version, kind, ordinal, summary)
                    values ('terms-v9', 'terms', 9, 'New terms.') $$,
  '42501', null, 'but can''t add one');
select throws_ok($$ update public.agreement_versions set effective_at = now() $$, '42501', null,
  'or put one in force');
select throws_ok($$ delete from public.agreement_versions $$, '42501', null, 'or delete one');
select pg_temp.as_anon();
select throws_ok($$ select count(*) from public.agreement_versions $$, '42501', null, 'signed out, nothing');
select throws_ok($$ select public.current_agreement_version('terms') $$, '42501', null, 'not even the helpers');

-- In force ------------------------------------------------------------------------------------------------------------
select pg_temp.as_admin();
update public.agreement_versions set effective_at = now()
where version in ('allergy-data-v2', 'parental-invite-v2', 'parental-invite-v3');
select is(public.current_agreement_version('allergy_data'), 'allergy-data-v2', 'the newest in force is current');
select is(public.current_agreement_version('parental'), 'parental-invite-v3', 'by order, not by when it was set');
select ok(public.agreement_satisfies('allergy-data-v2', 'allergy_data'), 'an agreement to it counts');
select ok(not public.agreement_satisfies('allergy-data-v1', 'allergy_data'), 'one to an older wording doesn''t');
select ok(not public.agreement_satisfies('made-up-v1', 'allergy_data'), 'nor one to a wording nobody registered');
select ok(not public.agreement_satisfies('parental-invite-v2', 'parental'),
  'nor one older than the newest in force, though that one was in force too');
update public.agreement_versions set requires_reagreement = false where version = 'parental-invite-v3';
select ok(public.agreement_satisfies('parental-invite-v2', 'parental'),
  'unless every version since only fixed a typo');
select ok(not public.agreement_satisfies('parental-invite-v1', 'parental'),
  'one before a change that matters still doesn''t count');
update public.agreement_versions set effective_at = now() + interval '1 day' where version = 'allergy-data-v2';
select is(public.current_agreement_version('allergy_data'), null, 'a version due later isn''t in force yet');

-- The agreement log is written only by the functions --------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.consent_agreements (household_id, text_version)
                    values ('00000000-0000-0000-0000-0000000000a0', 'allergy-data-v2') $$,
  '42501', null, 'a parent can''t write the agreement log directly');
select pg_temp.as_admin();
select is_empty($$ select 1 from pg_policies where schemaname = 'public' and tablename = 'consent_agreements'
                     and cmd = 'INSERT' $$,
  'and no policy would let anyone');

select * from finish();
rollback;
