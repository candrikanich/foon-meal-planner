-- Plans, nights, attendance, and list items for the Sunday flow (#6).
-- Planners own the plan and attendance; everyone works the list. Plans and nights are the
-- household's dinner log, so they are never deleted. List items are to-dos and can be removed.

create type public.night_effort as enum ('normal', 'rushed', 'full', 'event');
create type public.quick_pick as enum ('leftovers', 'takeout', 'eat_out', 'fend_for_yourselves', 'freezer_raid');
create type public.list_kind as enum ('weekly', 'quick');
create type public.list_urgency as enum ('tonight', 'whenever');
create type public.list_item_source as enum ('plan', 'pivot', 'staple', 'manual', 'shared');

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  -- The household's shopping day; a plan covers week_start through week_start + 6.
  week_start date not null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint plans_one_per_week unique (household_id, week_start),
  constraint plans_id_household_key unique (id, household_id)
);

create table public.plan_nights (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  plan_id uuid not null,
  date date not null,
  effort public.night_effort not null default 'normal',
  dinner_time time,
  meal_id uuid,
  quick_pick public.quick_pick,
  locked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (plan_id, household_id) references public.plans (id, household_id),
  foreign key (meal_id, household_id) references public.meals (id, household_id),
  constraint plan_nights_meal_or_quick_pick check (meal_id is null or quick_pick is null),
  constraint plan_nights_one_per_date unique (plan_id, date),
  constraint plan_nights_id_household_key unique (id, household_id)
);

create table public.night_attendance (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  plan_night_id uuid not null,
  member_id uuid not null,
  expected boolean not null default true,
  foreign key (plan_night_id, household_id) references public.plan_nights (id, household_id),
  foreign key (member_id, household_id) references public.members (id, household_id),
  constraint night_attendance_one_per_member unique (plan_night_id, member_id)
);

create index night_attendance_member_idx on public.night_attendance (member_id);

create table public.list_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  item_id uuid not null,
  list public.list_kind not null,
  urgency public.list_urgency not null default 'whenever',
  source public.list_item_source not null default 'manual',
  note text check (char_length(note) <= 140),
  checked_at timestamptz,
  checked_by uuid,
  created_at timestamptz not null default now(),
  foreign key (item_id, household_id) references public.items (id, household_id),
  foreign key (checked_by, household_id) references public.members (id, household_id),
  constraint list_items_checked_by_needs_checked_at check (checked_by is null or checked_at is not null)
);

-- Milk from a pivot and milk from a tap show once until someone checks it off.
create unique index list_items_one_open_per_item on public.list_items (household_id, list, item_id)
  where checked_at is null;

create trigger plans_set_updated_at before update on public.plans
  for each row execute function public.set_updated_at();
create trigger plan_nights_set_updated_at before update on public.plan_nights
  for each row execute function public.set_updated_at();

-- Guards --------------------------------------------------------------------------------------
-- Timestamps and check-off attribution come from the database, not the client.

create function public.plans_stamp_approval()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if (select auth.uid()) is null or new.approved_at is null then
    return new;
  end if;
  -- First approval is stamped now; re-sending it (stale cache, full-struct update) keeps the original.
  new.approved_at := case when old.approved_at is null then now() else old.approved_at end;
  return new;
end;
$$;

create trigger plans_stamp_approval before update on public.plans
  for each row execute function public.plans_stamp_approval();

create function public.plan_nights_within_week()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  start date;
begin
  select week_start into start from public.plans where id = new.plan_id;
  if new.date < start or new.date > start + 6 then
    raise exception 'a night falls inside its plan''s week' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger plan_nights_within_week before insert or update of date, plan_id on public.plan_nights
  for each row execute function public.plan_nights_within_week();

create function public.night_attendance_active_members()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if exists (select 1 from public.members where id = new.member_id and status = 'removed') then
    raise exception 'removed members are not part of attendance' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger night_attendance_active_members before insert or update of member_id on public.night_attendance
  for each row execute function public.night_attendance_active_members();

