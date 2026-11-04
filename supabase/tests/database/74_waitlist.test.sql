-- Founding-family waitlist (#34): nobody signed in or not can read or write it; only the server's functions do.
begin;
select plan(26);

create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true), set_config('role', 'anon', true);
$$;
create function pg_temp.as_user() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_server() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true),
         set_config('role', 'service_role', true);
$$;

select pg_temp.as_server();
select is(public.waitlist_join('Pat@Example.com', ' Pat ', 'hash-1', 'ip-1'), 'send', 'a new signup sends the email');
select is((select status from public.waitlist_signups where email = 'pat@example.com'), 'pending', 'and is pending (email matches any case)');
select is((select first_name from public.waitlist_signups where email = 'pat@example.com'), 'Pat', 'with the trimmed name');
select is(public.waitlist_join('pat@example.com', null, 'hash-2', 'ip-1'), 'skip', 'a second try within 10 minutes sends nothing');
update public.waitlist_signups set token_sent_at = now() - interval '11 minutes';
select is(public.waitlist_join('pat@example.com', null, 'hash-3', 'ip-1'), 'send', 'later, a fresh link goes out');
select is((select token_hash from public.waitlist_signups), 'hash-3', 'replacing the token');
select is(public.waitlist_confirm('hash-2'), 'invalid', 'an old token no longer works');
select is(public.waitlist_confirm('hash-3'), 'confirmed', 'the current one confirms');
select is(public.waitlist_confirm('hash-3'), 'confirmed', 'opening it twice is fine');
select ok((select confirmed_at is not null from public.waitlist_signups), 'confirmation is dated');
select is(public.waitlist_join('pat@example.com', null, 'hash-4', 'ip-1'), 'skip', 'a confirmed email is never re-sent');

select is(public.waitlist_unsubscribe(public.waitlist_id_for('pat@example.com')), true, 'unsubscribing works');
select is((select first_name from public.waitlist_signups), null, 'and drops the name');
select is(public.waitlist_confirm('hash-3'), 'invalid', 'the old link is dead');

-- Five attempts an hour from one address: four are already on ip-1.
select is(public.waitlist_join('a@example.com', null, 'h-a', 'ip-1'), 'send', 'the fifth attempt in an hour is fine');
select is(public.waitlist_join('b@example.com', null, 'h-b', 'ip-1'), 'rate_limited', 'the sixth is refused');
select is((select count(*)::int from public.waitlist_signups where email = 'b@example.com'), 0, 'and stores nothing');

-- The overall cap: 200 attempts from other addresses fill the hour, whoever asks next is refused.
insert into public.waitlist_attempts (ip_hash) select 'g-' || n from generate_series(1, 200) n;
select is(public.waitlist_join('d@example.com', null, 'h-d', 'ip-new'), 'rate_limited', 'a fresh address is refused once the hour is full');
select is((select count(*)::int from public.waitlist_signups where email = 'd@example.com'), 0, 'and stores nothing');

insert into public.waitlist_signups (email, status, token_hash, token_sent_at, created_at)
values ('old@example.com', 'pending', 'h-old', now() - interval '8 days', now() - interval '31 days'),
       ('c@example.com', 'confirmed', null, now() - interval '40 days', now() - interval '40 days');
select is(public.waitlist_confirm('h-old'), 'expired', 'a link older than 7 days is expired');
select public.prune_waitlist();
select is((select count(*)::int from public.waitlist_signups where email = 'old@example.com'), 0, 'pending over 30 days is pruned');
select is((select count(*)::int from public.waitlist_signups where email = 'c@example.com'), 1, 'confirmed ones are kept');

select pg_temp.as_anon();
select throws_ok($$ select * from public.waitlist_signups $$, '42501', null, 'anon can''t read signups');
select throws_ok($$ insert into public.waitlist_signups (email) values ('x@example.com') $$, '42501', null, 'or write one');
select pg_temp.as_user();
select throws_ok($$ select * from public.waitlist_signups $$, '42501', null, 'a signed-in user can''t read signups');
select throws_ok($$ select public.waitlist_join('x@example.com', null, 'h', 'ip-9') $$, '42501', null,
  'or call the functions');

select * from finish();
rollback;
