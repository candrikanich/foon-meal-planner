-- The household AI queue (#58): members submit jobs as themselves; a job is claimed once, re-claimed only after its lease
-- lapses, never once it's expired, and finished only by whoever holds the claim; another household can't read, claim or
-- finish one.
begin;
select plan(38);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');

select has_table('public', 'ai_jobs', 'AI jobs are a table');
select ok((select relrowsecurity from pg_class where oid = 'public.ai_jobs'::regclass), 'with row-level security');
select ok((select bool_and(not prosecdef and proconfig @> array['search_path=""']) from pg_proc
           where proname in ('submit_ai_job', 'claim_ai_job', 'complete_ai_job', 'fail_ai_job')),
  'submit, claim, complete and fail run as the caller, with an empty search_path');
select ok(not has_function_privilege('anon', 'public.claim_ai_job(text[], uuid)', 'execute')
          and not has_function_privilege('anon', 'public.complete_ai_job(uuid, jsonb)', 'execute')
          and not has_function_privilege('anon', 'public.fail_ai_job(uuid, text)', 'execute'),
  'anon can''t claim or finish a job');

-- Submitting --------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
insert into public.ai_jobs (id, household_id, kind, payload, created_by) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a0', 'echo', '{"text":"one"}',
   '00000000-0000-0000-0000-0000000000a1');
select is((select status from public.ai_jobs where id = '00000000-0000-0000-0000-0000000005a1'), 'queued',
  'a submitted job is queued');
select ok((select expires_at = created_at + interval '3 days' from public.ai_jobs
           where id = '00000000-0000-0000-0000-0000000005a1'), 'and expires in 3 days');
select throws_ok(
  $$ insert into public.ai_jobs (household_id, kind, payload, created_by) values
       ('00000000-0000-0000-0000-0000000000a0', 'echo', '{}', '00000000-0000-0000-0000-0000000000a2') $$,
  '42501', null, 'a job can''t be submitted in someone else''s name');
select throws_ok(
  $$ insert into public.ai_jobs (household_id, kind, payload, created_by) values
       ('00000000-0000-0000-0000-0000000000b0', 'echo', '{}', '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'or into another household');
select throws_ok(
  $$ insert into public.ai_jobs (household_id, kind, payload, created_by) values
       ('00000000-0000-0000-0000-0000000000a0', 'mystery', '{}', '00000000-0000-0000-0000-0000000000a1') $$,
  '23514', null, 'only a known kind is queued');
select throws_ok(
  $$ insert into public.ai_jobs (household_id, kind, payload, created_by, status) values
       ('00000000-0000-0000-0000-0000000000a0', 'echo', '{}', '00000000-0000-0000-0000-0000000000a1', 'done') $$,
  '42501', null, 'a job starts queued: its status isn''t the submitter''s to set');
select throws_ok(
  $$ update public.ai_jobs set status = 'done', result = '{}' where id = '00000000-0000-0000-0000-0000000005a1' $$,
  '42501', null, 'nobody finishes a job they haven''t claimed');

-- Another household reads, claims and finishes nothing ---------------------------------------------------------------------
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.ai_jobs $$, 'another household reads no jobs');
select is_empty($$ select * from public.claim_ai_job(array['echo']) $$, 'or claims one');
select is_empty($$ select * from public.claim_ai_job(array['echo'], '00000000-0000-0000-0000-0000000005a1') $$,
  'even by its id');
select throws_ok($$ select public.complete_ai_job('00000000-0000-0000-0000-0000000005a1', '{"text":"hacked"}') $$,
  '42501', null, 'or completes one');
select throws_ok($$ select public.fail_ai_job('00000000-0000-0000-0000-0000000005a1', 'no') $$,
  '42501', null, 'or fails one');

-- Claimed once ---------------------------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((select claimed_by from public.claim_ai_job(array['echo'])), '00000000-0000-0000-0000-0000000000a2'::uuid,
  'Bob claims the family''s job');
select ok((select lease_expires_at = claimed_at + interval '5 minutes' from public.ai_jobs
           where id = '00000000-0000-0000-0000-0000000005a1'), 'with a 5-minute lease');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is_empty($$ select * from public.claim_ai_job(array['echo']) $$, 'a claimed job isn''t claimed again');
select is_empty($$ select * from public.claim_ai_job(array['echo'], '00000000-0000-0000-0000-0000000005a1') $$,
  'not even by its submitter');
select throws_ok(
  $$ update public.ai_jobs set status = 'claimed', claimed_by = '00000000-0000-0000-0000-0000000000a1'
     where id = '00000000-0000-0000-0000-0000000005a1' $$,
  '55P03', null, 'nor taken over by writing to it');
select throws_ok($$ select public.complete_ai_job('00000000-0000-0000-0000-0000000005a1', '{"text":"mine"}') $$,
  '42501', null, 'only the member holding the claim completes it');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is((public.complete_ai_job('00000000-0000-0000-0000-0000000005a1', '{"text":"one"}')).status, 'done',
  'Bob completes it');
select throws_ok($$ select public.fail_ai_job('00000000-0000-0000-0000-0000000005a1', 'late') $$,
  '42501', null, 'a finished job stays finished');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select result ->> 'text' from public.ai_jobs where id = '00000000-0000-0000-0000-0000000005a1'), 'one',
  'the family reads the result');

