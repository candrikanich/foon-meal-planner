-- Receipt aliases (#61): anyone in the family, kids too, teaches a receipt line's item; a correction moves it, nothing
-- deletes it; another household can't read, teach or correct it.
begin;
select plan(20);

create function pg_temp.as_user(uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users (id, email, aud, role) values
  ('a0000000-0000-0000-0000-00000000000a', 'alice@example.com', 'authenticated', 'authenticated'),
  ('e0000000-0000-0000-0000-00000000000e', 'kim@example.com', 'authenticated', 'authenticated'),
  ('c0000000-0000-0000-0000-00000000000c', 'carol@example.com', 'authenticated', 'authenticated');
insert into public.households (id, name, owner) values
  ('00000000-0000-0000-0000-0000000000a0', 'Andersons', 'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000b0', 'Carters', 'c0000000-0000-0000-0000-00000000000c');
insert into public.members (id, household_id, first_name, role, guardian, age_group, user_id) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a0', 'Alice', 'planner', true, 'adult',
   'a0000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a0', 'Kim', 'member', false, 'kid',
   'e0000000-0000-0000-0000-00000000000e'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b0', 'Carol', 'planner', true, 'adult',
   'c0000000-0000-0000-0000-00000000000c');
insert into public.items (id, household_id, canonical_name) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-0000000000a0', 'Chicken breasts'),
  ('00000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000a0', 'Chicken thighs'),
  ('00000000-0000-0000-0000-0000000001c1', '00000000-0000-0000-0000-0000000000b0', 'Milk');

select has_table('public', 'receipt_aliases', 'receipt aliases are a table');
select hasnt_table('public', 'receipts', 'no receipt is stored');
select hasnt_table('public', 'receipt_lines', 'nor its lines');

-- A kid teaches the household ------------------------------------------------------------------------------------------
select pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
select is((public.teach_receipt_alias('00000000-0000-0000-0000-0000000000a0', '  BNLS CHKN BRST ',
            '00000000-0000-0000-0000-0000000001a1')).raw_text,
  'bnls chkn brst', 'a kid teaches a line, normalized');
select is((select created_by from public.receipt_aliases where raw_text = 'bnls chkn brst'),
  '00000000-0000-0000-0000-0000000000a3'::uuid, 'who taught it is their profile');

-- Correcting it moves it, and keeps one row ---------------------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.receipt_aliases), 1, 'the family reads what was taught');
select lives_ok($$ select public.teach_receipt_alias('00000000-0000-0000-0000-0000000000a0', 'bnls chkn brst',
                  '00000000-0000-0000-0000-0000000001a2') $$, 'teaching the same line again corrects it');
select is((select item_id from public.receipt_aliases where raw_text = 'bnls chkn brst'),
  '00000000-0000-0000-0000-0000000001a2'::uuid, 'it now points at the corrected item');
select is((select count(*)::int from public.receipt_aliases), 1, 'still one alias for that line');
select is((select created_by from public.receipt_aliases where raw_text = 'bnls chkn brst'),
  '00000000-0000-0000-0000-0000000000a3'::uuid, 'who first taught it stays');

-- Never deleted, and nobody writes someone else's name on one -----------------------------------------------------------
select throws_ok($$ delete from public.receipt_aliases $$, '42501', null, 'nobody can delete an alias');
select throws_ok(
  $$ insert into public.receipt_aliases (household_id, raw_text, item_id, created_by) values
       ('00000000-0000-0000-0000-0000000000a0', 'gv whl milk', '00000000-0000-0000-0000-0000000001a1',
        '00000000-0000-0000-0000-0000000000a3') $$,
  '42501', null, 'an alias can''t be put in someone else''s name');
select throws_ok(
  $$ select public.teach_receipt_alias('00000000-0000-0000-0000-0000000000a0', 'whole milk',
       '00000000-0000-0000-0000-0000000001c1') $$,
  '23503', null, 'an alias points only at the household''s own item');
select throws_ok(
  $$ select public.teach_receipt_alias('00000000-0000-0000-0000-0000000000a0', '   ',
       '00000000-0000-0000-0000-0000000001a1') $$,
  '23514', null, 'a blank line is not taught');

-- Another household reads and writes nothing ---------------------------------------------------------------------------
select pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
select is_empty($$ select 1 from public.receipt_aliases $$, 'another household reads none of it');
select throws_ok(
  $$ select public.teach_receipt_alias('00000000-0000-0000-0000-0000000000a0', 'org bananas',
       '00000000-0000-0000-0000-0000000001a1') $$,
  '42501', null, 'another household can''t teach this one');
update public.receipt_aliases set item_id = '00000000-0000-0000-0000-0000000001a1';
select lives_ok($$ select public.teach_receipt_alias('00000000-0000-0000-0000-0000000000b0', 'bnls chkn brst',
                  '00000000-0000-0000-0000-0000000001c1') $$, 'the same text is its own alias in another household');
reset role;
select is((select item_id from public.receipt_aliases
           where household_id = '00000000-0000-0000-0000-0000000000a0' and raw_text = 'bnls chkn brst'),
  '00000000-0000-0000-0000-0000000001a2'::uuid, 'another household can''t correct this one');
select is((select count(*)::int from public.receipt_aliases), 2, 'one alias per household');
select pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
select is(public.export_household('00000000-0000-0000-0000-0000000000a0') -> 'receipt_aliases' -> 0 ->> 'raw_text',
  'bnls chkn brst', 'the export holds the household''s own corrections and no one else''s');
reset role;

select * from finish();
rollback;
