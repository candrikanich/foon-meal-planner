-- The notification log (#40 part 1). A device writes its own rows and nobody else's; planners read the household's, everyone
-- reads their own, and another household reads nothing. Only type, night, and times: there's nowhere to put message text.
begin;
select plan(40);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.entry(id uuid, type text = 'after_dinner', night uuid = null, sent timestamptz = null,
                              answered timestamptz = null, response text = null) returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'type', type, 'night_id', night, 'scheduled_for', '2037-11-02T19:00:00Z',
                            'sent_at', sent, 'responded_at', answered, 'response', response);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'kim@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'dee@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
-- Alice plans, Bob is a member, Kim is a kid with her own account, Zed a kid whose consent gets withdrawn, Dee an adult whose
-- account gets deleted, and Carol plans the other household.
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', 'adult', false,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false,
   'd0000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Zed', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Dee', 'member', 'adult', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0', '2037-11-01'),
  ('00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000b0', '2037-11-01');
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1', '2037-11-02'),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000003b1', '2037-11-02');

select has_table('public', 'notification_log', 'the log exists');
select ok((select relrowsecurity from pg_class where oid = 'public.notification_log'::regclass), 'it has row-level security');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public'
                      and table_name = 'notification_log' and data_type in ('text', 'jsonb')
                      and column_name not in ('type', 'channel', 'response')),
  'nothing free-form: no column could hold message text or allergy data');

-- Everyone writes their own.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004a1', 'prep_reminder', '00000000-0000-0000-0000-0000000000d1'))) $$,
  'a planner writes her own row');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004a2'))) $$, 'a member writes his own');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004a3', 'after_dinner', '00000000-0000-0000-0000-0000000000d1'))) $$,
  'a kid writes her own');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000b0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004b1'))) $$, 'another household writes its own');

-- Isolation: who reads what.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.notification_log), 3, 'a planner reads her whole household, and nothing else');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select results_eq($$ select id from public.notification_log $$,
  $$ values ('00000000-0000-0000-0000-0000000004a2'::uuid) $$, 'a member reads only his own');
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select results_eq($$ select id from public.notification_log $$,
  $$ values ('00000000-0000-0000-0000-0000000004a3'::uuid) $$, 'a kid reads only her own');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select results_eq($$ select id from public.notification_log $$,
  $$ values ('00000000-0000-0000-0000-0000000004b1'::uuid) $$, 'another household reads only its own');

-- Nobody writes around the function, or into someone else's.
select throws_ok($$ insert into public.notification_log (id, household_id, member_id, type, scheduled_for)
    values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000b1', 'prep_reminder', now()) $$,
  '42501', null, 'not even your own row directly');
select throws_ok($$ update public.notification_log set response = 'done' $$, '42501', null, 'or an update');
select throws_ok($$ delete from public.notification_log $$, '42501', null, 'or a delete');
select throws_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004c1'))) $$, '42501', null, 'another household can''t write here');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000b0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004a3', 'prep_reminder', null, '2037-11-02T19:00:00Z'))) $$,
  'sending someone else''s id is quietly nothing');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004a3', 'after_dinner', null, null, '2037-11-02T19:00:00Z', 'done'))) $$,
  'as it is from the same household');
reset role;
select is((select household_id::text || member_id::text || coalesce(response, 'none') || (sent_at is null)::text
           from public.notification_log where id = '00000000-0000-0000-0000-0000000004a3'),
  '00000000-0000-0000-0000-0000000000a0' || '00000000-0000-0000-0000-0000000000a3' || 'none' || 'true',
  'the row stays as it was');

-- It always writes the caller's member, and a night from elsewhere reads as none.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry('00000000-0000-0000-0000-0000000004a4', 'after_dinner', '00000000-0000-0000-0000-0000000000e1'))) $$,
  'a row naming another household''s night still goes in');
reset role;
select is((select night_id from public.notification_log where id = '00000000-0000-0000-0000-0000000004a4'), null,
  'without the night');
select is((select member_id from public.notification_log where id = '00000000-0000-0000-0000-0000000004a4'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'and under the caller');

-- Sending again only fills in.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
  pg_temp.entry('00000000-0000-0000-0000-0000000004a1', 'prep_reminder', '00000000-0000-0000-0000-0000000000d1',
                '2037-11-02T19:00:00Z', '2037-11-02T19:05:00Z', 'done')));
select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
  pg_temp.entry('00000000-0000-0000-0000-0000000004a1', 'prep_reminder')));
select results_eq($$ select sent_at, responded_at, response from public.notification_log
                     where id = '00000000-0000-0000-0000-0000000004a1' $$,
  $$ values ('2037-11-02T19:00:00Z'::timestamptz, '2037-11-02T19:05:00Z'::timestamptz, 'done'::text) $$,
  'a stale copy can''t clear what''s known');
