-- Founding families (#37): households created while founding is open are flagged on the server; clients can't
-- read or change the switch, or set the flag themselves.
begin;
select plan(10);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('d0000000-0000-0000-0000-00000000000d', 'dave@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'erin@example.com', 'authenticated', 'authenticated'),
  ('f0000000-0000-0000-0000-00000000000f', 'fay@example.com', 'authenticated', 'authenticated');

select is((select founding_open from public.app_config), true, 'founding is open during the beta');

select pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
select is((public.create_household('The Daltons', null, 'Dave')).founding, true,
  'a household made while it''s open is a founding family');
select throws_ok($$ select 1 from public.app_config $$, '42501', null, 'clients can''t read the switch');
select throws_ok($$ update public.app_config set founding_open = false $$, '42501', null, 'or flip it');

reset role;
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select throws_ok($$ insert into public.households (name, founding) values ('Sneaky', true) $$, '42501', null,
  'and can''t set the flag themselves');

-- Launch: founding closes (a migration flips it). Households already flagged keep it.
reset role;
update public.app_config set founding_open = false;
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((public.create_household('The Ellises', null, 'Erin')).founding, false,
  'after it closes, new households aren''t founding families');
reset role;
select is((select founding from public.households where name = 'The Daltons'), true, 'the Daltons keep theirs');
insert into public.households (name, owner, founding) values ('Closed', null, true);
select is((select founding from public.households where name = 'Closed'), false, 'the trigger decides, even over a role that can write the column');

-- The switch decides at insert time, every time.
update public.app_config set founding_open = true;
select pg_temp.as_user('f0000000-0000-0000-0000-00000000000f');
select is((public.create_household('The Fays', null, 'Fay')).founding, true, 'open again, flagged again');
reset role;
insert into public.households (name, owner, founding) values ('Open', null, false);
select is((select founding from public.households where name = 'Open'), true, 'and while open, nobody opts a new household out');

select * from finish();
rollback;