-- A lapsed lease, an expired job --------------------------------------------------------------------------------------------
reset role;
insert into public.ai_jobs (id, household_id, kind, payload, created_by, status, claimed_by, claimed_at, lease_expires_at,
                            created_at) values
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a0', 'echo', '{"text":"two"}',
   '00000000-0000-0000-0000-0000000000a1', 'claimed', '00000000-0000-0000-0000-0000000000a2',
   now() - interval '10 minutes', now() - interval '5 minutes', now() - interval '1 hour');
insert into public.ai_jobs (id, household_id, kind, payload, created_by, created_at, expires_at) values
  ('00000000-0000-0000-0000-0000000005a3', '00000000-0000-0000-0000-0000000000a0', 'echo', '{"text":"three"}',
   '00000000-0000-0000-0000-0000000000a1', now() - interval '4 days', now() - interval '1 day');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select id from public.claim_ai_job(array['echo'])), '00000000-0000-0000-0000-0000000005a2'::uuid,
  'a claim whose lease lapsed is claimed again, and the expired job before it is skipped');
select is((select claimed_by from public.ai_jobs where id = '00000000-0000-0000-0000-0000000005a2'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'Alice holds it now');
select is_empty($$ select * from public.claim_ai_job(array['echo'], '00000000-0000-0000-0000-0000000005a3') $$,
  'an expired job can''t be claimed, even by its id');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.complete_ai_job('00000000-0000-0000-0000-0000000005a2', '{"text":"stale"}') $$,
  '42501', null, 'the lapsed claimer can''t complete it');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((public.fail_ai_job('00000000-0000-0000-0000-0000000005a2', 'timed out')).error, 'timed out',
  'the claimer can fail it, and the reason is kept');

select throws_ok($$ select public.expire_ai_jobs() $$, '42501', null, 'clients don''t run the expiry');
reset role;
select public.expire_ai_jobs();
select is((select status from public.ai_jobs where id = '00000000-0000-0000-0000-0000000005a3'), 'expired',
  'the hourly expiry marks the job no one claimed in time');
select is((select status from public.ai_jobs where id = '00000000-0000-0000-0000-0000000005a1'), 'done',
  'and leaves the finished ones');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'ai_jobs'), 3,
  'the export holds the household''s jobs');
select is((public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'ai_jobs' -> 0 ->> 'household_id'), null,
  'without the household id');
reset role;

-- Submitting through the app's call, as yourself ------------------------------------------------------------------------
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((public.submit_ai_job('00000000-0000-0000-0000-0000000000b0', 'echo', '{"text":"paella"}')).created_by,
  '00000000-0000-0000-0000-0000000000c1'::uuid, 'submit_ai_job queues a job in the caller''s name');
select throws_ok($$ select public.submit_ai_job('00000000-0000-0000-0000-0000000000a0', 'echo', '{}') $$,
  '42501', null, 'and only in their own household');
select is((select payload ->> 'text' from public.claim_ai_job(array['echo'])), 'paella',
  'a claim takes only the caller''s household''s jobs');
reset role;

select * from finish();
rollback;
