-- Forwarded email receipts (#237): only adults see the household's address and add forwarding addresses; only the
-- server confirms a sender and stores a receipt, and only from a confirmed adult's address to a live address; anyone
-- in the family reads and clears a receipt; another household sees none of it; old rows are pruned.
begin;
select plan(64);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true), set_config('role', 'anon', true);
$$;
create function pg_temp.as_server() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true),
         set_config('role', 'service_role', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.h(c text) returns text language sql as $$ select repeat(c, 64) $$;
create function pg_temp.add(address text, token text) returns text language sql as $$
  select public.add_receipt_sender('00000000-0000-0000-0000-0000000000a0', pg_temp.h(address), 'a•••@example.com',
                                   pg_temp.h(token)) ->> 'outcome';
$$;
create function pg_temp.store(token text, sender text, source text, lines text[] default array['BANANAS 0.59'])
returns text language sql as $$
  select public.record_forwarded_receipt(token, pg_temp.h(sender), source, lines);
$$;

-- The Andersons: Alice (owner, adult), Ben (adult), Kim (kid with an account). The Carters: Carol (owner).
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000b1', 'ben@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', false, 'adult',
   'a0000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');

-- The address ----------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select set_config('test.token', public.receipt_inbox_token('00000000-0000-0000-0000-0000000000a0'), true);
select matches(current_setting('test.token'), '^[0-9a-f]{16}$', 'an adult gets the household''s address token');
select is(public.receipt_inbox_token('00000000-0000-0000-0000-0000000000a0'), current_setting('test.token'),
  'asking again gives the same address');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000b1');
select is(public.receipt_inbox_token('00000000-0000-0000-0000-0000000000a0'), current_setting('test.token'),
  'every adult in the household gets the same address');
select is((select count(*)::int from public.receipt_inboxes), 1, 'adults read it');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.receipt_inbox_token('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'a kid can''t get it');
select throws_ok($$ select public.reset_receipt_inbox('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'a kid can''t reset it');
select is((select count(*)::int from public.receipt_inboxes), 0, 'a kid can''t read it');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.receipt_inbox_token('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'another household''s adult can''t get it');
select is((select count(*)::int from public.receipt_inboxes), 0, 'another household can''t read it');
select throws_ok($$ insert into public.receipt_inboxes (household_id, token) values
                      ('00000000-0000-0000-0000-0000000000b0', '0123456789abcdef') $$, '42501', null,
  'nobody writes an address directly');
select pg_temp.as_anon();
select throws_ok($$ select public.receipt_inbox_token('00000000-0000-0000-0000-0000000000a0') $$, '42501', null,
  'signed-out callers can''t ask');

-- Adding a forwarding address ----------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.add('1', '2') $$, '42501', null, 'signed-out callers can''t add one');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ select pg_temp.add('1', '2') $$, '42501', null, 'a kid can''t add one');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select throws_ok($$ select pg_temp.add('1', '2') $$, '42501', null, 'another household''s adult can''t add one here');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.add_receipt_sender('00000000-0000-0000-0000-0000000000a0', 'not-a-hash',
                     'a•••@example.com', pg_temp.h('2')) $$, '22023', null, 'only a sha256 is taken, never an address');
select is(pg_temp.add('1', '2'), 'send', 'an adult adds an address and Foon emails it a link');
select is(pg_temp.add('1', '3'), 'send', 'adding it again sends a new link');
select is((select count(*)::int from public.receipt_senders), 1, 'still one row for that address');
select pg_temp.as_admin();
select is((select confirm_token_hash from public.receipt_senders), pg_temp.h('3'), 'only the newest link works');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000b1');
select is(pg_temp.add('1', '4'), 'taken', 'another adult can''t take over an address waiting for Alice');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.add('1', '5'), 'send', 'a third email');
select is(pg_temp.add('1', '6'), 'send', 'a fourth');
select is(pg_temp.add('1', '7'), 'send', 'a fifth');
select is(pg_temp.add('1', '8'), 'rate_limited', 'no sixth email for one address');
select is(pg_temp.add('b', 'c'), 'send', 'a second address');
select is(pg_temp.add('d', 'e'), 'send', 'a third');
select is(pg_temp.add('f', '9'), 'send', 'a fourth');
select is(pg_temp.add('0', 'a'), 'send', 'a fifth');
select is(pg_temp.add('e', 'f'), 'too_many', 'no sixth address for one adult');
select pg_temp.as_admin();
select set_config('test.waiting', (select id::text from public.receipt_senders where confirm_token_hash = pg_temp.h('c')),
  true);
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
delete from public.receipt_senders where id = current_setting('test.waiting')::uuid;
select is((select count(*)::int from public.receipt_senders), 4, 'an adult removes their own waiting address');
select is(pg_temp.add('b', 'd'), 'send', 'removing a waiting address and adding it again sends a new link');
select is(pg_temp.add('b', '4'), 'rate_limited', 'but no more than 10 links a day for one adult, whatever the address');
select throws_ok($$ select * from public.receipt_sender_emails $$, '42501', null, 'nobody reads the email log');

