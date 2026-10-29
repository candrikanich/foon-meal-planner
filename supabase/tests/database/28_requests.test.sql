-- The idea inbox (#38, part 1).
begin;
select plan(33);

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
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Bob', 'member', false, 'kid',
   'b0000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Nora', 'member', false, 'kid', null),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.meals (id, household_id, name) values
  ('00000000-0000-0000-0000-0000000002a1', '00000000-0000-0000-0000-0000000000a0', 'Tacos'),
  ('00000000-0000-0000-0000-0000000002b1', '00000000-0000-0000-0000-0000000000b0', 'Saffron rice');
insert into public.plans (id, household_id, week_start) values
  ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000a0',
   public.household_today('00000000-0000-0000-0000-0000000000a0'));
insert into public.plan_nights (id, household_id, plan_id, date) values
  ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000003a1',
   public.household_today('00000000-0000-0000-0000-0000000000a0') + 2);

create temp table made (name text primary key, id uuid) on commit drop;
grant select, insert on made to authenticated;

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
insert into made select 'tacos', public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000002a1', null, null, 'my night off',
  public.household_today('00000000-0000-0000-0000-0000000000a0') + 2);
insert into made select 'crab', public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a3', null, '  Crab legs ', null, null, null);
select results_eq(
  $$ select r.title, r.note, r.status::text, r.requested_by_member_id, r.entered_by_member_id from public.requests r
     join made m on m.id = r.id order by m.name $$,
  $$ values ('Crab legs', null::text, 'open', '00000000-0000-0000-0000-0000000000a3'::uuid,
             '00000000-0000-0000-0000-0000000000a2'::uuid),
            (null, 'my night off', 'open', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2') $$,
  'Bob asks for tacos on a night, and (passing the phone) crab legs for Nora; his phone is recorded for both');
select throws_ok($$ select public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a1', null, 'Steak', null, null, null) $$, '42501', null,
  'nobody asks in the name of someone with their own account');
select throws_ok($$ select public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a2', null, null, null, 'hm', null) $$, '23514', null, 'a request asks for something');
select throws_ok($$ select public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a2', null, 'Pie', 'javascript:alert(1)', null, null) $$, '23514', null,
  'links are web links');
select throws_ok($$ select public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a2', null, 'Pie', null, null,
  public.household_today('00000000-0000-0000-0000-0000000000a0') - 1) $$, '22023', null, 'not for a night gone by');
select throws_ok($$ insert into public.requests (household_id, requested_by_member_id, title) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'x') $$, '42501', null,
  'requests are made through make_request only');

-- Me too.
select is(public.toggle_me_too((select id from made where name = 'crab'), '00000000-0000-0000-0000-0000000000a2'), true,
  'Bob says me too to crab legs');
select throws_ok($$ select public.toggle_me_too((select id from made where name = 'tacos'),
  '00000000-0000-0000-0000-0000000000a2') $$, '22023', null, 'not to his own request');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.toggle_me_too((select id from made where name = 'crab'), '00000000-0000-0000-0000-0000000000a1'), true,
  'Alice too');
select is((select count(*)::int from public.request_plus_ones), 2, 'two me-toos');
select is(public.toggle_me_too((select id from made where name = 'crab'), '00000000-0000-0000-0000-0000000000a1'), false,
  'and Alice takes hers back');

-- What happens next.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.update_request((select id from made where name = 'tacos'), 'planned',
  '00000000-0000-0000-0000-0000000004a1', false, null, null, null) $$, '42501', null, 'Bob can''t plan it');
select lives_ok($$ select public.update_request((select id from made where name = 'tacos'), null, null, false, null,
  'my night off!', null) $$, 'but he can change his note');
select throws_ok($$ select public.update_request((select id from made where name = 'crab'), 'special', null, false,
  null, null, null) $$, '42501', null, 'or save someone''s for a special occasion');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.update_request((select id from made where name = 'tacos'), 'planned',
  '00000000-0000-0000-0000-0000000004a1', false, null, null, null) $$, 'Alice plans the tacos on their night');
