-- Opt-in account email (#48, PR C): an adult's own email preferences (nobody else reads them, only the function writes
-- them, kids can't opt in, opting in logs the wording), the weekly plan email queued on approval for opted-in adults only
-- and once per week, founding-family updates queued for opted-in adults, unsubscribing, and every way an account stops
-- being an adult in a household taking the preferences with it.
begin;
select plan(56);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true), set_config('role', 'anon', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role": "service_role"}', true), set_config('role', 'service_role', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;

-- Alice owns the Andersons, with Bob (an adult) and Kit (a kid with an account). Carol owns the Carters. Frank has no
-- household.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'frank@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000c0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');

-- Who reads and writes ---------------------------------------------------------------------------------------------------

select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.email_preferences'::regclass, 'public.founding_updates'::regclass)),
  'row-level security on both new tables');
select ok(not has_table_privilege('anon', 'public.email_preferences', 'select, insert, update, delete'),
  'anon has no grant on preferences');
select ok(not has_table_privilege('authenticated', 'public.email_preferences', 'insert, update, delete'),
  'a signed-in user only reads them');
select ok(not has_table_privilege('authenticated', 'public.founding_updates', 'select, insert, update, delete'),
  'and has no grant on founding updates');
select is((select confdeltype::text from pg_constraint
            where conrelid = 'public.email_preferences'::regclass and contype = 'f'), 'c',
  'deleting an account deletes its preferences');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.my_email_preferences(),
  '{"weekly_plan": false, "founding_updates": false, "can_opt_in": true, "available": false}'::jsonb,
  'both off by default, and an adult may opt in once email is on');
select throws_ok($$ select public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1') $$, '55000', null,
  'nothing turns on while account email is off');

select pg_temp.as_admin();
update public.app_config set account_email_enabled = true;

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1', 'Foon 1.5 (80)') ->> 'weekly_plan',
  'true', 'an adult turns on the weekly plan email');
select throws_ok($$ select public.set_email_preference('weekly_plan', true, 'founding-updates-v1') $$, '22023', null,
  'only with that email''s own wording');
select throws_ok($$ select public.set_email_preference('weekly_plan', true) $$, '22023', null, 'and never without one');
select throws_ok($$ select public.set_email_preference('newsletter', true, 'weekly-plan-email-v1') $$, '22023', null,
  'an unknown email is refused');
select is((select count(*)::int from public.email_preferences), 1, 'Alice reads her own preferences');

select pg_temp.as_admin();
select results_eq(
  $$ select kind::text, text_version, context, client from public.account_agreements
      where user_id = 'a0000000-0000-0000-0000-00000000000a' $$,
  $$ values ('weekly_plan_email', 'weekly-plan-email-v1', 'opt_in', 'Foon 1.5 (80)') $$,
  'opting in logs the agreement to its wording');
select results_eq(
  $$ select weekly_plan, weekly_plan_version, weekly_plan_agreed_at is not null, founding_updates
       from public.email_preferences where user_id = 'a0000000-0000-0000-0000-00000000000a' $$,
  $$ values (true, 'weekly-plan-email-v1', true, false) $$,
  'and the preference keeps which wording and when');
select results_eq(
  $$ select version, kind::text, effective_at from public.agreement_versions
      where kind in ('weekly_plan_email', 'founding_updates') order by version $$,
  $$ values ('founding-updates-v1', 'founding_updates', null::timestamptz),
            ('weekly-plan-email-v1', 'weekly_plan_email', null::timestamptz) $$,
  'both wordings are registered, not yet in force');

-- Adults only ------------------------------------------------------------------------------------------------------------

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1') $$, '42501', null,
  'a kid can''t turn on email');
select throws_ok($$ select public.set_email_preference('founding_updates', true, 'founding-updates-v1') $$, '42501', null,
  'not even founding updates');
select is(public.my_email_preferences() ->> 'can_opt_in', 'false', 'and the app is told so');
select lives_ok($$ select public.set_email_preference('weekly_plan', false) $$, 'turning one off is fine for anyone');
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select throws_ok($$ select public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1') $$, '42501', null,
  'nor can an account in no household');
select pg_temp.as_admin();
select is_empty($$ select 1 from public.email_preferences
                   where user_id in ('e0000000-0000-0000-0000-00000000000e', 'f0000000-0000-0000-0000-00000000000f') $$,
  'and nothing is stored for them');

