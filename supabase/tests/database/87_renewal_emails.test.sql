-- Renewal emails for a held kid (#277): every parent with a verified account email gets one, once, and one reminder 7
-- days later if the hold is still open. Every parent's link stays live; a parent without a verified email is told in
-- the app only. Only the overall 200-an-hour cap applies. Service role only; pg_cron pokes the Edge Function.
begin;
select plan(25);

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
create function pg_temp.emails(setting text) returns text[] language sql as $$
  select array_agg(e ->> 'email' order by e ->> 'email') from jsonb_array_elements(current_setting(setting)::jsonb) e;
$$;

-- Household A: Ann (owner) and Ben, parents who sign in with Apple; Paul, a parent with no Apple email; Kit, a kid with an
-- account whose consent was given in the app (v1); Zoe, a kid with no consent yet. Household B: Carol, for the cap.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated'),
  ('20000000-0000-0000-0000-000000000002', 'paul@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kit@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into auth.identities (provider_id, user_id, identity_data, provider) values
  ('apple-ann', 'a0000000-0000-0000-0000-00000000000a',
   '{"sub": "apple-ann", "email": "ann@example.com", "email_verified": true}', 'apple'),
  ('apple-ben', 'b0000000-0000-0000-0000-00000000000b',
   '{"sub": "apple-ben", "email": "ben@example.com", "email_verified": true}', 'apple');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true,
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Paul', 'member', 'adult', true,
   '20000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Kit', 'member', 'kid', false,
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000a5', '00000000-0000-0000-0000-0000000000a0', 'Zoe', 'member', 'kid', false, null),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', 'adult', true,
   'c0000000-0000-0000-0000-00000000000c');
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a4', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-invite-v1');

update public.agreement_versions set effective_at = now() where version in ('parental-invite-v2', 'parental-invite-v3');
select pg_temp.as_service();
select public.apply_agreement_holds();

