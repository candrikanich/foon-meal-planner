-- Recipe link import is capped at 30 a day per account (#116), counted before the fetch, and one account's count never
-- touches or shows another's.
begin;
select plan(13);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated');

select ok((select relrowsecurity from pg_class where oid = 'public.import_usage'::regclass), 'the counter has RLS on');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');

select is((select count(*)::int from generate_series(1, 30) where public.claim_import_slot()), 30,
  'the first 30 imports of the day each get a slot');
select is(public.claim_import_slot(), false, 'the 31st is over the cap');
select is(public.claim_import_slot(), false, 'and stays refused');

select throws_ok($$ select * from public.import_usage $$, '42501', null, 'no one reads the counter directly');
select throws_ok($$ update public.import_usage set imports = 1 $$, '42501', null, 'or resets it');
select throws_ok($$ insert into public.import_usage (user_id, day, imports) values (auth.uid(), current_date - 1, 1) $$,
  '42501', null, 'or writes it');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');

select is(public.claim_import_slot(), true, 'another account is not held back by the first one''s cap');

reset role;
select is((select imports from public.import_usage where user_id = 'a0000000-0000-0000-0000-00000000000a'), 30,
  'the capped account stays at 30; refused calls do not count');
select is((select imports from public.import_usage where user_id = 'b0000000-0000-0000-0000-00000000000b'), 1,
  'and the other account''s count is its own');

-- A new UTC day starts fresh, and last week's rows are pruned.
update public.import_usage set day = day - 1 where user_id = 'a0000000-0000-0000-0000-00000000000a';
insert into public.import_usage (user_id, day, imports)
  values ('a0000000-0000-0000-0000-00000000000a', (now() at time zone 'utc')::date - 30, 5);
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.claim_import_slot(), true, 'the next day the cap starts over');
reset role;
select is((select count(*)::int from public.import_usage where user_id = 'a0000000-0000-0000-0000-00000000000a'), 2,
  'and rows older than a week are gone');

-- Not signed in: no slot, and anon cannot call it at all.
select set_config('request.jwt.claims', '{"role":"anon"}', true), set_config('role', 'anon', true);
select throws_ok($$ select public.claim_import_slot() $$, '42501', null, 'anon cannot claim a slot');

select * from finish();
rollback;
