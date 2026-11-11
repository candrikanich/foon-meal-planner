-- Opt-in email (#48): every time an adult turns an email on, a new agreement is logged, even to the same wording. Terms
-- and Privacy still log once per account per wording.
begin;
select plan(9);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a');
update public.app_config set account_email_enabled = true;

-- On, off, on again --------------------------------------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1', 'Foon 1.5 (80)') $$,
  'Alice turns on the weekly plan email');
select lives_ok($$ select public.set_email_preference('weekly_plan', false) $$, 'turns it off');
select lives_ok($$ select public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1', 'Foon 1.5 (81)') $$,
  'and on again, with the same wording');

select pg_temp.as_admin();
select results_eq(
  $$ select kind::text, text_version, context, client from public.account_agreements
      where user_id = 'a0000000-0000-0000-0000-00000000000a' order by client $$,
  $$ values ('weekly_plan_email', 'weekly-plan-email-v1', 'opt_in', 'Foon 1.5 (80)'),
            ('weekly_plan_email', 'weekly-plan-email-v1', 'opt_in', 'Foon 1.5 (81)') $$,
  'each time it''s turned on logs its own agreement');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_email_preference('founding_updates', true, 'founding-updates-v1');
select public.set_email_preference('founding_updates', false);
select public.set_email_preference('founding_updates', true, 'founding-updates-v1');
select pg_temp.as_admin();
select is((select count(*)::int from public.account_agreements
            where user_id = 'a0000000-0000-0000-0000-00000000000a' and kind = 'founding_updates'), 2,
  'and so do founding updates');
select results_eq(
  $$ select founding_updates, founding_updates_version from public.email_preferences
      where user_id = 'a0000000-0000-0000-0000-00000000000a' $$,
  $$ values (true, 'founding-updates-v1') $$, 'the preference is on, with that wording');

-- Terms and Privacy: once per wording ---------------------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v1', 'create_household') $$,
  'Alice accepts the Terms and Privacy');
select lives_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v1', 'next_launch') $$,
  'and again on the next launch');
select pg_temp.as_admin();
select results_eq(
  $$ select kind::text, context from public.account_agreements
      where user_id = 'a0000000-0000-0000-0000-00000000000a' and kind in ('terms', 'privacy') order by kind::text $$,
  $$ values ('privacy', 'create_household'), ('terms', 'create_household') $$,
  'which still logs each once, as first given');

select * from finish();
rollback;
