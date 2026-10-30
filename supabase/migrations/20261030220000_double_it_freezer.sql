-- Double it and the freezer stash (#53).
-- 1. Double it: plan_nights.leftovers_from links a leftovers night to the night cooking twice as much. The link is the
--    only record: a night is doubled because a leftovers night points at it, so the two can't disagree. The list isn't
--    touched here. The app rebuilds a week's lines from the plan and approve_plan refreshes only that week's own lines, so
--    a scale can't compound, and undoing it is the same Update the list as any other change. A line can be shared with
--    another week, a staple, or a hand-add, so nothing here scales or deletes by plan_id.
--    double_it and undo_double_it lock both nights and check what the device saw. leftovers_restore holds what the
--    leftovers night held before, so an undo puts it back. Both nights are saved locked, as any planner's pick is.
-- 2. Every other way a night changes goes through triggers, so Swap, Plan it, Build, away dates, We had something else,
--    and an older app (which writes meal_id, quick_pick, reason and locked directly and has never heard of the link) all
--    agree. A different dish on the doubled night takes its leftovers night back to what it held; a different pick on the
--    leftovers night ends the link and keeps the pick. Nights already past keep what was eaten.
-- 3. freezer_stash: one row per dinner cooked ahead, always a library dish, so its allergy flags and sides come along.
--    Household-owned, and only functions write it: anyone in the family adds to it and uses it up; only planners plan a
--    night from it (use_freezer_item, which locks the item, so two phones offered the same one can't both have it). An
--    item leaves through state ('used' or 'archived') and is never deleted. plan_nights.stash_item_id says which night it's
--    on; a night that changes dish puts it back.
--
-- Errors the app words itself: FD001 the night changed since this device saw it (or can't be doubled); FD002 the item's
-- already gone or planned; FD003 the item can't go on that night (retired, archived, or made after it).

create table public.freezer_stash (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  meal_id uuid not null,
  made_on date not null,
  -- Text, not an enum: an older build decoding a state it doesn't know treats the item as gone rather than failing.
  state text not null default 'in' check (state in ('in', 'used', 'archived')),
  state_changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (meal_id, household_id) references public.meals (id, household_id),
  constraint freezer_stash_id_household_key unique (id, household_id)
);

create index freezer_stash_household_idx on public.freezer_stash (household_id, state);

revoke all on public.freezer_stash from anon, authenticated;
grant select on public.freezer_stash to authenticated;

alter table public.freezer_stash enable row level security;

create policy "members read the freezer" on public.freezer_stash
  for select to authenticated using (public.is_household_member(household_id));

-- Not granted to anyone: only the functions below and their triggers write these.
alter table public.plan_nights
  add column leftovers_from uuid,
  add column leftovers_restore jsonb,
  add column stash_item_id uuid,
  add constraint plan_nights_leftovers_from_fkey foreign key (leftovers_from, household_id)
    references public.plan_nights (id, household_id),
  add constraint plan_nights_stash_item_fkey foreign key (stash_item_id, household_id)
    references public.freezer_stash (id, household_id),
  add constraint plan_nights_leftovers_are_leftovers check (leftovers_from is null or quick_pick = 'leftovers'),
  add constraint plan_nights_stash_has_a_dish check (stash_item_id is null or meal_id is not null);

create unique index plan_nights_one_leftovers_night on public.plan_nights (leftovers_from) where leftovers_from is not null;
create unique index plan_nights_one_stash_night on public.plan_nights (stash_item_id) where stash_item_id is not null;

-- Takes a leftovers night back to what it held before. From today on: a dish no longer in rotation, or a night the family
-- is now away, stays empty. Past nights keep what was eaten and only lose the link.
create function public.unwind_leftovers_night(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  before jsonb;
  restored_meal uuid;
  restored_pick public.quick_pick;
begin
  select * into night from public.plan_nights where id = target for update;
  if night.date < public.household_today(night.household_id) then
    update public.plan_nights set leftovers_from = null, leftovers_restore = null where id = target;
    return;
  end if;

  before := coalesce(night.leftovers_restore, '{}');
  restored_meal := (before ->> 'meal_id')::uuid;
  restored_pick := (before ->> 'quick_pick')::public.quick_pick;
  if restored_meal is not null
     and not exists (select 1 from public.meals m where m.id = restored_meal and m.status in ('active', 'trial')) then
    restored_meal := null;
  end if;
  if public.household_away_on(night.household_id, night.date) then
    restored_meal := null;
    restored_pick := null;
  end if;

  if restored_meal is null and restored_pick is null then
    update public.plan_nights
    set meal_id = null, quick_pick = null, reason = null, locked = false, leftovers_from = null, leftovers_restore = null
    where id = target;
  else
    update public.plan_nights
    set meal_id = restored_meal, quick_pick = restored_pick, reason = before ->> 'reason',
        locked = coalesce((before ->> 'locked')::boolean, false), leftovers_from = null, leftovers_restore = null
    where id = target;
  end if;
end;
$$;

revoke execute on function public.unwind_leftovers_night(uuid) from public, anon, authenticated;

-- Ends the links this write makes untrue, in the row itself.
create function public.plan_nights_end_stale_links()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.leftovers_from is not null and (new.quick_pick is distinct from 'leftovers' or new.meal_id is not null) then
    new.leftovers_from := null;
    new.leftovers_restore := null;
  end if;
  if old.stash_item_id is not null and new.stash_item_id = old.stash_item_id and new.meal_id is distinct from old.meal_id then
    new.stash_item_id := null;
  end if;
  return new;
end;
$$;

create trigger plan_nights_end_stale_links before update of meal_id, quick_pick on public.plan_nights
  for each row execute function public.plan_nights_end_stale_links();

-- And what they meant elsewhere. Security definer: a planner has no direct write to the stash or the link.
create function public.plan_nights_follow_links()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.meal_id is distinct from old.meal_id then
    perform public.unwind_leftovers_night(l.id) from public.plan_nights l where l.leftovers_from = new.id;
  end if;
  if old.stash_item_id is not null and new.stash_item_id is distinct from old.stash_item_id then
    update public.freezer_stash set state = 'in', state_changed_at = now() where id = old.stash_item_id and state = 'used';
  end if;
  return null;
end;
$$;

revoke execute on function public.plan_nights_follow_links() from public, anon, authenticated;

create trigger plan_nights_follow_links after update of meal_id, quick_pick on public.plan_nights
  for each row execute function public.plan_nights_follow_links();

-- Cooks twice as much on one night and plans the leftovers on a later night in the same week. The device says what it saw
-- on both, so a stale phone can't double a dish that's been swapped or plan over something it never saw.
create function public.double_it(target_night uuid, leftovers_night uuid, expected_meal uuid, expected_leftovers_meal uuid,
                                 expected_leftovers_pick public.quick_pick)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  dish public.plan_nights;
  later public.plan_nights;
  today date;
begin
  -- Under one order, so two planners doubling at once can't deadlock.
  perform 1 from public.plan_nights where id in (target_night, leftovers_night) order by id for update;

  select * into dish from public.plan_nights n where n.id = target_night and public.is_household_member(n.household_id);
  if dish.id is null then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if not public.is_household_planner(dish.household_id) then
    raise exception 'only planners double a night' using errcode = '42501';
  end if;
  select * into later from public.plan_nights where id = leftovers_night and plan_id = dish.plan_id;
  today := public.household_today(dish.household_id);

  if later.id is null or later.date <= dish.date or dish.date < today then
    raise exception 'leftovers go on a later night in the same week, from today on' using errcode = 'FD001';
  end if;
  if dish.meal_id is null or dish.meal_id is distinct from expected_meal or dish.stash_item_id is not null then
    raise exception 'that night isn''t the dish this device saw, or came from the freezer' using errcode = 'FD001';
  end if;
  if (later.meal_id, later.quick_pick) is distinct from (expected_leftovers_meal, expected_leftovers_pick) then
    raise exception 'the leftovers night isn''t what this device saw' using errcode = 'FD001';
  end if;
  if exists (select 1 from public.plan_nights n where n.leftovers_from = dish.id)
     or exists (select 1 from public.plan_nights n where n.leftovers_from = later.id)
     or later.leftovers_from is not null or later.stash_item_id is not null or later.effort = 'event'
     or (later.locked and later.quick_pick is distinct from 'leftovers') then
    raise exception 'that night can''t take the leftovers' using errcode = 'FD001';
  end if;
  if public.household_away_on(later.household_id, later.date) then
    raise exception 'the family is away that night' using errcode = '22023';
  end if;

  update public.plan_nights
  set meal_id = null, quick_pick = 'leftovers', reason = null, locked = true, leftovers_from = dish.id,
      leftovers_restore = jsonb_build_object('meal_id', later.meal_id, 'quick_pick', later.quick_pick,
                                             'reason', later.reason, 'locked', later.locked, 'dish_locked', dish.locked)
  where id = later.id;
  update public.plan_nights set locked = true where id = dish.id;
end;
$$;

revoke execute on function public.double_it(uuid, uuid, uuid, uuid, public.quick_pick) from public, anon;
grant execute on function public.double_it(uuid, uuid, uuid, uuid, public.quick_pick) to authenticated;

-- Nothing doubled any more is nothing to do: another device got there first.
create function public.undo_double_it(target_night uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  dish public.plan_nights;
  later public.plan_nights;
begin
  select * into dish from public.plan_nights n where n.id = target_night and public.is_household_member(n.household_id);
  if dish.id is null then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if not public.is_household_planner(dish.household_id) then
    raise exception 'only planners undo it' using errcode = '42501';
  end if;

  perform 1 from public.plan_nights n where n.id = target_night or n.leftovers_from = target_night order by n.id for update;
  select * into later from public.plan_nights n where n.leftovers_from = target_night;
  if later.id is null then
    return;
  end if;
  update public.plan_nights
  set locked = coalesce((later.leftovers_restore ->> 'dish_locked')::boolean, locked)
  where id = target_night;
  perform public.unwind_leftovers_night(later.id);
end;
$$;

revoke execute on function public.undo_double_it(uuid) from public, anon;
grant execute on function public.undo_double_it(uuid) to authenticated;

-- Anyone in the family, whoever cooked it. "Made on" can't be after the household's today.
create function public.add_to_freezer(target_household uuid, target_meal uuid, made date)
returns public.freezer_stash
language plpgsql security definer set search_path = ''
as $$
declare
  added public.freezer_stash;
begin
  if not public.is_household_member(target_household) then
    raise exception 'only the family adds to its freezer' using errcode = '42501';
  end if;
  if not exists (select 1 from public.meals m where m.id = target_meal and m.household_id = target_household) then
    raise exception 'no dish %', target_meal using errcode = 'P0002';
  end if;
  if made is null or not isfinite(made) or made > public.household_today(target_household) then
    raise exception 'a dish in the freezer has been made' using errcode = '22023';
  end if;
  insert into public.freezer_stash (household_id, meal_id, made_on)
  values (target_household, target_meal, made)
  returning * into added;
  return added;
end;
$$;

revoke execute on function public.add_to_freezer(uuid, uuid, date) from public, anon;
grant execute on function public.add_to_freezer(uuid, uuid, date) to authenticated;

-- Used up, archived, or put back; anyone in the family. An item planned on a night comes back by changing the night, and
-- what's gone on another phone stays gone until someone puts it back.
create function public.set_freezer_item(target_item uuid, new_state text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  item public.freezer_stash;
begin
  if new_state not in ('in', 'used', 'archived') then
    raise exception 'no such state' using errcode = '22023';
  end if;
  select * into item from public.freezer_stash s
  where s.id = target_item and public.is_household_member(s.household_id) for update;
  if item.id is null then
    raise exception 'no item %', target_item using errcode = 'P0002';
  end if;
  if item.state = new_state then
    return;
  end if;
  if (item.state <> 'in' and new_state <> 'in')
     or exists (select 1 from public.plan_nights n where n.stash_item_id = item.id) then
    raise exception 'that item has already gone' using errcode = 'FD002';
  end if;
  update public.freezer_stash set state = new_state, state_changed_at = now() where id = item.id;
end;
$$;

revoke execute on function public.set_freezer_item(uuid, text) from public, anon;
grant execute on function public.set_freezer_item(uuid, text) to authenticated;

-- Puts a stash item on a night, the way Swap puts a dish there: the planner's pick, locked. Allergy flags and dislikes are
-- the app's to show; what's checked here is what would make the pick untrue. Security definer, so it asks the away rule
-- itself: plan_nights_refuse_away only looks at the app's own writes.
create function public.use_freezer_item(target_night uuid, target_item uuid, night_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  item public.freezer_stash;
  today date;
begin
  select * into night from public.plan_nights n
  where n.id = target_night and public.is_household_member(n.household_id) for update;
  if night.id is null then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if not public.is_household_planner(night.household_id) then
    raise exception 'only planners plan a night' using errcode = '42501';
  end if;
  select * into item from public.freezer_stash s
  where s.id = target_item and s.household_id = night.household_id for update;
  if item.id is null then
    raise exception 'no item %', target_item using errcode = 'P0002';
  end if;
  if item.state <> 'in' then
    raise exception 'that item has already gone' using errcode = 'FD002';
  end if;
  if item.made_on > night.date
     or not exists (select 1 from public.meals m where m.id = item.meal_id and m.status in ('active', 'trial')) then
    raise exception 'that item can''t go on that night' using errcode = 'FD003';
  end if;
  today := public.household_today(night.household_id);
  if (night.date > today or (night.date = today and night.meal_id is null and night.quick_pick is null))
     and public.household_away_on(night.household_id, night.date) then
    raise exception 'the family is away that night' using errcode = '22023';
  end if;

  update public.freezer_stash set state = 'used', state_changed_at = now() where id = item.id;
  update public.plan_nights
  set meal_id = item.meal_id, quick_pick = null, reason = left(nullif(btrim(night_reason), ''), 80), locked = true,
      stash_item_id = item.id
  where id = night.id;
end;
$$;

revoke execute on function public.use_freezer_item(uuid, uuid, text) from public, anon;
grant execute on function public.use_freezer_item(uuid, uuid, text) to authenticated;

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.attendance_templates where household_id = target;
  delete from public.request_plus_ones where household_id = target;
  delete from public.requests where household_id = target;
  delete from public.serving_notes where household_id = target;
  delete from public.chef_thanks where household_id = target;
  delete from public.reactions where household_id = target;
  delete from public.meal_logs where household_id = target;
  delete from public.night_attendance where household_id = target;
  delete from public.list_items where household_id = target;
  delete from public.plan_nights where household_id = target;
  delete from public.freezer_stash where household_id = target;
  delete from public.plans where household_id = target;
  delete from public.traditions where household_id = target;
  delete from public.meal_sides where household_id = target;
  delete from public.meal_ingredients where household_id = target;
  delete from public.meals where household_id = target;
  delete from public.items where household_id = target;
  delete from public.member_allergies where household_id = target;
  delete from public.invites where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;

create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners export the household' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'household', (select to_jsonb(h) - 'owner' from public.households h where id = target_household),
    'members', (select coalesce(jsonb_agg(to_jsonb(m) - 'user_id' - 'household_id' order by m.created_at), '[]')
                from public.members m where household_id = target_household),
    'allergies', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                  from public.member_allergies a where household_id = target_household),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' - 'granted_by' order by c.granted_at), '[]')
                 from public.consents c where household_id = target_household),
    'meals', (select coalesce(jsonb_agg(to_jsonb(m) - 'household_id' order by m.name), '[]')
              from public.meals m where household_id = target_household),
    'meal_ingredients', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id'), '[]')
                         from public.meal_ingredients i where household_id = target_household),
    'meal_sides', (select coalesce(jsonb_agg(to_jsonb(s) - 'household_id'), '[]')
                   from public.meal_sides s where household_id = target_household),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id' order by i.canonical_name), '[]')
              from public.items i where household_id = target_household),
    'traditions', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id'), '[]')
                   from public.traditions t where household_id = target_household),
    'plans', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.week_start), '[]')
              from public.plans p where household_id = target_household),
    'nights', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.date), '[]')
               from public.plan_nights n where household_id = target_household),
    'attendance', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                   from public.night_attendance a where household_id = target_household),
    'list_items', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id'), '[]')
                   from public.list_items l where household_id = target_household),
    'meal_logs', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                  from public.meal_logs l where household_id = target_household),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                  from public.reactions r where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household),
    'attendance_templates', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                             from public.attendance_templates t where household_id = target_household),
    'freezer_stash', (select coalesce(jsonb_agg(to_jsonb(f) - 'household_id' order by f.created_at), '[]')
                      from public.freezer_stash f where household_id = target_household)
  );
end;
$$;
