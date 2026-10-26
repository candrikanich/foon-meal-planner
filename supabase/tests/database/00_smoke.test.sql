-- Proves the pgTAP harness runs; RLS tests for each household table live alongside this file.
begin;
select plan(2);

select has_extension('pgtap', 'pgTAP is installed for the test run');
select has_schema('public', 'public schema exists');

select * from finish();
rollback;