create function public.list_items_stamp_check()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;
  if new.checked_at is null then
    new.checked_by := null;
  elsif old.checked_at is null then
    new.checked_at := now();
    new.checked_by := (
      select id from public.members where household_id = new.household_id and user_id = (select auth.uid())
    );
  else
    -- Already checked: an offline replay or a second shopper's tap keeps the original stamp.
    new.checked_at := old.checked_at;
  end if;
  return new;
end;
$$;

create trigger list_items_stamp_check before update of checked_at on public.list_items
  for each row execute function public.list_items_stamp_check();

-- Grants ------------------------------------------------------------------------------------

revoke all on public.plans, public.plan_nights, public.night_attendance, public.list_items from anon, authenticated;

grant select on public.plans, public.plan_nights, public.night_attendance, public.list_items to authenticated;

grant insert (id, household_id, week_start) on public.plans to authenticated;
grant update (approved_at) on public.plans to authenticated;

grant insert (id, household_id, plan_id, date, effort, dinner_time, meal_id, quick_pick, locked)
  on public.plan_nights to authenticated;
grant update (effort, dinner_time, meal_id, quick_pick, locked) on public.plan_nights to authenticated;

grant insert (id, household_id, plan_night_id, member_id, expected) on public.night_attendance to authenticated;
grant update (expected) on public.night_attendance to authenticated;

grant insert (id, household_id, item_id, list, urgency, source, note) on public.list_items to authenticated;
grant update (list, urgency, note, checked_at) on public.list_items to authenticated;
grant delete on public.list_items to authenticated;

-- Policies ----------------------------------------------------------------------------------

alter table public.plans enable row level security;
alter table public.plan_nights enable row level security;
alter table public.night_attendance enable row level security;
alter table public.list_items enable row level security;

create policy "members read plans" on public.plans
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "planners start plans" on public.plans
  for insert to authenticated with check (public.is_household_planner(household_id));
create policy "planners approve plans" on public.plans
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));

create policy "members read nights" on public.plan_nights
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "planners add nights" on public.plan_nights
  for insert to authenticated with check (public.is_household_planner(household_id));
create policy "planners edit nights" on public.plan_nights
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));

-- Planners own attendance; real-life changes are reconciled by the day-of check-in (later).
create policy "members read attendance" on public.night_attendance
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "planners set attendance" on public.night_attendance
  for insert to authenticated with check (public.is_household_planner(household_id));
create policy "planners edit attendance" on public.night_attendance
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));

create policy "members read the list" on public.list_items
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members add to the list" on public.list_items
  for insert to authenticated
  with check (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members work the list" on public.list_items
  for update to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id))
  with check (public.is_household_member(household_id) or public.is_household_planner(household_id));
create policy "members remove list items" on public.list_items
  for delete to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));

-- Realtime ----------------------------------------------------------------------------------
-- Live check-offs in store mode. Inserts and updates are filtered by the select policy. Deletes
-- are not (Postgres can't check a row that no longer exists): every subscriber receives the bare id
-- of any deleted list item, so clients ignore deletes for ids they don't hold.
alter publication supabase_realtime add table public.list_items;

-- Add to a list, merging with the item's open entry ("milk from a pivot and milk from a tap show
-- once"). A PostgREST upsert can't target the partial unique index, so clients call this.
-- Urgency only goes up; an existing note is kept.
create function public.add_to_list(
  target_household uuid,
  target_item uuid,
  target_list public.list_kind,
  item_urgency public.list_urgency default 'whenever',
  item_source public.list_item_source default 'manual',
  item_note text default null
)
returns public.list_items
language sql security invoker set search_path = ''
as $$
  insert into public.list_items as existing (household_id, item_id, list, urgency, source, note)
  values (target_household, target_item, target_list, item_urgency, item_source, item_note)
  on conflict (household_id, list, item_id) where checked_at is null do update
    set urgency = case when excluded.urgency = 'tonight' then 'tonight'::public.list_urgency else existing.urgency end,
        note = coalesce(existing.note, excluded.note)
  returning *;
$$;

revoke execute on function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text)
  from public, anon;
grant execute on function public.add_to_list(uuid, uuid, public.list_kind, public.list_urgency, public.list_item_source, text)
  to authenticated;
