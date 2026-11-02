-- Heading to the store (#51): one tap tells the family someone's at the store, so they can add anything in the next 10
-- minutes; what's added in that time is marked "Just added" in store mode.
-- 1. store_runs: one row per run, written only by start_store_run. Any adult in the family starts one; kids can't. One at a
--    time per household: starting while one is open hands back the open one and sends nothing. Members read their own
--    household's runs; nobody writes them directly. A run is only news for 10 minutes, so a day later it's pruned.
-- 2. Push 'heading_to_store' (a kind both lists have held since the log was made): "Ben's at the store." / "Add anything in
--    the next 10 minutes." to everyone else in the family with a device who isn't travelling, on Engaged only, not on an away day. Quiet hours per person (kid hours for kids); one they'd hold past the run's
--    end isn't queued, and what isn't sent by then is given up. A tap opens Lists. It ranks with urgent items for budgets.
--    Removal and retention follow the other kinds: members_drop_push_devices deletes rows to or about someone who leaves.

-- Runs ------------------------------------------------------------------------------------------------------------------------

create table public.store_runs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  -- Set null, not cascade: a run outlives nobody, and it's pruned within a day anyway.
  started_by uuid references public.members (id) on delete set null,
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  constraint store_runs_ends_after_start check (ends_at > started_at)
);

create index store_runs_household_idx on public.store_runs (household_id, ends_at desc);
create index store_runs_started_by_idx on public.store_runs (started_by);

revoke all on public.store_runs from anon, authenticated;
grant select on public.store_runs to authenticated;

alter table public.store_runs enable row level security;

create policy "members read store runs" on public.store_runs
  for select to authenticated using (public.is_household_member(household_id));

-- The open run, or a new one. Locks the household row so two adults tapping at once line up and get one run, and one push.
-- `for no key update`: enough to line up taps with each other, without blocking writes that only reference the household
-- (a list line going on during the run).
create function public.start_store_run(target_household uuid)
returns public.store_runs
language plpgsql security definer set search_path = ''
as $$
declare
  me public.members;
  run public.store_runs;
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
  select * into run from public.store_runs
  where household_id = target_household and ends_at > clock_timestamp()
  order by ends_at desc limit 1;
  if run.id is not null then
    return run;
  end if;

  insert into public.store_runs (household_id, started_by, started_at, ends_at)
  values (target_household, me.id, clock_timestamp(), clock_timestamp() + interval '10 minutes')
  returning * into run;
  return run;
end;
$$;

revoke execute on function public.start_store_run(uuid) from public, anon;
grant execute on function public.start_store_run(uuid) to authenticated;

-- Push ------------------------------------------------------------------------------------------------------------------------

create function public.store_runs_enqueue_push()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  tz text := public.household_time_zone(new.household_id);
  starter public.members;
begin
  if public.household_notification_preset(new.household_id) <> 'engaged'
     or public.household_away_on(new.household_id, (now() at time zone tz)::date) then
    return null;
  end if;
  select * into starter from public.members where id = new.started_by and status <> 'removed';
  if starter.id is null then
    return null;
  end if;

  insert into public.push_outbox
    (household_id, member_id, kind, about_member_id, args, not_before, expires_at)
  select m.household_id, m.id, 'heading_to_store', starter.id, jsonb_build_object('name', starter.first_name),
         held.not_before, new.ends_at
  from public.members m
  cross join lateral (select public.push_not_before(tz, m.age_group = 'kid', now()) as not_before) held
  where m.household_id = new.household_id and m.status <> 'removed' and m.id <> starter.id
    -- Travelling (the rule urgent items use): nothing to add from away.
    and not (m.status = 'away' and (m.away_until is null or (now() at time zone tz)::date < m.away_until))
    and held.not_before < new.ends_at
    and exists (select 1 from public.push_devices d where d.member_id = m.id);
  return null;
end;
$$;

revoke execute on function public.store_runs_enqueue_push() from public, anon, authenticated;

create trigger store_runs_enqueue_push after insert on public.store_runs
  for each row execute function public.store_runs_enqueue_push();

-- Budgets: a run is over in 10 minutes, so it goes first, with urgent items.
create or replace function public.push_kind_rank(row_kind text)
returns int
language sql immutable set search_path = ''
as $$
  select case row_kind
    when 'plan_set' then 0 when 'urgent_item' then 0 when 'heading_to_store' then 0
    when 'not_home' then 1 when 'claim' then 1
    when 'tonight_poll' then 2
    else 3
  end;
$$;

-- Pruning: sent and failed pushes are kept eight weeks, like the log; a run is old news the next day.
create or replace function public.prune_push_outbox()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.push_outbox where created_at < now() - interval '8 weeks';
  delete from public.store_runs where ends_at < now() - interval '1 day';
$$;