select results_eq($$ select status::text, planned_night_id from public.requests where id = (select id from made where name = 'tacos') $$,
  $$ values ('planned', '00000000-0000-0000-0000-0000000004a1'::uuid) $$, 'planned, with the night');
select lives_ok($$ select public.update_request((select id from made where name = 'crab'), null, null, true,
  '00000000-0000-0000-0000-0000000002a1', null, null) $$, 'and links crab legs to a library dish (Save to library)');
select lives_ok($$ select public.update_request((select id from made where name = 'crab'), 'special', null, false,
  null, null, null) $$, 'then saves it for a special occasion');
select lives_ok($$ select public.update_request((select id from made where name = 'tacos'), 'planned', null, false,
  null, null, null) $$, 'planning again keeps the night it has');
insert into made select 'pie', public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a3', null, 'Pie', null, 'Nora wants', null);
select throws_ok($$ select public.update_request((select id from made where name = 'pie'), 'planned', null, false,
  null, null, null) $$, '22023', null, 'planning needs a night');
select throws_ok($$ select public.update_request((select id from made where name = 'pie'), 'special',
  '00000000-0000-0000-0000-0000000004a1', false, null, null, null) $$, '22023', null, 'a night is only for planning');
select throws_ok($$ select public.make_request('00000000-0000-0000-0000-0000000000a0',
  '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000002b1', null, null, null, null) $$,
  '23503', null, 'another household''s dish can''t be asked for');
select throws_ok($$ update public.requests set status = 'archived' $$, '42501', null, 'never written directly');
select throws_ok($$ delete from public.requests $$, '42501', null, 'and never deleted');

-- Bob can't archive or rewrite the pie Alice asked for on Nora's behalf: it's neither his nor entered on his phone.
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.update_request((select id from made where name = 'pie'), 'archived', null, false,
  null, 'Bob rewrote', null) $$, '42501', null, 'passing the phone doesn''t make Nora''s other requests yours');
select throws_ok($$ select public.update_request((select id from made where name = 'tacos'), null, null, true, null,
  null, null) $$, '42501', null, 'and a planned request stays where the planner put it');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(jsonb_array_length(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'requests'), 3,
  'the export includes requests');

-- Retention: Bob's own-device consent is withdrawn a month ago. His own requests (and me-toos on them) go; the crab
-- legs he asked for Nora stay.
reset role;
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select public.toggle_me_too((select id from made where name = 'tacos'), '00000000-0000-0000-0000-0000000000a1');
reset role;
insert into public.consents (household_id, member_id, kind, granted_by, text_version, granted_at, revoked_at) values
  ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000a2', 'parental',
   'a0000000-0000-0000-0000-00000000000a', 'parental-v1', now() - interval '60 days', now() - interval '31 days');
update public.members set user_id = null where id = '00000000-0000-0000-0000-0000000000a2';
select public.anonymize_expired_profiles();
select is_empty($$ select 1 from public.requests where id = (select id from made where name = 'tacos') $$,
  'Bob''s own request is erased, with the me-toos on it');
select is_empty($$ select 1 from public.request_plus_ones where member_id = '00000000-0000-0000-0000-0000000000a2' $$,
  'and his own me-toos');
select is((select title from public.requests where id = (select id from made where name = 'crab')), 'Crab legs',
  'what he asked for Nora stays');
select public.delete_account_data('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.requests where household_id = '00000000-0000-0000-0000-0000000000a0'), 0,
  'deleting the household takes its requests');

select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.requests $$, 'another household sees no requests');
select throws_ok($$ select public.toggle_me_too((select id from made where name = 'crab'),
  '00000000-0000-0000-0000-0000000000c1') $$, 'P0002', null, 'or votes on them');

select * from finish();
rollback;
