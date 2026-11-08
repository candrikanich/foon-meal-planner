-- Verifiable parental consent by email plus (#275): only the parental-consent Edge Function's service-role calls write
-- a parental consent, after the parent agreed from email 1 and email 2 went out. Pending, refused, expired, confirmed
-- and withdrawn; the limits; who reads requests; retention.
begin;
select plan(84);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role": "service_role"}', true),
         set_config('role', 'service_role', true);
$$;
create function pg_temp.req(kid uuid) returns public.parental_consent_requests language sql as $$
  select * from public.parental_consent_requests where member_id = kid order by created_at desc, id limit 1;
$$;

-- Household A: Alice (owner, parent), Paul (parent, no email on his account), Grace (adult, not a parent), Kim (kid,
-- claimed). Unclaimed: Nora, Owen, Pia, Quin (kids), Ben (adult). Household B: Carol (owner) and her kid Cal.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a2', '', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a3', 'grace@example.com', 'authenticated', 'authenticated'),
  ('a0000000-0000-0000-0000-0000000000a4', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated'),
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'erin@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, status, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Paul', 'planner', 'adult', true, 'active', 'a0000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Grace', 'planner', 'adult', false, 'active', 'a0000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', 'kid', false, 'active', 'a0000000-0000-0000-0000-0000000000a4'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a6', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a7', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a0', 'Pia', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000a0', 'Quin', 'member', 'kid', false, 'active', null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true, 'active', 'c0000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b0', 'Cal', 'member', 'kid', false, 'active', null);

-- The app can't write a parental consent any more ---------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok(
  $$ insert into public.consents (household_id, member_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'parental', 'parental-invite-v2') $$,
  '42501', null, 'a parent can''t record a kid''s consent from the app');
select lives_ok(
  $$ insert into public.consents (household_id, kind, text_version) values
       ('00000000-0000-0000-0000-0000000000a0', 'allergy_data', 'allergy-data-v2') $$,
  'allergy consent is still given in the app');
select is((select method::text from public.consents where kind = 'allergy_data'), 'in_app',
  'and is recorded as in_app');
select throws_ok(
  $$ insert into public.consents (household_id, kind, text_version, method) values
       ('00000000-0000-0000-0000-0000000000b0', 'allergy_data', 'v1', 'email_plus') $$,
  '42501', null, 'nobody sets the method from the app');
select throws_ok($$ select public.activate_parental_consent(gen_random_uuid(), 'x') $$, '42501', null,
  'activating is for the Edge Function only');
select throws_ok($$ select public.parental_consent_decide('x', 'agree') $$, '42501', null,
  'and so is deciding');
select throws_ok($$ select public.withdraw_parental_consent('x') $$, '42501', null, 'and withdrawing by link');

-- Who can ask -----------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000a5') $$, '42501', null,
  'an adult who isn''t a parent can''t ask');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000a5') $$, '42501', null,
  'nor a parent in another household');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000a6') $$, '22023', null,
  'an adult''s profile needs no parental consent');
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000a4') $$, '22023', null,
  'nor a profile already claimed');

select set_config('test.nora1', public.request_parental_consent('00000000-0000-0000-0000-0000000000a5')::text, true);
select is(current_setting('test.nora1')::jsonb - 'request_id' - 'send_id',
  '{"outcome": "send", "email": "alice@example.com", "email_source": "account", "first_name": "Nora"}'::jsonb,
  'a parent asks: the email goes to the address on their own sign-in');
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a5') ->> 'outcome', 'rate_limited',
  'a second ask while that email is being sent waits');
select pg_temp.as_admin();
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a5')).status, 'pending', 'the request is pending');

select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul, no email on his account
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a7'), '{"outcome": "no_email"}'::jsonb,
  'an account with no email gets no_email');
select throws_ok($$ select public.request_parental_consent('00000000-0000-0000-0000-0000000000a7', 'not an email') $$,
  '22000', null, 'a typed address must look like one');
select set_config('test.owen1',
  public.request_parental_consent('00000000-0000-0000-0000-0000000000a7', ' Paul@Example.com ')::text, true);
