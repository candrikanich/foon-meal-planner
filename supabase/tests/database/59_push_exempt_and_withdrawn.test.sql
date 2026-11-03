-- Plan's set and urgent items sit outside the weekly budget; no push names a kid whose consent is withdrawn.
begin;
select plan(14);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

create function pg_temp.as_postgres() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('role', 'postgres', true);
$$;

create function pg_temp.log_sent(member uuid, n int, kind text) returns void language sql as $$
  insert into public.notification_log (id, household_id, member_id, type, channel, scheduled_for, sent_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-0000000000a0', member, kind, 'push', now(), now()
  from generate_series(1, n);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'bob@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a');

-- A clock where it's about noon now, so tonight's dinner is still ahead and adults aren't in quiet hours.
update public.households
set settings = settings || jsonb_build_object('time_zone',
  (select case when k >= 0 then 'Etc/GMT+' || k else 'Etc/GMT-' || -k end
   from (select extract(hour from now() at time zone 'UTC')::int - 12 as k) offset_hours));

insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'planner', false, 'adult',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a0', 'Owen', 'member', false, 'kid', null);

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.register_push_device(repeat('a1', 32), 'sandbox');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select public.register_push_device(repeat('b2', 32), 'sandbox');
select pg_temp.as_postgres();

-- Outside the budget --------------------------------------------------------------------------------------------------------------

select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a1', 12, 'plan_set');
select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a1', 12, 'urgent_item');
select is(public.push_budget_left('00000000-0000-0000-0000-0000000000a1', now()), 12,
  'Plan''s set and urgent items that went out don''t use the week''s budget');

select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a2', 12, 'tonight_poll');
insert into public.push_outbox (id, household_id, member_id, kind, args, not_before) values
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'plan_set', '{}', now() - interval '2 minutes'),
  ('00000000-0000-0000-0000-0000000005b2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'urgent_item', '{"name": "Alice"}', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-0000000005b3', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'tonight_poll', '{"name": "Alice"}', now() - interval '1 minute');
set local role service_role;
select results_eq($$ select id from public.claim_push_outbox(10) order by id $$,
  $$ values ('00000000-0000-0000-0000-0000000005b1'::uuid), ('00000000-0000-0000-0000-0000000005b2'::uuid) $$,
  'someone at budget still gets Plan''s set and an urgent item; only the poll waits out');
select pg_temp.as_postgres();
select is((select failed from public.push_outbox where id = '00000000-0000-0000-0000-0000000005b3'), 'over_budget',
  'the poll is over budget');
select is((select count(*) from public.push_outbox where kind in ('plan_set', 'urgent_item') and failed is not null), 0::bigint,
  'and they never are');

-- One left, and an urgent item still being tried: it doesn't hold that one.
delete from public.push_outbox;
delete from public.notification_log where member_id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.log_sent('00000000-0000-0000-0000-0000000000a2', 11, 'tonight_poll');
insert into public.push_outbox (id, household_id, member_id, kind, args, not_before, attempts, claimed_until) values
  ('00000000-0000-0000-0000-0000000005b4', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'urgent_item', '{"name": "Alice"}', now() - interval '5 minutes', 1, now() + interval '4 minutes');
insert into public.push_outbox (id, household_id, member_id, kind, args, not_before) values
  ('00000000-0000-0000-0000-0000000005b5', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2',
   'tonight_poll', '{"name": "Alice"}', now() - interval '1 minute');
set local role service_role;
select results_eq($$ select id from public.claim_push_outbox(10) $$,
  $$ values ('00000000-0000-0000-0000-0000000005b5'::uuid) $$,
  'an urgent item being retried doesn''t take the last slot from a poll');
select pg_temp.as_postgres();
delete from public.push_outbox;
delete from public.notification_log;

-- Names -------------------------------------------------------------------------------------------------------------------------

-- Nora's parents gave consent for her own device and then withdrew it. Owen never had a device of his own.
insert into public.consents (household_id, member_id, kind, granted_by, text_version) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a3', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'v1');
-- Queued and sent before the withdrawal.
insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before, sent_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'claim',
   '00000000-0000-0000-0000-0000000000a3', '{"name": "Nora"}', now() + interval '1 hour', null),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'not_home',
   '00000000-0000-0000-0000-0000000000a3', '{"name": "Nora"}', now(), now()),
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a1', 'new_requests',
   '00000000-0000-0000-0000-0000000000a3', '{"count": 1, "name": "Nora"}', now(), now());
update public.consents set revoked_at = now() where member_id = '00000000-0000-0000-0000-0000000000a3';

select is((select count(*) from public.push_outbox where args ? 'name'), 0::bigint,
  'withdrawing consent takes her name out of what''s queued or sent at once, not a month later');
select results_eq($$ select kind, about_member_id from public.push_outbox order by kind $$,
  $$ values ('claim', '00000000-0000-0000-0000-0000000000a3'::uuid), ('new_requests', null::uuid),
            ('not_home', '00000000-0000-0000-0000-0000000000a3'::uuid) $$,
  'a digest stops pointing at her; the rest keep what once-only and call-offs need');
select is(public.push_name_args('00000000-0000-0000-0000-0000000000a3'), '{}'::jsonb, 'a withdrawn kid is never named');
select is(public.push_name_args('00000000-0000-0000-0000-0000000000a4'), '{"name": "Owen"}'::jsonb,
  'a kid whose parents never gave a device of their own is, as before');
delete from public.push_outbox;

insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_nights (id, household_id, plan_id, date, dinner_time) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0'), '23:00'),
  ('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 1, '23:00');

-- Alice answers and offers for Nora, as she can for a profile nobody has claimed.
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a3', false);
select public.claim_night('00000000-0000-0000-0000-0000000004a2', '00000000-0000-0000-0000-0000000000a3');
select pg_temp.as_postgres();
select results_eq($$ select kind, args from public.push_outbox where member_id = '00000000-0000-0000-0000-0000000000a2'
                     order by kind $$,
  $$ values ('claim', '{}'::jsonb), ('not_home', '{}'::jsonb) $$,
  'Bob still hears that someone won''t be home and someone will cook, with no name');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.answer_check_in('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a4', false);
select pg_temp.as_postgres();
select is((select args from public.push_outbox where about_member_id = '00000000-0000-0000-0000-0000000000a4'),
  '{"name": "Owen"}'::jsonb, 'Owen is named as before');

-- Whatever got queued with her name somehow, it isn't handed out with it.
update public.push_outbox set not_before = now() - interval '1 minute';
update public.push_outbox set args = '{"name": "Nora"}' where about_member_id = '00000000-0000-0000-0000-0000000000a3';
set local role service_role;
select results_eq($$ select kind, args from public.claim_push_outbox(10) where kind in ('not_home', 'claim')
                     and (args ->> 'name' is distinct from 'Owen') order by kind $$,
  $$ values ('claim', '{}'::jsonb), ('not_home', '{}'::jsonb) $$,
  'send-push gets no name for her, whatever the row holds');
select pg_temp.as_postgres();

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.push_name_args('00000000-0000-0000-0000-0000000000a4') $$, '42501', null,
  'clients can''t ask for names this way');
select throws_ok($$ select * from public.push_outbox $$, '42501', null, 'or read the outbox');
select pg_temp.as_postgres();

select * from finish();
rollback;
