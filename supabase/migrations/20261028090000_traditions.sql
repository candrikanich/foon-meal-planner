-- Standing traditions (#31): Taco Tuesday, Pizza Friday. One per weekday per household: a meal from the
-- library or a quick pick, with an optional name for the chip. Build my week fills them in and locks them;
-- a swap changes just that week. Traditions are settings, so removing one deletes the row.
-- set_nights gains an optional "locked" per night, so Build can save tradition nights locked.

create table public.traditions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  weekday smallint not null check (weekday between 1 and 7),
  meal_id uuid,
  quick_pick public.quick_pick,
  name text check (char_length(btrim(name)) between 1 and 40),
  created_at timestamptz not null default now(),
  constraint traditions_meal_fkey foreign key (meal_id, household_id) references public.meals (id, household_id),
  constraint traditions_one_kind check ((meal_id is null) <> (quick_pick is null)),
  constraint traditions_one_per_weekday unique (household_id, weekday)
);

revoke all on public.traditions from anon, authenticated;
grant select, delete on public.traditions to authenticated;
grant insert (id, household_id, weekday, meal_id, quick_pick, name) on public.traditions to authenticated;
grant update (meal_id, quick_pick, name) on public.traditions to authenticated;

alter table public.traditions enable row level security;

create policy "members read traditions" on public.traditions
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "planners add traditions" on public.traditions
  for insert to authenticated with check (public.is_household_planner(household_id));
create policy "planners edit traditions" on public.traditions
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));
create policy "planners remove traditions" on public.traditions
  for delete to authenticated using (public.is_household_planner(household_id));

-- Sets or replaces a weekday's tradition in one statement, so two taps (or two planners) can't race into a
-- duplicate. Row-level security still applies; the planner check gives a clear error.
create function public.set_tradition(
  target_household uuid, tradition_weekday smallint, tradition_meal uuid, tradition_quick_pick public.quick_pick,
  tradition_name text
)
returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners set traditions' using errcode = '42501';
  end if;
  insert into public.traditions as existing (household_id, weekday, meal_id, quick_pick, name)
  values (target_household, tradition_weekday, tradition_meal, tradition_quick_pick, nullif(btrim(tradition_name), ''))
  on conflict (household_id, weekday) do update
    set meal_id = excluded.meal_id, quick_pick = excluded.quick_pick, name = excluded.name;
end;
$$;

revoke execute on function public.set_tradition(uuid, smallint, uuid, public.quick_pick, text) from public, anon;
grant execute on function public.set_tradition(uuid, smallint, uuid, public.quick_pick, text) to authenticated;

create or replace function public.set_nights(target_plan uuid, nights jsonb)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
  night jsonb;
begin
  -- Under the caller's row-level security another household's plan is simply not found.
  select household_id into household from public.plans where id = target_plan;
  if household is null then
    raise exception 'no plan %', target_plan using errcode = 'P0002';
  end if;
  if not public.is_household_planner(household) then
    raise exception 'only planners plan nights' using errcode = '42501';
  end if;
  if jsonb_typeof(nights) is distinct from 'array' then
    raise exception 'nights must be a JSON array' using errcode = '22023';
  end if;

  for night in select * from jsonb_array_elements(nights) loop
    update public.plan_nights
    set meal_id = (night ->> 'meal_id')::uuid,
        quick_pick = (night ->> 'quick_pick')::public.quick_pick,
        reason = nullif(btrim(night ->> 'reason'), ''),
        locked = coalesce((night ->> 'locked')::boolean, false)
    where id = (night ->> 'id')::uuid and plan_id = target_plan and not locked;
    if not found then
      raise exception 'night % is locked or not in plan %', night ->> 'id', target_plan using errcode = 'P0002';
    end if;
  end loop;
end;
$$;
