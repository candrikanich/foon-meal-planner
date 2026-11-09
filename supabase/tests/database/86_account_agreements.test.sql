-- Terms and Privacy acceptances (#277): logged per account through accept_agreements only, read only by that account,
-- kept as proof after the account is deleted. An account-level table, so it's the one place tenancy is by account
-- rather than household: another account (in any household) reads none of it.
begin;
select plan(20);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '{}', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role": "anon"}', true), set_config('role', 'anon', true);
$$;

-- Ann and Ben share a household; Zed is a household neither is in.
insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'ann@example.com', 'authenticated', 'authenticated'),
  ('b0000000-0000-0000-0000-00000000000b', 'ben@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000f0', 'Zed', null);
insert into public.members (id, household_id, first_name, role, age_group, guardian, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Ann', 'planner', 'adult', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a0', 'Ben', 'member', 'adult', true,
   'b0000000-0000-0000-0000-00000000000b');

select has_table('public', 'account_agreements', 'Terms and Privacy acceptances have their own table');

select set_config('request.jwt.claims', '{"role": "authenticated"}', true), set_config('role', 'authenticated', true);
select throws_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v1', 'join') $$, '28000', null,
  'without a signed-in account nothing is logged');

select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select throws_ok($$ select public.accept_agreements('terms-v99', 'privacy-draft-v1', 'join') $$, '22023', null,
  'a wording nobody registered is refused');
select throws_ok($$ select public.accept_agreements('privacy-draft-v1', 'terms-draft-v1', 'join') $$, '22023', null,
  'and one of the wrong kind');
select throws_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v1', 'whenever') $$, '22023', null,
  'and a context the app doesn''t send');
select lives_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v1', 'create_household',
                                                   'Foon 1.4 (63)') $$,
  'an adult accepts both');
select lives_ok($$ select public.accept_agreements('terms-draft-v1', 'privacy-draft-v1', 'next_launch') $$,
  'accepting again is fine');
select is((select array_agg((kind, text_version, context, client)::text order by kind) from public.account_agreements),
  array['(terms,terms-draft-v1,create_household,"Foon 1.4 (63)")',
        '(privacy,privacy-draft-v1,create_household,"Foon 1.4 (63)")'],
  'each is logged once, as first given');
select throws_ok($$ insert into public.account_agreements (kind, text_version, context)
                    values ('terms', 'terms-draft-v1', 'join') $$,
  '42501', null, 'nobody writes the log directly');
select is(public.my_agreements() -> 'terms' ->> 'satisfied', 'true', 'the app hears the Terms are agreed');
select is(public.my_agreements() -> 'terms' ->> 'agreed', 'terms-draft-v1', 'and to which wording');

select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben, in the same household
select is((select count(*)::int from public.account_agreements), 0, 'another account reads none of it');
select throws_ok($$ select public.my_agreements('00000000-0000-0000-0000-0000000000f0') $$, '42501', null,
  'and the app asks only about its own household');
select is(public.my_access_hold(), null, 'an account that isn''t held has no hold');

select pg_temp.as_admin();
update public.agreement_versions set effective_at = now() where version in ('terms-draft-v1', 'privacy-draft-v1');
select pg_temp.as_user('b0000000-0000-0000-0000-00000000000b');  -- Ben
select is(public.my_agreements() -> 'terms' ->> 'satisfied', 'false',
  'once the Terms are in force, someone who hasn''t agreed is asked');
select is(public.my_agreements() -> 'privacy' ->> 'current', 'privacy-draft-v1', 'with the wording to show');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');  -- Ann
select is(public.my_agreements() -> 'privacy' ->> 'satisfied', 'true', 'and someone who agreed isn''t');

select pg_temp.as_anon();
select throws_ok($$ select 1 from public.account_agreements $$, '42501', null, 'signed out, nobody reads it');
select throws_ok($$ select public.my_agreements() $$, '42501', null, 'or asks');

select pg_temp.as_admin();
delete from auth.users where id = 'a0000000-0000-0000-0000-00000000000a';
select is((select count(*)::int from public.account_agreements where user_id = 'a0000000-0000-0000-0000-00000000000a'), 2,
  'the record outlives the account, as proof');

select * from finish();
rollback;