-- The first round ----------------------------------------------------------------------------------------------------------
select set_config('test.first', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select is(pg_temp.emails('test.first'), array['ann@example.com', 'ben@example.com'],
  'every parent with a verified email gets one; a parent without is told in the app only');
select ok((select bool_and(not (e ->> 'reminder')::boolean and e ->> 'first_name' = 'Kit'
                           and e ->> 'held_version' = 'parental-invite-v1'
                           and e ->> 'required_version' = 'parental-invite-v3'
                           and e ->> 'summary' is not null and e ->> 'agreed_at' is not null)
           from jsonb_array_elements(current_setting('test.first')::jsonb) e),
  'each says whose it is, what changed and when a parent agreed before');
select pg_temp.as_admin();
select is((select count(*)::int from public.parental_consent_requests
           where reason = 'renewal' and status = 'pending'
             and hold_id = (select id from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a4')),
  2, 'one renewal request per parent, on the hold');
select ok((select emailed_at is null and reminded_at is null from public.agreement_holds
           where member_id = '00000000-0000-0000-0000-0000000000a4'),
  'reserving the emails doesn''t start the round clock (20261118000000)');
select pg_temp.as_service();
select is(public.claim_consent_renewal_emails(10, 'parental-invite-v3'), '[]'::jsonb, 'nobody gets it twice');
select pg_temp.as_admin();
select is(public.kick_consent_renewals(), false, 'and nothing is owed');
select pg_temp.as_service();
select public.parental_consent_mark_sent((e ->> 'request_id')::uuid, (e ->> 'send_id')::bigint, 'hash-' || (e ->> 'email'),
                                         'parental-invite-v3')
from jsonb_array_elements(current_setting('test.first')::jsonb) e;
select pg_temp.as_admin();
select ok((select emailed_at is not null and reminded_at is null from public.agreement_holds
           where member_id = '00000000-0000-0000-0000-0000000000a4'),
  'the hold records the first email once it''s sent');
select is((select count(*)::int from public.parental_consent_requests
           where reason = 'renewal' and status = 'pending' and token_sent_at is not null), 2,
  'one parent''s link doesn''t cancel another''s: every parent can answer');
select pg_temp.as_service();
select is(public.parental_consent_decide('hash-ben@example.com', 'refuse'), '{"outcome": "refused"}'::jsonb,
  'Ben says No');
select pg_temp.as_admin();

-- The reminder ---------------------------------------------------------------------------------------------------------
update public.agreement_holds set emailed_at = emailed_at - interval '8 days'
where member_id = '00000000-0000-0000-0000-0000000000a4';
update public.parental_consent_requests
set created_at = created_at - interval '8 days', token_sent_at = token_sent_at - interval '8 days'
where reason = 'renewal';
select pg_temp.as_service();
select set_config('test.second', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select is(pg_temp.emails('test.second'), array['ann@example.com'],
  'a week on, still held: one reminder, and none to a parent who said No');
select ok((select bool_and((e ->> 'reminder')::boolean) from jsonb_array_elements(current_setting('test.second')::jsonb) e),
  'marked as the reminder');
select public.parental_consent_mark_sent((e ->> 'request_id')::uuid, (e ->> 'send_id')::bigint, 'hash-r-' || (e ->> 'email'),
                                         'parental-invite-v3')
from jsonb_array_elements(current_setting('test.second')::jsonb) e;
select pg_temp.as_admin();
select is((select count(*)::int from public.parental_consent_requests where reason = 'renewal' and status = 'cancelled'), 1,
  'the new link replaces the old one');
select ok((select reminded_at is not null from public.agreement_holds
           where member_id = '00000000-0000-0000-0000-0000000000a4'),
  'the hold records the reminder');
update public.agreement_holds set reminded_at = reminded_at - interval '2 days'
where member_id = '00000000-0000-0000-0000-0000000000a4';
select pg_temp.as_service();
select is(public.claim_consent_renewal_emails(10, 'parental-invite-v3'), '[]'::jsonb, 'and there''s only one reminder');

-- The overall cap, and only it ----------------------------------------------------------------------------------------
select pg_temp.as_admin();
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a5', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-invite-v1');
insert into public.parental_consent_sends (household_id, requested_by, reserved_at)
select '00000000-0000-0000-0000-0000000000b0', 'c0000000-0000-0000-0000-00000000000c', now()
from generate_series(1, 200);
select pg_temp.as_service();
select public.apply_agreement_holds();
select is(public.claim_consent_renewal_emails(10, 'parental-invite-v3'), '[]'::jsonb, 'over the overall cap, renewal emails wait');
select pg_temp.as_admin();
select ok((select emailed_at is null from public.agreement_holds where member_id = '00000000-0000-0000-0000-0000000000a5'),
  'and the hold is still owed them');
select is(public.kick_consent_renewals(), false, 'without the Vault secrets nothing is poked');
select vault.create_secret('https://example.test/functions/v1/parental-consent', 'consent_function_url');
select vault.create_secret('test-secret', 'consent_cron_secret');
select is(public.kick_consent_renewals(), true, 'with them, an owed email pokes the function');
delete from public.parental_consent_sends where household_id = '00000000-0000-0000-0000-0000000000b0';
-- Past the per-parent and per-household limits, which are for the emails a parent asks for.
insert into public.parental_consent_sends (household_id, requested_by, reserved_at)
select '00000000-0000-0000-0000-0000000000a0', 'a0000000-0000-0000-0000-00000000000a', now()
from generate_series(1, 10);
select pg_temp.as_service();
select set_config('test.zoe1', public.claim_consent_renewal_emails(1, 'parental-invite-v3')::text, true);
select set_config('test.zoe2', public.claim_consent_renewal_emails(10, 'parental-invite-v3')::text, true);
select is(jsonb_array_length(current_setting('test.zoe1')::jsonb), 1, 'a run takes as many as it''s given');
select is((select array_agg(e ->> 'email' order by e ->> 'email')
           from jsonb_array_elements(current_setting('test.zoe1')::jsonb || current_setting('test.zoe2')::jsonb) e),
  array['ann@example.com', 'ben@example.com'],
  'and the next run the rest; a parent''s own send limits don''t hold them back');

-- Who can do this ------------------------------------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select throws_ok($$ select public.claim_consent_renewal_emails(10, 'parental-invite-v3') $$, '42501', null, 'a parent can''t claim emails');
select throws_ok($$ select public.apply_agreement_holds() $$, '42501', null, 'or apply holds');
select throws_ok($$ select public.kick_consent_renewals() $$, '42501', null, 'or poke the function');
select pg_temp.as_user('20000000-0000-0000-0000-000000000002');  -- Paul
select is(jsonb_array_length(public.my_agreements('00000000-0000-0000-0000-0000000000a0') -> 'kids_held'), 2,
  'a parent without a verified email still sees who''s held, in the app');

-- Push order -----------------------------------------------------------------------------------------------------------
select pg_temp.as_admin();
select is(array[public.push_kind_rank('agreement_hold'), public.push_kind_rank('heading_to_store'),
                public.push_kind_rank('urgent_item'), public.push_kind_rank('plan_set')], array[0, 0, 0, 0],
  'a held kid goes first, with the store run and urgent items');

select * from finish();
rollback;