select is(current_setting('test.owen1')::jsonb ->> 'email', 'paul@example.com', 'a typed address is used');
select is(current_setting('test.owen1')::jsonb ->> 'email_source', 'typed', 'and says so');

-- Email 1 sent, and sent again ------------------------------------------------------------------------------------------
select pg_temp.as_service();
select public.parental_consent_mark_sent((current_setting('test.nora1')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.nora1')::jsonb ->> 'send_id')::bigint, 'hash-n1', 'parental-invite-v3');
select public.parental_consent_mark_sent((current_setting('test.owen1')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.owen1')::jsonb ->> 'send_id')::bigint, 'hash-o1', 'parental-invite-v3');
select is(public.parental_consent_lookup('hash-n1') - 'expires_at', '{"outcome": "pending", "first_name": "Nora"}'::jsonb,
  'the link''s page can show whom it''s for');
select ok((public.parental_consent_lookup('hash-n1') ->> 'expires_at')::timestamptz
          between now() + interval '7 days' - interval '1 minute' and now() + interval '7 days',
  'the link works for 7 days');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000a5') ->> 'outcome', 'rate_limited',
  'Send again waits 10 minutes');
select pg_temp.as_admin();
update public.parental_consent_requests set token_sent_at = now() - interval '11 minutes'
where member_id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select set_config('test.nora2', public.request_parental_consent('00000000-0000-0000-0000-0000000000a5')::text, true);
select is(current_setting('test.nora2')::jsonb ->> 'request_id', current_setting('test.nora1')::jsonb ->> 'request_id',
  'Send again reuses the request');
select pg_temp.as_service();
select public.parental_consent_mark_sent((current_setting('test.nora2')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.nora2')::jsonb ->> 'send_id')::bigint, 'hash-n2', 'parental-invite-v3');
select is(public.parental_consent_lookup('hash-n1'), '{"outcome": "invalid"}'::jsonb, 'and the older link stops working');
select is(public.parental_consent_decide('hash-n1', 'agree'), '{"outcome": "invalid"}'::jsonb,
  'so it can''t be used to agree');
select is(public.parental_consent_decide('no-such-hash', 'agree'), '{"outcome": "invalid"}'::jsonb,
  'an unknown link is invalid');

-- Refused ------------------------------------------------------------------------------------------------------------
select is(public.parental_consent_decide('hash-o1', 'refuse'), '{"outcome": "refused"}'::jsonb, 'a parent can say no');
select is(public.parental_consent_decide('hash-o1', 'agree'), '{"outcome": "refused"}'::jsonb, 'and that answer stays');
select pg_temp.as_admin();
select is((select (status, typed_email is null, ended_at is not null, decided_at is not null)::text
           from public.parental_consent_requests where member_id = '00000000-0000-0000-0000-0000000000a7'),
  '(refused,t,t,t)', 'a refused request ends and forgets the typed address');
select is_empty($$ select 1 from public.consents where member_id = '00000000-0000-0000-0000-0000000000a7' $$,
  'refusing records no consent');
insert into public.invites (household_id, member_id, code_hash, created_by) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a7',
   encode(extensions.digest('ABCDEFGH', 'sha256'), 'hex'), 'a0000000-0000-0000-0000-00000000000a');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a7') $$, '22023', null,
  'a refused kid can''t be invited');
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');  -- Erin
select is(public.redeem_invite('ANDER-ABCD-EFGH', 'under_13'), 'needs_consent',
  'and an older invite for them can''t be claimed');

-- Agreed, then confirmed once email 2 is out ---------------------------------------------------------------------------
select pg_temp.as_service();
select set_config('test.agree', public.parental_consent_decide('hash-n2', 'agree')::text, true);
select is(current_setting('test.agree')::jsonb ->> 'outcome', 'send_confirmation', 'I agree asks for email 2');
select is(current_setting('test.agree')::jsonb ->> 'email', 'alice@example.com', 'to the parent who asked');
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a5')).status, 'consented', 'the request is consented');
select is_empty($$ select 1 from public.consents where member_id = '00000000-0000-0000-0000-0000000000a5' $$,
  'but no consent exists until email 2 is out');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select throws_ok($$ select public.create_invite('00000000-0000-0000-0000-0000000000a5') $$, '22023', null,
  'so the kid still can''t be invited');
select throws_ok($$ select public.parental_consent_lookup('hash-n2') $$, '42501', null,
  'a parent can''t look links up either');
select pg_temp.as_service();
select is(public.parental_consent_decide('hash-n2', 'agree'), '{"outcome": "busy"}'::jsonb,
  'a second tap while email 2 is going out waits');
select public.parental_consent_release_confirmation((current_setting('test.agree')::jsonb ->> 'request_id')::uuid);
select is((pg_temp.req('00000000-0000-0000-0000-0000000000a5')).status, 'consented',
  'email 2 failing keeps the agreement');
select is(public.parental_consent_lookup('hash-n2') ->> 'outcome', 'pending', 'and the page offers I agree again');
select is(public.parental_consent_decide('hash-n2', 'agree') ->> 'outcome', 'send_confirmation',
  'tapping again sends email 2 again');
select is(public.activate_parental_consent((current_setting('test.agree')::jsonb ->> 'request_id')::uuid, 'whash-n'),
  'confirmed', 'email 2 out: consent is active');
select pg_temp.as_admin();
select is((select (method, granted_by, text_version, confirmed_at is not null, granted_at <= confirmed_at,
                   request_id::text = current_setting('test.agree')::jsonb ->> 'request_id')::text
           from public.consents where member_id = '00000000-0000-0000-0000-0000000000a5' and revoked_at is null),
  '(email_plus,a0000000-0000-0000-0000-00000000000a,parental-invite-v3,t,t,t)',
  'the record has the method, who asked, the wording, both times and the request');
select is((select (status, withdraw_token_hash, confirmed_at is not null)::text
           from public.parental_consent_requests where member_id = '00000000-0000-0000-0000-0000000000a5'),
  '(confirmed,whash-n,t)', 'the request is confirmed');
select pg_temp.as_service();
select is(public.parental_consent_decide('hash-n2', 'refuse'), '{"outcome": "confirmed"}'::jsonb,
  'the consent link can''t undo it; the withdraw link does');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select set_config('test.code', public.create_invite('00000000-0000-0000-0000-0000000000a5'), true);
select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');  -- Dave
select is(public.redeem_invite(current_setting('test.code'), 'under_13'), 'claimed', 'and the kid joins');

-- Withdrawing by email 2's link ---------------------------------------------------------------------------------------
select pg_temp.as_service();
select is(public.parental_consent_withdraw_lookup('whash-n'), '{"outcome": "active", "first_name": "Nora"}'::jsonb,
  'the withdraw page can show whom it''s for');
select is(public.withdraw_parental_consent('whash-n'), 'withdrawn', 'the link withdraws');
select is(public.withdraw_parental_consent('whash-n'), 'withdrawn', 'twice is fine');
select is(public.withdraw_parental_consent('nope'), 'invalid', 'an unknown link is invalid');
select pg_temp.as_admin();
select is((select user_id from public.members where id = '00000000-0000-0000-0000-0000000000a5'), null,
  'withdrawing unlinks the kid at once');
select is((select count(*)::int from public.invites
           where member_id = '00000000-0000-0000-0000-0000000000a5' and redeemed_at is null and revoked_at is null), 0,
  'and leaves no open invite');
update public.parental_consent_requests set confirmed_at = now() - interval '31 days'
where member_id = '00000000-0000-0000-0000-0000000000a5';
select pg_temp.as_service();
select is(public.parental_consent_withdraw_lookup('whash-n'), '{"outcome": "expired"}'::jsonb,
  'the withdraw link works for 30 days');

-- Expired --------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul asks again for Owen
select set_config('test.owen2',
  public.request_parental_consent('00000000-0000-0000-0000-0000000000a7', 'paul@example.com')::text, true);
select isnt(current_setting('test.owen2')::jsonb ->> 'request_id', current_setting('test.owen1')::jsonb ->> 'request_id',
  'asking again after a no is a new request');
select pg_temp.as_service();
select public.parental_consent_mark_sent((current_setting('test.owen2')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.owen2')::jsonb ->> 'send_id')::bigint, 'hash-o2', 'parental-invite-v3');
select pg_temp.as_admin();
update public.parental_consent_requests set expires_at = now() - interval '1 minute' where token_hash = 'hash-o2';
select pg_temp.as_service();
select is(public.parental_consent_lookup('hash-o2'), '{"outcome": "expired"}'::jsonb, 'a lapsed link shows expired');
select is(public.parental_consent_decide('hash-o2', 'agree'), '{"outcome": "expired"}'::jsonb, 'and can''t agree');
select pg_temp.as_admin();
select is((select (status, typed_email is null)::text from public.parental_consent_requests where token_hash = 'hash-o2'),
  '(expired,t)', 'it ends, forgetting the typed address');

-- Activation checks again ----------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice, for Pia
select set_config('test.pia', public.request_parental_consent('00000000-0000-0000-0000-0000000000a8')::text, true);
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul, for Quin
select set_config('test.quin', public.request_parental_consent('00000000-0000-0000-0000-0000000000a9', 'paul@example.com')::text, true);
select pg_temp.as_service();
select public.parental_consent_mark_sent((current_setting('test.pia')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.pia')::jsonb ->> 'send_id')::bigint, 'hash-p1', 'parental-invite-v3');
select public.parental_consent_mark_sent((current_setting('test.quin')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.quin')::jsonb ->> 'send_id')::bigint, 'hash-q1', 'parental-invite-v3');
select public.parental_consent_decide('hash-p1', 'agree');
select public.parental_consent_decide('hash-q1', 'agree');
select pg_temp.as_admin();
update public.members set status = 'removed' where id = '00000000-0000-0000-0000-0000000000a8';
update public.members set guardian = false where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_service();
select is(public.activate_parental_consent((current_setting('test.pia')::jsonb ->> 'request_id')::uuid, 'whash-p'),
  'expired', 'a profile removed meanwhile gets no consent');
select is(public.activate_parental_consent((current_setting('test.quin')::jsonb ->> 'request_id')::uuid, 'whash-q'),
  'expired', 'nor one whose parent stopped being a parent');
select pg_temp.as_admin();
select is_empty($$ select 1 from public.consents
                  where member_id in ('00000000-0000-0000-0000-0000000000a8', '00000000-0000-0000-0000-0000000000a9') $$,
  'no consent was written for either');
select is((select array_agg(status order by token_hash) from public.parental_consent_requests
           where token_hash in ('hash-p1', 'hash-q1')), '{cancelled,cancelled}'::text[], 'both requests are cancelled');
update public.members set guardian = true where id = '00000000-0000-0000-0000-0000000000a2';

-- Limits ---------------------------------------------------------------------------------------------------------------
insert into public.parental_consent_sends (requested_by, reserved_at, sent)
select 'c0000000-0000-0000-0000-00000000000c', now() - interval '2 hours', true from generate_series(1, 5);
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000b2') ->> 'outcome', 'rate_limited',
  '5 emails a day per parent');
select pg_temp.as_admin();
delete from public.parental_consent_sends where requested_by = 'c0000000-0000-0000-0000-00000000000c';
insert into public.parental_consent_sends (requested_by, reserved_at, sent)
select gen_random_uuid(), now(), true from generate_series(1, 200);
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is(public.request_parental_consent('00000000-0000-0000-0000-0000000000b2') ->> 'outcome', 'rate_limited',
  '200 an hour overall');
select pg_temp.as_admin();
update public.parental_consent_sends set reserved_at = now() - interval '2 hours' where request_id is null;
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select set_config('test.cal', public.request_parental_consent('00000000-0000-0000-0000-0000000000b2')::text, true);
select is(current_setting('test.cal')::jsonb ->> 'outcome', 'send', 'and an hour later it sends');
select pg_temp.as_service();
select public.parental_consent_release_send((current_setting('test.cal')::jsonb ->> 'request_id')::uuid,
  (current_setting('test.cal')::jsonb ->> 'send_id')::bigint);
select pg_temp.as_admin();
select is_empty($$ select 1 from public.parental_consent_requests where member_id = '00000000-0000-0000-0000-0000000000b2' $$,
  'a send that failed leaves no request behind');
select is((select reserved_at from public.parental_consent_sends
           where id = (current_setting('test.cal')::jsonb ->> 'send_id')::bigint), null,
  'and doesn''t count toward the limits');

-- Who reads requests ---------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a2');  -- Paul
select ok((select count(*) from public.parental_consent_requests
           where household_id = '00000000-0000-0000-0000-0000000000a0') >= 4, 'a parent reads the family''s requests');
select is((select status from public.parental_consent_requests where member_id = '00000000-0000-0000-0000-0000000000a5'),
  'confirmed', 'and their status');
select throws_ok($$ select token_hash from public.parental_consent_requests $$, '42501', null, 'but never a token hash');
select throws_ok($$ select withdraw_token_hash from public.parental_consent_requests $$, '42501', null,
  'or a withdraw token hash');
select throws_ok($$ select typed_email from public.parental_consent_requests $$, '42501', null, 'or a typed address');
select throws_ok($$ update public.parental_consent_requests set status = 'confirmed' $$, '42501', null,
  'and nobody changes one from the app');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a3');  -- Grace
select is_empty($$ select 1 from public.parental_consent_requests $$, 'an adult who isn''t a parent reads none');
select pg_temp.as_user('a0000000-0000-0000-0000-0000000000a4');  -- Kim
select is_empty($$ select 1 from public.parental_consent_requests $$, 'nor does a kid');
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');  -- Carol
select is_empty($$ select 1 from public.parental_consent_requests $$, 'nor another household');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'parental_consent_requests'),
  (select count(*)::int from public.parental_consent_requests), 'the export has the requests');
select ok(not exists (select 1 from jsonb_array_elements(
            public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'parental_consent_requests') r
          where r ? 'token_hash' or r ? 'typed_email' or r ? 'requested_by'),
  'status and times only');

-- Retention ------------------------------------------------------------------------------------------------------------
select pg_temp.as_admin();
update public.parental_consent_requests set ended_at = now() - interval '31 days' where token_hash = 'hash-o1';
insert into public.parental_consent_requests (household_id, member_id, requested_by, email_source, typed_email,
                                              token_hash, token_sent_at, expires_at)
values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a9',
        'a0000000-0000-0000-0000-0000000000a2', 'typed', 'paul@example.com', 'hash-q2', now() - interval '8 days',
        now() - interval '1 day');
insert into public.parental_consent_requests (household_id, member_id, requested_by, email_source, send_reserved_at,
                                              created_at)
values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a9',
        'a0000000-0000-0000-0000-00000000000a', 'account', now() - interval '2 hours', now() - interval '2 hours');
update public.parental_consent_sends set created_at = now() - interval '2 days' where request_id is null;
select pg_temp.as_service();
select public.purge_parental_consent_requests();
select pg_temp.as_admin();
select is_empty($$ select 1 from public.parental_consent_requests where token_hash = 'hash-o1' $$,
  'a request is deleted 30 days after it ended');
select is((select (status, typed_email is null)::text from public.parental_consent_requests where token_hash = 'hash-q2'),
  '(expired,t)', 'a lapsed one is ended, typed address and all');
select is_empty($$ select 1 from public.parental_consent_requests where token_sent_at is null $$,
  'a send that never happened is dropped');
select is_empty($$ select 1 from public.parental_consent_sends where created_at < now() - interval '1 day' $$,
  'send bookkeeping goes after a day');
select isnt_empty($$ select 1 from public.parental_consent_requests where token_hash = 'hash-o2' $$,
  'a recently ended request stays');

-- Deleting a kid or the household takes their requests ----------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Alice
select public.delete_kid('00000000-0000-0000-0000-0000000000a7');
select pg_temp.as_admin();
select is_empty($$ select 1 from public.parental_consent_requests where member_id = '00000000-0000-0000-0000-0000000000a7' $$,
  'delete_kid deletes the kid''s requests');
select public.erase_household('00000000-0000-0000-0000-0000000000a0');
select is_empty($$ select 1 from public.parental_consent_requests
                  where household_id = '00000000-0000-0000-0000-0000000000a0' $$,
  'erasing the household deletes them all');

select * from finish();
rollback;
