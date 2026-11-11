-- Finished shopping trips (#260): recorded once per trip by a member through record_shopping_trip, read only by the
-- household, counted by internal.metrics only from 5 households, pruned after 13 months.
begin;
select plan(19);

create function pg_temp.id(kind int, i int) returns uuid language sql immutable as $$
  select format('00000000-0000-0000-%s-%s', lpad(kind::text, 4, '0'), lpad(i::text, 12, '0'))::uuid;
$$;
create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.week(result jsonb, monday date) returns jsonb language sql as $$
  select e from jsonb_array_elements(result -> 'weeks') e where e ->> 'week' = monday::text;
$$;

-- Kinds of id: 1 household, 2 account, 3 planner, 4 trip, 5 Ben (household 1's second adult).
-- Seven households on New York time; 7 is a sample family.
insert into auth.users (id, email, aud, role)
select pg_temp.id(2, i), format('planner%s@example.com', i), 'authenticated', 'authenticated'
from generate_series(1, 7) i
union all select pg_temp.id(5, 1), 'ben@example.com', 'authenticated', 'authenticated';

insert into public.households (id, name, owner, settings)
select pg_temp.id(1, i), format('Household %s', i), pg_temp.id(2, i),
       case when i = 7 then '{"sample": true}' else '{}' end::jsonb
from generate_series(1, 7) i;

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id)
select pg_temp.id(3, i), pg_temp.id(1, i), 'Pat', 'planner'::public.member_role, true, 'adult'::public.age_group,
       pg_temp.id(2, i)
from generate_series(1, 7) i
union all select pg_temp.id(5, 1), pg_temp.id(1, 1), 'Ben', 'member', true, 'adult', pg_temp.id(5, 1);

select has_table('public', 'shopping_trips', 'finished trips have a table');
select is((select relrowsecurity from pg_class where oid = 'public.shopping_trips'::regclass), true, 'with RLS on');

-- Recording ------------------------------------------------------------------------------------------------------------

select pg_temp.as_user(pg_temp.id(2, 1));
select lives_ok(format($$ select public.record_shopping_trip(%L, %L, now() - interval '1 hour') $$,
                       pg_temp.id(4, 1), pg_temp.id(1, 1)),
  'a member records a finished trip');
select lives_ok(format($$ select public.record_shopping_trip(%L, %L, now()) $$, pg_temp.id(4, 1), pg_temp.id(1, 1)),
  'sending the same trip again is fine');
select throws_ok(format($$ select public.record_shopping_trip(%L, %L, now()) $$, pg_temp.id(4, 2), pg_temp.id(1, 2)),
  '42501', null, 'but not for another household');
select throws_ok(format($$ insert into public.shopping_trips (id, household_id, finished_at) values (%L, %L, now()) $$,
                        pg_temp.id(4, 3), pg_temp.id(1, 1)),
  '42501', null, 'nobody writes the table directly');
select lives_ok(format($$ select public.record_shopping_trip(%L, %L, now() + interval '2 days') $$,
                       pg_temp.id(4, 4), pg_temp.id(1, 1)),
  'a phone clock in the future is accepted');
select lives_ok(format($$ select public.record_shopping_trip(%L, %L, now() - interval '90 days') $$,
                       pg_temp.id(4, 5), pg_temp.id(1, 1)),
  'and one far in the past');

select pg_temp.as_admin();
select is((select count(*)::int from public.shopping_trips where id = pg_temp.id(4, 1)), 1, 'a resend records nothing more');
select is((select finished_at from public.shopping_trips where id = pg_temp.id(4, 1)), now() - interval '1 hour',
  'the first send''s time stands');
select is((select finished_at from public.shopping_trips where id = pg_temp.id(4, 4)), now(), 'a future time becomes now');
select is((select finished_at from public.shopping_trips where id = pg_temp.id(4, 5)), now() - interval '30 days',
  'a time over 30 days old becomes 30 days ago');

-- Reading --------------------------------------------------------------------------------------------------------------

select pg_temp.as_user(pg_temp.id(5, 1));  -- Ben, same household
select is((select count(*)::int from public.shopping_trips), 3, 'the household reads its trips');
select pg_temp.as_user(pg_temp.id(2, 2));  -- another household
select is((select count(*)::int from public.shopping_trips), 0, 'another household reads none');
select pg_temp.as_user(pg_temp.id(2, 1));
select is((select jsonb_array_length(public.export_household(pg_temp.id(1, 1)) -> 'shopping_trips')), 3,
  'the export includes them');

select set_config('request.jwt.claims', '{"role": "anon"}', true), set_config('role', 'anon', true);
select throws_ok(format($$ select public.record_shopping_trip(%L, %L, now()) $$, pg_temp.id(4, 6), pg_temp.id(1, 1)),
  '42501', null, 'signed out, nothing is recorded');

-- Metrics: trips in the week of Monday, August 10, from households 1 to 4 plus the sample family, then 5 joins the
-- week of August 17 with households 1 to 4 again.

select pg_temp.as_admin();
delete from public.shopping_trips;
insert into public.shopping_trips (id, household_id, finished_at)
select gen_random_uuid(), pg_temp.id(1, i), '2026-08-12 18:00-04'::timestamptz
from generate_series(1, 4) i
union all select gen_random_uuid(), pg_temp.id(1, 7), '2026-08-12 18:00-04'
union all select gen_random_uuid(), pg_temp.id(1, i), '2026-08-19 18:00-04'
from generate_series(1, 5) i
union all select gen_random_uuid(), pg_temp.id(1, 1), '2026-08-20 18:00-04'
-- Sunday night in New York is still the week of August 17, though it's Monday in UTC.
union all select gen_random_uuid(), pg_temp.id(1, 2), '2026-08-23 22:00-04';

create temp table result as select internal.metrics('2026-08-10', '2026-08-17') as m;
select is((select pg_temp.week(m, '2026-08-10') -> 'shopping_trips' from result), 'null'::jsonb,
  'four households (the sample family doesn''t count) is too few to show');
select is((select pg_temp.week(m, '2026-08-17') -> 'shopping_trips' from result), '7'::jsonb,
  'five households'' trips are counted, by the household''s week');

insert into public.shopping_trips (id, household_id, finished_at)
values (gen_random_uuid(), pg_temp.id(1, 1), now() - interval '14 months');
select public.prune_shopping_trips();
select is((select count(*)::int from public.shopping_trips where finished_at < now() - interval '13 months'), 0,
  'the daily job drops trips over 13 months old');

select * from finish();
rollback;