-- Personal: nobody else reads them ----------------------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.email_preferences), 0, 'someone else in the household can''t read them');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.email_preferences), 0, 'nor can another household');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.email_preferences (user_id) values ('a0000000-0000-0000-0000-00000000000a') $$,
  '42501', null, 'they''re written only through set_email_preference');
select throws_ok($$ update public.email_preferences set founding_updates = true $$, '42501', null,
  'so nobody skips the agreement');
select pg_temp.as_anon();
select throws_ok($$ select public.my_email_preferences() $$, '42501', null, 'signed out, nothing');

-- The weekly plan email ---------------------------------------------------------------------------------------------------

select pg_temp.as_admin();
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos');
-- This week (the household's clock is America/New_York without a time zone), and one that ended a week ago.
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0',
   (now() at time zone 'America/New_York')::date),
  ('00000000-0000-0000-0000-0000000002a2', '00000000-0000-0000-0000-0000000000a0',
   (now() at time zone 'America/New_York')::date - 14);
insert into public.plan_nights (household_id, plan_id, date, meal_id, quick_pick) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   (now() at time zone 'America/New_York')::date, '00000000-0000-0000-0000-0000000001a1', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000002a1',
   (now() at time zone 'America/New_York')::date + 1, null, 'leftovers');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.approve_plan('00000000-0000-0000-0000-0000000002a1', '[]') $$, 'Alice approves the week');

select pg_temp.as_admin();
select results_eq(
  $$ select household_id, user_id, dedupe_key, payload from public.email_outbox where kind = 'weekly_plan' $$,
  $$ values ('00000000-0000-0000-0000-0000000000a0'::uuid, 'a0000000-0000-0000-0000-00000000000a'::uuid,
             '00000000-0000-0000-0000-0000000002a1:a0000000-0000-0000-0000-00000000000a',
             '{"plan_id": "00000000-0000-0000-0000-0000000002a1", "user_id": "a0000000-0000-0000-0000-00000000000a"}'::jsonb) $$,
  'approving queues the weekly plan email for the adult who opted in, and nobody else (ids only)');
select ok((select not_before > now() from public.email_outbox where kind = 'weekly_plan'),
  'a little later, so a quick swap after approving makes it in');

update public.plans set approved_at = null where id = '00000000-0000-0000-0000-0000000002a1';
update public.plans set approved_at = now() where id = '00000000-0000-0000-0000-0000000002a1';
select is((select count(*)::int from public.email_outbox where kind = 'weekly_plan'), 1,
  'approving the same week again sends nothing more');
update public.plans set approved_at = now() where id = '00000000-0000-0000-0000-0000000002a2';
select is((select count(*)::int from public.email_outbox where kind = 'weekly_plan'), 1,
  'nor does approving a week that''s over');

select pg_temp.as_service();
select is(public.account_email_weekly_plan('00000000-0000-0000-0000-0000000002a1') -> 'nights' -> 0 ->> 'meal', 'Tacos',
  'the email reads each night''s dish when it''s sent');
select is(public.account_email_weekly_plan('00000000-0000-0000-0000-0000000002a1') -> 'nights' -> 1 ->> 'quick_pick',
  'leftovers', 'or its quick pick');
select is(public.account_email_weekly_plan('00000000-0000-0000-0000-0000000002a1') ->> 'week_start',
  ((now() at time zone 'America/New_York')::date)::text, 'and the week it starts');
select pg_temp.as_admin();
update public.plans set approved_at = null where id = '00000000-0000-0000-0000-0000000002a1';
select pg_temp.as_service();
select is(public.account_email_weekly_plan('00000000-0000-0000-0000-0000000002a1'), null,
  'nothing once the week isn''t approved any more');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.account_email_weekly_plan('00000000-0000-0000-0000-0000000002a1') $$, '42501', null,
  'only the server reads it');

select public.set_email_preference('weekly_plan', false);
select pg_temp.as_admin();
select results_eq($$ select last_error_code, failed_at is not null from public.email_outbox where kind = 'weekly_plan' $$,
  $$ values ('opted_out', true) $$, 'turning it off drops the email still waiting');
select results_eq(
  $$ select weekly_plan, weekly_plan_version, weekly_plan_agreed_at from public.email_preferences
      where user_id = 'a0000000-0000-0000-0000-00000000000a' $$,
  $$ values (false, null::text, null::timestamptz) $$, 'and clears the wording it was on with');