-- Confirming ---------------------------------------------------------------------------------------------------------
select throws_ok($$ select public.confirm_receipt_sender(pg_temp.h('7')) $$, '42501', null,
  'the app can''t confirm an address; only the emailed link can');
select pg_temp.as_server();
select is(public.confirm_receipt_sender(pg_temp.h('2')), 'unknown', 'an older link no longer works');
select is(public.confirm_receipt_sender('nonsense'), 'unknown', 'nor does a made-up one');
select pg_temp.as_admin();
update public.receipt_senders set confirm_expires_at = now() - interval '1 minute' where confirm_token_hash = pg_temp.h('d');
select pg_temp.as_server();
select is(public.confirm_receipt_sender(pg_temp.h('d')), 'expired', 'a link lasts a day');
select is(public.confirm_receipt_sender(pg_temp.h('7')), 'confirmed', 'the newest link confirms it');
select is(public.confirm_receipt_sender(pg_temp.h('7')), 'unknown', 'a link works once');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(pg_temp.add('1', '1'), 'confirmed', 'adding a confirmed address again sends nothing');

-- Who sees forwarding addresses --------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000b1');
select is((select count(*)::int from public.receipt_senders where confirmed_at is not null), 1,
  'the other adults see who forwards receipts');
select throws_ok($$ select address_hash from public.receipt_senders $$, '42501', null, 'nobody reads the hash');
delete from public.receipt_senders;
select is((select count(*)::int from public.receipt_senders), 5, 'an adult can''t remove someone else''s address');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((select count(*)::int from public.receipt_senders), 0, 'a kid doesn''t see them');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.receipt_senders), 0, 'another household doesn''t see them');

-- Storing a forwarded receipt ----------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select throws_ok($$ select pg_temp.store(current_setting('test.token'), '1', 'email-1') $$, '42501', null,
  'the app can''t store a receipt; only the server can');
select pg_temp.as_server();
select is(pg_temp.store('ffffffffffffffff', '1', 'email-0'), 'unknown_inbox', 'mail to no household is dropped');
select is(pg_temp.store(current_setting('test.token'), 'b', 'email-0'), 'unknown_sender',
  'mail from an address that isn''t confirmed is dropped');
select is(pg_temp.store(current_setting('test.token'), '1', 'email-0', array[repeat('x', 201)]), 'bad_lines',
  'a line over 200 characters is refused');
select is(pg_temp.store(current_setting('test.token'), '1', 'email-1'), 'stored', 'a confirmed adult''s receipt is stored');
select is(pg_temp.store(current_setting('test.token'), '1', 'email-1'), 'duplicate', 'a webhook sent twice stores once');

select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((select lines from public.forwarded_receipts), array['BANANAS 0.59'], 'anyone in the family, a kid too, reads it');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.forwarded_receipts), 0, 'another household can''t read it');
delete from public.forwarded_receipts;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'forwarded_receipts'), 1,
  'the export has the receipt waiting for review');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'receipt_senders'), 5,
  'and the forwarding addresses, as hints');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((select count(*)::int from public.forwarded_receipts), 1, 'another household can''t clear it');
delete from public.forwarded_receipts;
select is((select count(*)::int from public.forwarded_receipts), 0, 'a kid clears it once it''s reviewed');

-- Limits, a reset address, an adult who left, and pruning -------------------------------------------------------------
select pg_temp.as_server();
select is((select count(*)::int from (select pg_temp.store(current_setting('test.token'), '1', 'bulk-' || i) as outcome
                                       from generate_series(1, 21) i) sent where outcome = 'over_limit'), 1,
  'at most 20 receipts a day per household');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select isnt(public.reset_receipt_inbox('00000000-0000-0000-0000-0000000000a0'), current_setting('test.token'),
  'an adult resets the address');
select pg_temp.as_server();
select is(pg_temp.store(current_setting('test.token'), '1', 'email-2'), 'unknown_inbox', 'the old address stops working');
select pg_temp.as_admin();
-- Straight to the row (the member guard keeps an owner from being removed): what matters is the sender check.
set local session_replication_role = replica;
update public.members set status = 'removed', user_id = null where id = '00000000-0000-0000-0000-0000000000a1';
set local session_replication_role = origin;
select pg_temp.as_server();
select is(pg_temp.store((select token from public.receipt_inboxes), '1', 'email-3'), 'unknown_sender',
  'once Alice has left, her address no longer forwards');
select pg_temp.as_admin();
update public.forwarded_receipts set received_at = now() - interval '15 days' where source_id = 'bulk-1';
select public.prune_forwarded_receipts();
select is((select count(*)::int from public.forwarded_receipts where source_id = 'bulk-1'), 0,
  'a receipt nobody reviews goes after 14 days');
select is((select count(*)::int from public.forwarded_receipts), 19, 'newer ones stay');
select is((select count(*)::int from public.receipt_senders), 0, 'the addresses of an adult who left go');

select * from finish();
rollback;