select throws_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', '{}') $$, '22023', null,
  'entries must be a list');
select throws_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry(gen_random_uuid(), 'Has Spaces'))) $$, '23514', null, 'a type is a short key, not a sentence');

-- Export, and retention.
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'notification_log'), 4,
  'the export includes it');
reset role;
insert into public.notification_log (id, household_id, member_id, type, scheduled_for, created_at) values
  ('00000000-0000-0000-0000-0000000004a5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1',
   'prep_reminder', now(), now() - interval '9 weeks');
select public.anonymize_expired_profiles();
select is((select count(*)::int from public.notification_log where id = '00000000-0000-0000-0000-0000000004a5'), 0,
  'older than eight weeks goes');
select is((select count(*)::int from public.notification_log where id = '00000000-0000-0000-0000-0000000004a1'), 1,
  'newer stays');

update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a3';
update public.members set removed_at = now() - interval '13 months' where id = '00000000-0000-0000-0000-0000000000a3';
select public.anonymize_expired_profiles();
select is((select count(*)::int from public.notification_log where member_id = '00000000-0000-0000-0000-0000000000a3'), 0,
  'a removed kid''s rows go when her profile is anonymized');

insert into public.notification_log (id, household_id, member_id, type, scheduled_for) values
  ('00000000-0000-0000-0000-0000000004a6', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4',
   'after_dinner', now());
insert into public.consents (household_id, kind, granted_by, text_version, member_id, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', 'parental', 'a0000000-0000-0000-0000-00000000000a', 'test-v1',
   '00000000-0000-0000-0000-0000000000a4', now() - interval '40 days', now() - interval '31 days');
select public.anonymize_expired_profiles();
select is((select count(*)::int from public.notification_log where member_id = '00000000-0000-0000-0000-0000000000a4'), 0,
  'and a kid''s whose consent was withdrawn');

insert into public.notification_log (id, household_id, member_id, type, scheduled_for) values
  ('00000000-0000-0000-0000-0000000004a7', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5',
   'after_dinner', now());
select is(public.delete_account_data('e0000000-0000-0000-0000-00000000000e'), 'profile_anonymized', 'a member deletes her account');
select is((select count(*)::int from public.notification_log where member_id = '00000000-0000-0000-0000-0000000000a5'), 0,
  'and what was sent to her goes');

insert into public.members (id, household_id, first_name, role, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Ivy', 'member', 'kid',
   'e0000000-0000-0000-0000-00000000000e');
insert into public.notification_log (id, household_id, member_id, type, scheduled_for) values
  ('00000000-0000-0000-0000-0000000004a8', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a6',
   'after_dinner', now());
select is(public.delete_account_data('e0000000-0000-0000-0000-00000000000e'), 'unlinked', 'a kid deletes her account');
select is((select count(*)::int from public.notification_log where member_id = '00000000-0000-0000-0000-0000000000a6'), 0,
  'and hers goes too, though her profile stays');

-- Racing an erase. One connection can't race, so these pin the locks; a two-connection run is in the PR's notes.
create function pg_temp.before(fn regprocedure, first text, second text) returns boolean language sql as $$
  select position(first in lower(pg_get_functiondef(fn))) between 1 and position(second in lower(pg_get_functiondef(fn))) - 1;
$$;
select ok(pg_temp.before('public.erase_household(uuid)', 'from public.members where household_id = target for update',
                         'delete from public.notification_log'),
  'an erase holds the members before it empties the log, so a late insert waits and then fails');
select ok(pg_temp.before('public.erase_household(uuid)', 'from public.households where id = target for update',
                         'delete from public.notification_log'), 'and the household');
select ok(pg_temp.before('public.delete_account_data(uuid)', 'where user_id = target_user for update',
                         'delete from public.notification_log'), 'deleting an account holds the profile first');
select ok(position('for key share' in lower(pg_get_functiondef('public.record_notifications(uuid, jsonb)'::regprocedure))) > 0,
  'and writing checks the profile again under a lock, so it sees what they did');

-- After the account's gone, its device can't log.
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.record_notifications('00000000-0000-0000-0000-0000000000a0', jsonb_build_array(
    pg_temp.entry(gen_random_uuid()))) $$, '42501', null, 'a device whose profile was unlinked can''t write');
reset role;

select is(public.delete_account_data('c0000000-0000-0000-0000-00000000000c'), 'household_deleted', 'an owner deletes her account');
select is((select count(*)::int from public.notification_log where household_id = '00000000-0000-0000-0000-0000000000b0'), 0,
  'and the household''s log goes with it');

select * from finish();
rollback;