-- Founding-family updates -------------------------------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.set_email_preference('founding_updates', true, 'founding-updates-v1');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.set_email_preference('founding_updates', true, 'founding-updates-v1');

select pg_temp.as_service();
select is(public.founding_update_audience(), 2, 'two adults opted in to founding updates');
create temp table sent_update on commit drop as
  select public.queue_founding_update('What''s new in Foon', 'Hello, founding families.') as result;
select is((select (result ->> 'queued')::int from sent_update), 2, 'an update queues one email for each of them');
select is(public.queue_founding_update('What''s new in Foon', 'Hello, founding families.') ->> 'repeat', 'true',
  'the same update again queues nothing new');
select is(public.account_email_founding_update(((select result from sent_update) ->> 'update_id')::uuid) ->> 'subject',
  'What''s new in Foon', 'the email reads the update''s words when it''s sent');

select pg_temp.as_admin();
select results_eq(
  $$ select user_id from public.email_outbox where kind = 'founding_update' order by user_id $$,
  $$ values ('a0000000-0000-0000-0000-00000000000a'::uuid), ('b0000000-0000-0000-0000-00000000000b'::uuid) $$,
  'to exactly those adults');
select ok((select bool_and(payload ?& array['update_id', 'user_id'] and not payload ? 'subject')
             from public.email_outbox where kind = 'founding_update'),
  'with ids only in the outbox');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.queue_founding_update('Spam', 'Spam') $$, '42501', null, 'only the server sends one');
select throws_ok($$ select public.email_unsubscribe('b0000000-0000-0000-0000-00000000000b', 'founding_updates') $$,
  '42501', null, 'or unsubscribes someone');

select pg_temp.as_service();
select public.email_unsubscribe('b0000000-0000-0000-0000-00000000000b', 'founding_updates');
select pg_temp.as_admin();
select is((select founding_updates from public.email_preferences where user_id = 'b0000000-0000-0000-0000-00000000000b'),
  false, 'an unsubscribe link turns it off');
select is((select last_error_code from public.email_outbox
            where kind = 'founding_update' and user_id = 'b0000000-0000-0000-0000-00000000000b'),
  'opted_out', 'and drops what was waiting for them');
select pg_temp.as_service();
select lives_ok($$ select public.email_unsubscribe('b0000000-0000-0000-0000-00000000000b', 'founding_updates') $$,
  'unsubscribing twice is fine');
select throws_ok($$ select public.email_unsubscribe('b0000000-0000-0000-0000-00000000000b', 'newsletter') $$, '22023',
  null, 'an unknown email is refused');

select pg_temp.as_admin();
update public.app_config set account_email_enabled = false;
select pg_temp.as_service();
select throws_ok($$ select public.queue_founding_update('Another', 'Update') $$, '55000', null,
  'nothing is queued while account email is off');
select pg_temp.as_admin();
update public.app_config set account_email_enabled = true;

-- The outbox takes the new kinds -------------------------------------------------------------------------------------------

select lives_ok($$ select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0',
  'a0000000-0000-0000-0000-00000000000a', 'subscription_refunded', 'kinds-test', '{}') $$,
  'the subscription kinds are still allowed');
select throws_ok($$ select public.enqueue_account_email('00000000-0000-0000-0000-0000000000a0',
  'a0000000-0000-0000-0000-00000000000a', 'newsletter', 'kinds-test', '{}') $$, '23514', null,
  'and an unknown kind still isn''t');

-- Leaving takes them ------------------------------------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.set_email_preference('weekly_plan', true, 'weekly-plan-email-v1');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_admin();
select is_empty($$ select 1 from public.email_preferences where user_id = 'b0000000-0000-0000-0000-00000000000b' $$,
  'someone removed from the household loses their preferences');

-- Delete my account unlinks the profile first.
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a1';
select is_empty($$ select 1 from public.email_preferences where user_id = 'a0000000-0000-0000-0000-00000000000a' $$,
  'so does an account unlinked from its profile');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select public.set_email_preference('founding_updates', true, 'founding-updates-v1');
select pg_temp.as_admin();
select public.erase_household('00000000-0000-0000-0000-0000000000c0');
select is_empty($$ select 1 from public.email_preferences where user_id = 'c0000000-0000-0000-0000-00000000000c' $$,
  'and deleting the household takes its people''s preferences');

select * from finish();
rollback;
