-- Recipe tidy-up (#59): `recipe` is a kind the queue takes; only a planner's device claims, completes or fails one; the
-- recipe lines in a job's payload go once it's done, failed or expired; and a result is saved into a dish only if nobody saved
-- the dish since it was read. Another household still reads nothing.
begin;
select plan(19);

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
insert into public.meals (id, household_id, name, servings) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000a0', 'CHILI!!', 4);

-- Submitting -------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select set_config('test.done', (public.submit_ai_job('00000000-0000-0000-0000-0000000000a0', 'recipe',
  '{"text": "Chili\nIngredients:\n2 lb ground beef", "source_url": "https://www.instagram.com/p/abc"}')).id::text, true);
select set_config('test.failed', (public.submit_ai_job('00000000-0000-0000-0000-0000000000a0', 'recipe',
  '{"text": "Soup\nIngredients:\n1 onion"}')).id::text, true);
select is((select kind from public.ai_jobs where id = current_setting('test.done')::uuid), 'recipe',
  'a recipe job is queued');
select throws_ok($$ select public.submit_ai_job('00000000-0000-0000-0000-0000000000a0', 'recipes', '{}') $$,
  '23514', null, 'an unknown kind still isn''t');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.ai_jobs where kind = 'recipe' $$, 'another household reads no recipe jobs');
select is_empty($$ select * from public.claim_ai_job(array['recipe']) $$, 'or claims one');

-- Only a planner's device works one --------------------------------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select is_empty($$ select * from public.claim_ai_job(array['recipe']) $$, 'a member can''t claim a recipe job');
select is_empty($$ select * from public.claim_ai_job(array['recipe'], current_setting('test.done')::uuid) $$,
  'not even by its id');
select throws_ok(
  $$ update public.ai_jobs set status = 'claimed', claimed_by = '00000000-0000-0000-0000-0000000000a2'
     where id = current_setting('test.done')::uuid $$,
  '42501', null, 'or by writing to it');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select payload ->> 'text' from public.claim_ai_job(array['recipe'], current_setting('test.done')::uuid)),
  E'Chili\nIngredients:\n2 lb ground beef', 'a planner''s device claims it and gets the lines to run');
select is((select payload ->> 'text' from public.ai_jobs where id = current_setting('test.failed')::uuid),
  E'Soup\nIngredients:\n1 onion', 'a job nobody''s run yet keeps its lines');

-- Finishing empties the payload --------------------------------------------------------------------------------------------
select is((public.complete_ai_job(current_setting('test.done')::uuid,
  '{"name": "Chili", "ingredients": ["2 lb ground beef"], "steps": [], "prepSteps": []}')).payload, '{}'::jsonb,
  'a done job no longer holds the recipe lines');
select is((select result ->> 'name' from public.ai_jobs where id = current_setting('test.done')::uuid), 'Chili',
  'but the family reads its result');

select is((select id from public.claim_ai_job(array['recipe'], current_setting('test.failed')::uuid)),
  current_setting('test.failed')::uuid, 'the planner claims the other');
select is((public.fail_ai_job(current_setting('test.failed')::uuid, 'timed out')).payload, '{}'::jsonb,
  'a failed job no longer holds them either');

-- Expiring empties it too ------------------------------------------------------------------------------------------------
reset role;
insert into public.ai_jobs (id, household_id, kind, payload, created_by, created_at, expires_at) values
  ('00000000-0000-0000-0000-0000000006a3', '00000000-0000-0000-0000-0000000000a0', 'recipe', '{"text": "Stew"}',
   '00000000-0000-0000-0000-0000000000a1', now() - interval '4 days', now() - interval '1 day');
select public.expire_ai_jobs();
select is((select payload from public.ai_jobs where id = '00000000-0000-0000-0000-0000000006a3'), '{}'::jsonb,
  'nor does an expired one');

-- Saving a result only over an unchanged dish ---------------------------------------------------------------------------
select set_config('test.version', (select updated_at::text from public.meals where id = '00000000-0000-0000-0000-0000000007a1'),
  true);
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$ select public.save_meal_if_unchanged('00000000-0000-0000-0000-0000000007a1', now() - interval '1 day', 'Chili',
       4::smallint, '{}', '{}', null, null, '[]'::jsonb) $$,
  '40001', null, 'a dish saved since it was read isn''t saved over');
select is((select name from public.meals where id = '00000000-0000-0000-0000-0000000007a1'), 'CHILI!!', 'and keeps its name');
select is((public.save_meal_if_unchanged('00000000-0000-0000-0000-0000000007a1',
  current_setting('test.version')::timestamptz, 'Chili', 4::smallint, '{}', '{}', null, null, '[]'::jsonb)).name, 'Chili',
  'an unchanged dish takes the result');
select throws_ok(
  $$ select public.save_meal_if_unchanged('00000000-0000-0000-0000-0000000009a9', now(), 'Chili', 4::smallint, '{}', '{}',
       null, null, '[]'::jsonb) $$,
  'P0002', null, 'a dish that''s gone says so');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$ select public.save_meal_if_unchanged('00000000-0000-0000-0000-0000000007a1',
       (select updated_at from public.meals where id = '00000000-0000-0000-0000-0000000007a1'), 'Mine', 4::smallint, '{}',
       '{}', null, null, '[]'::jsonb) $$,
  '42501', null, 'and a member can''t save one');
reset role;

select * from finish();
rollback;
