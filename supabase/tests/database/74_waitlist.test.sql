-- Founding-family waitlist (#34): nobody signed in or not can read or write it; only the server's functions do.
begin;
select plan(39);

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
-- Joins, and when it says send, marks it sent the way the function does after Resend answers.
create function pg_temp.join_and_send(p_email text, p_ip text, p_token text) returns text language plpgsql as $$
declare j jsonb;
begin
  j := public.waitlist_join(p_email, null, p_ip);
  if j->>'outcome' = 'send' then
    perform public.waitlist_mark_sent((j->>'signup_id')::uuid, (j->>'attempt_id')::bigint, p_token, null);
  end if;
  return j->>'outcome';
end;
$$;

select pg_temp.as_server();
select is(public.waitlist_join('Pat@Example.com', ' Pat ', 'ip-a')->>'outcome', 'send', 'a new signup is told to send');
select is((select status from public.waitlist_signups where email = 'pat@example.com'), 'pending', 'and is pending (email matches any case)');
select is((select first_name from public.waitlist_signups where email = 'pat@example.com'), 'Pat', 'with the trimmed name');
select is((select token_hash from public.waitlist_signups), null, 'but has no token until an email has gone out');
select is(public.waitlist_join('pat@example.com', null, 'ip-a')->>'outcome', 'skip', 'a second signup right behind it is skipped: the send is reserved');
select is((select count(*)::int from public.waitlist_attempts where reserved_at is not null), 1, 'only one attempt holds a reservation');
select public.waitlist_release_send((select id from public.waitlist_signups), (select id from public.waitlist_attempts where reserved_at is not null));
select is(public.waitlist_join('pat@example.com', null, 'ip-a')->>'outcome', 'send', 'once the failed send is released, a retry sends');

select public.waitlist_mark_sent((select id from public.waitlist_signups), (select max(id) from public.waitlist_attempts), 'hash-1', null);
select is((select token_hash from public.waitlist_signups), 'hash-1', 'marking it sent stores the token hash');
select is((select count(*)::int from public.waitlist_attempts where sent), 1, 'and counts the send');
select is(public.waitlist_join('pat@example.com', null, 'ip-a')->>'outcome', 'skip', 'a try within 10 minutes of a send does nothing');
update public.waitlist_signups set token_sent_at = now() - interval '11 minutes', send_reserved_at = null;
select is(pg_temp.join_and_send('pat@example.com', 'ip-a', 'hash-2'), 'send', 'later, a fresh link goes out');
select is(public.waitlist_confirm('hash-1'), 'invalid', 'the old token no longer works');
select is(public.waitlist_confirm('hash-2'), 'confirmed', 'the current one confirms');
select is(public.waitlist_confirm('hash-2'), 'confirmed', 'using it twice is fine');
select ok((select confirmed_at is not null from public.waitlist_signups), 'confirmation is dated');
select is(public.waitlist_join('pat@example.com', null, 'ip-c')->>'outcome', 'skip', 'a confirmed email is never re-sent');

-- Unsubscribing deletes everything about the person.
select public.waitlist_unsubscribe((select id from public.waitlist_signups));
select is((select count(*)::int from public.waitlist_signups), 0, 'unsubscribing deletes the row, email and name with it');
select is(public.waitlist_confirm('hash-2'), 'invalid', 'and the old link is dead');
select is(pg_temp.join_and_send('pat@example.com', 'ip-b', 'hash-3'), 'send', 'signing up again starts over');
select is((select status from public.waitlist_signups), 'pending', 'as pending');
select lives_ok($$ select public.waitlist_unsubscribe('00000000-0000-0000-0000-000000000001') $$, 'unsubscribing twice is harmless');

-- Five attempts an hour from one address: ip-a has made five.
select is(public.waitlist_join('b@example.com', null, 'ip-a')->>'outcome', 'rate_limited', 'the sixth attempt in an hour is refused');
select is((select count(*)::int from public.waitlist_signups where email = 'b@example.com'), 0, 'and stores nothing');

-- One address hammering doesn't lock out another.
select count(*) from (select public.waitlist_join('h' || n || '@example.com', null, 'ip-hammer') from generate_series(1, 30) n) s;
select is(public.waitlist_join('e@example.com', null, 'ip-other')->>'outcome', 'send', 'a different address still signs up');

-- The overall cap counts real sends only.
insert into public.waitlist_attempts (ip_hash, sent) select 'f-' || n, false from generate_series(1, 300) n;
select is(public.waitlist_join('f@example.com', null, 'ip-new')->>'outcome', 'send', 'hundreds of attempts that sent nothing leave the cap alone');
insert into public.waitlist_attempts (ip_hash, reserved_at, sent) select 'g-' || n, now(), true from generate_series(1, 200) n;
select is(public.waitlist_join('d@example.com', null, 'ip-new2')->>'outcome', 'rate_limited', 'but 200 sends in the hour fill it');
select is((select count(*)::int from public.waitlist_signups where email = 'd@example.com'), 0, 'and stores nothing');
update public.waitlist_attempts set sent = false where ip_hash like 'g-%';
select is(public.waitlist_join('d@example.com', null, 'ip-new2')->>'outcome', 'rate_limited', 'reservations that are still in flight count toward it too');
update public.waitlist_attempts set reserved_at = now() - interval '10 minutes' where ip_hash like 'g-%';
select is(public.waitlist_join('d@example.com', null, 'ip-new3')->>'outcome', 'send', 'but a reservation nobody confirmed lapses after 5 minutes');

-- Expiry and pruning.
insert into public.waitlist_attempts (ip_hash, attempted_at) values ('ip-old', now() - interval '2 days');
insert into public.waitlist_signups (email, status, token_hash, token_sent_at, created_at) values
  ('old@example.com', 'pending', 'h-old', now() - interval '8 days', now() - interval '9 days'),
  ('stale@example.com', 'pending', 'h-stale', now() - interval '31 days', now() - interval '60 days'),
  ('unsent@example.com', 'pending', null, null, now() - interval '31 days'),
  ('rejoined@example.com', 'pending', 'h-re', now() - interval '1 day', now() - interval '40 days'),
  ('c@example.com', 'confirmed', null, now() - interval '40 days', now() - interval '40 days');
select is(public.waitlist_confirm('h-old'), 'expired', 'a link older than 7 days is expired');
select public.prune_waitlist();
select is((select count(*)::int from public.waitlist_signups where email = 'stale@example.com'), 0, 'pending 30 days after its last email is pruned');
select is((select count(*)::int from public.waitlist_signups where email = 'unsent@example.com'), 0, 'so is one that never got an email, 30 days after it was made');
select is((select count(*)::int from public.waitlist_signups where email = 'rejoined@example.com'), 1, 'but one that came back recently stays');
select is((select count(*)::int from public.waitlist_signups where email = 'c@example.com'), 1, 'and confirmed ones');
select is((select count(*)::int from public.waitlist_attempts where attempted_at < now() - interval '1 day'), 0, 'old attempts are pruned');

select pg_temp.as_anon();
select throws_ok($$ select * from public.waitlist_signups $$, '42501', null, 'anon can''t read signups');
select throws_ok($$ insert into public.waitlist_signups (email) values ('x@example.com') $$, '42501', null, 'or write one');
select pg_temp.as_user();
select throws_ok($$ select * from public.waitlist_signups $$, '42501', null, 'a signed-in user can''t read signups');
select throws_ok($$ select public.waitlist_join('x@example.com', null, 'ip-9') $$, '42501', null, 'or call the functions');

select * from finish();
rollback;
