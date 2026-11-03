-- A store run is ten minutes exactly: its start and end come from one reading of the clock. Two separate calls to
-- clock_timestamp() could land a microsecond apart, making some runs 10:00.000001 (the flaky pgTAP 57 test 7).
-- Otherwise unchanged from 20261102210000_store_run.

create or replace function public.start_store_run(target_household uuid)
returns public.store_runs
language plpgsql security definer set search_path = ''
as $$
declare
  me public.members;
  run public.store_runs;
  started timestamptz;
begin
  select * into me from public.members
  where id = public.my_member_id(target_household);
  if me.id is null then
    raise exception 'not a member of this household' using errcode = '42501';
  end if;
  if me.age_group <> 'adult' then
    raise exception 'an adult heads to the store' using errcode = '42501';
  end if;

  perform 1 from public.households where id = target_household for no key update;
  -- Once, after the lock, as before: a run that waited on another starts when it got its turn.
  started := clock_timestamp();
  select * into run from public.store_runs
  where household_id = target_household and ends_at > started
  order by ends_at desc limit 1;
  if run.id is not null then
    return run;
  end if;

  insert into public.store_runs (household_id, started_by, started_at, ends_at)
  values (target_household, me.id, started, started + interval '10 minutes')
  returning * into run;
  return run;
end;
$$;
