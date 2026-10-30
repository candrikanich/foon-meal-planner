-- Change history and undo (#57). Two planners shouldn't confuse each other.
-- 1. plan_changes: one row per night whose pick changed. A trigger on plan_nights writes it, so every writer is logged:
--    Swap and Plan it, set_nights, the functions, and an older app's direct PATCH. Who did it comes from the JWT, inside
--    security definer functions too. Only that trigger writes the table. Rows from one statement share created_at
--    (statement_timestamp), which is how the app shows a whole Build as one entry. What the system moved on its own says so:
--    kind 'away' (write_away_dates) and 'follow' (a leftovers night going back) have no actor. A failure in logging is
--    swallowed: the log must never block a plan write. Effort, attendance, and the lock aren't logged.
-- 2. undo_plan_change restores the night by the same write Swap makes, as the caller, so the grants, row-level security, and
--    every existing trigger do the work and there's no second way for linked things to get in step. It only ever undoes a
--    plain change that's still the night's last. It holds the night, compares what the night holds now with what the entry
--    says it became, and refuses otherwise. Undoing an undo isn't offered: Swap is there. The chip doesn't come back: the
--    log keeps no reason, since one can name a person ("Wren's request") and outlast them here.
--    Double it has its own undo, and a freezer night goes back through Swap. A change that ended a link isn't restorable,
--    since putting back the pick wouldn't put back the link.
-- 3. Eight weeks are kept: the daily retention job prunes the rest. Names come from members, so a removed person reads
--    "Former member" with no change here; what a withdrawn kid did themselves goes with their other data.
--
-- Errors the app words itself: FD012 the night has moved since this entry; FD013 this one can't be undone.

create table public.plan_changes (
  -- Order matters and timestamps tie within a statement, so the key is a sequence.
  id bigint generated always as identity primary key,
  household_id uuid not null references public.households (id),
  night_id uuid not null,
  -- Null when the system did it (kinds 'away' and 'follow'), or no profile made the write.
  actor_member_id uuid,
  -- Text, not an enum: an older build ignores a kind it doesn't know rather than failing.
  kind text not null check (kind in ('pick', 'doubled', 'undo_double', 'freezer', 'away', 'follow', 'undo')),
  -- For 'doubled' and 'follow': the night cooking twice as much.
  linked_date date,
  before_meal_id uuid,
  before_quick_pick public.quick_pick,
  before_locked boolean not null,
  after_meal_id uuid,
  after_quick_pick public.quick_pick,
  after_locked boolean not null,
  -- A plain change with no link on the night when it was made, so writing the old pick back restores all of it.
  restorable boolean not null default false,
  created_at timestamptz not null default statement_timestamp(),
  constraint plan_changes_night_fkey foreign key (night_id, household_id) references public.plan_nights (id, household_id),
  constraint plan_changes_actor_fkey foreign key (actor_member_id, household_id) references public.members (id, household_id),
  constraint plan_changes_before_meal_fkey foreign key (before_meal_id, household_id) references public.meals (id, household_id),
  constraint plan_changes_after_meal_fkey foreign key (after_meal_id, household_id) references public.meals (id, household_id)
);

create index plan_changes_household_idx on public.plan_changes (household_id, id desc);
create index plan_changes_night_idx on public.plan_changes (night_id, id desc);
create index plan_changes_created_idx on public.plan_changes (created_at);
create index plan_changes_actor_idx on public.plan_changes (actor_member_id);

revoke all on public.plan_changes from anon, authenticated;
grant select on public.plan_changes to authenticated;

alter table public.plan_changes enable row level security;

create policy "members read plan changes" on public.plan_changes
  for select to authenticated using (public.is_household_member(household_id));

-- Security definer: nobody writes the log directly. foon.plan_change_source is a transaction setting the functions below
-- raise while they write; clients have no way to set one, since set_config isn't exposed through the API.
create function public.plan_nights_log_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  source text := nullif(current_setting('foon.plan_change_source', true), '');
  pick_changed boolean := (new.meal_id, new.quick_pick) is distinct from (old.meal_id, old.quick_pick);
  change_kind text;
  linked date;
begin
  change_kind := case
    when source is not null then source
    when new.leftovers_from is not null and old.leftovers_from is null then 'doubled'
    -- Taken out again by a corrected log (a trigger, with no pick changing) isn't anyone planning it.
    when new.stash_item_id is not null and new.stash_item_id is distinct from old.stash_item_id
         and pg_trigger_depth() = 1 then 'freezer'
    when pick_changed then 'pick'
  end;
  -- Only a link ended, and the pick stays: a past night, or a leftovers night going back to leftovers.
  if change_kind is null or (change_kind in ('follow', 'away', 'undo') and not pick_changed) then
    return null;
  end if;

  if change_kind = 'doubled' then
    select date into linked from public.plan_nights where id = new.leftovers_from;
  elsif change_kind = 'follow' and old.leftovers_from is not null then
    select date into linked from public.plan_nights where id = old.leftovers_from;
  end if;

  insert into public.plan_changes (household_id, night_id, actor_member_id, kind, linked_date, before_meal_id,
                                   before_quick_pick, before_locked, after_meal_id, after_quick_pick,
                                   after_locked, restorable)
  values (new.household_id, new.id,
          case when change_kind in ('follow', 'away') then null else public.my_member_id(new.household_id) end,
          change_kind, linked, old.meal_id, old.quick_pick, old.locked, new.meal_id, new.quick_pick, new.locked,
          change_kind = 'pick' and old.leftovers_from is null and old.stash_item_id is null
            and not exists (select 1 from public.plan_nights l where l.leftovers_from = new.id));
  return null;
exception when others then
  raise warning 'plan change not logged for night %: %', new.id, sqlerrm;
  return null;
end;
$$;

revoke execute on function public.plan_nights_log_change() from public, anon, authenticated;

-- After triggers run in name order. This name sorts before plan_nights_follow_links, so a doubled dish's change is logged
-- while its leftovers night still points at it (restorable, above) and is listed before what follows from it.
create trigger plan_nights_changes_logged after update on public.plan_nights
  for each row when ((old.meal_id, old.quick_pick, old.leftovers_from, old.stash_item_id)
                     is distinct from (new.meal_id, new.quick_pick, new.leftovers_from, new.stash_item_id))
  execute function public.plan_nights_log_change();

-- As the caller, on purpose: it's the same write as Swap, under the same grants, policies, and away trigger.
create function public.undo_plan_change(target_change bigint)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  change public.plan_changes;
  night public.plan_nights;
begin
  select * into change from public.plan_changes where id = target_change;
  if change.id is null then
    raise exception 'no change %', target_change using errcode = 'P0002';
  end if;
  if not public.is_household_planner(change.household_id) then
    raise exception 'only planners undo a change' using errcode = '42501';
  end if;

  select * into night from public.plan_nights where id = change.night_id for update;

  if exists (select 1 from public.plan_changes c where c.night_id = night.id and c.id > change.id)
     or (night.meal_id, night.quick_pick, night.locked)
        is distinct from (change.after_meal_id, change.after_quick_pick, change.after_locked) then
    raise exception 'that night has moved since this change' using errcode = 'FD012';
  end if;
  if not change.restorable
     or night.date < public.household_today(night.household_id)
     or exists (select 1 from public.meal_logs l where l.night_id = night.id)
     or night.leftovers_from is not null or night.stash_item_id is not null
     or exists (select 1 from public.plan_nights l where l.leftovers_from = night.id)
     or (change.before_meal_id is not null
         and not exists (select 1 from public.meals m where m.id = change.before_meal_id and m.status in ('active', 'trial'))) then
    raise exception 'this change can''t be undone' using errcode = 'FD013';
  end if;
  if public.household_away_on(night.household_id, night.date) then
    raise exception 'the family is away that night' using errcode = '22023';
  end if;

  perform set_config('foon.plan_change_source', 'undo', true);
  update public.plan_nights
  set meal_id = change.before_meal_id, quick_pick = change.before_quick_pick, reason = null, locked = change.before_locked
  where id = night.id;
  perform set_config('foon.plan_change_source', '', true);
end;
$$;

revoke execute on function public.undo_plan_change(bigint) from public, anon;
grant execute on function public.undo_plan_change(bigint) to authenticated;

-- What's below only adds the setting that says who moved the night. --------------------------------------------------

-- As before, and whatever it writes is the system following a link, unless Undo Double it asked for it by name.
create or replace function public.unwind_leftovers_night(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  before jsonb;
  restored_meal uuid;
  restored_pick public.quick_pick;
  source text := current_setting('foon.plan_change_source', true);
begin
  select * into night from public.plan_nights where id = target for update;
  if source is distinct from 'undo_double' then
    perform set_config('foon.plan_change_source', 'follow', true);
  end if;
  if night.date < public.household_today(night.household_id)
     or exists (select 1 from public.meal_logs l where l.night_id = night.id) then
    update public.plan_nights set leftovers_from = null, leftovers_restore = null where id = target;
    perform set_config('foon.plan_change_source', coalesce(source, ''), true);
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
        locked = night.locked and coalesce((before ->> 'locked')::boolean, false),
        leftovers_from = null, leftovers_restore = null
    where id = target;
  end if;
  perform set_config('foon.plan_change_source', coalesce(source, ''), true);
end;
$$;

create or replace function public.undo_double_it(target_night uuid)
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
  perform set_config('foon.plan_change_source', 'undo_double', true);
  perform public.unwind_leftovers_night(later.id);
  perform set_config('foon.plan_change_source', '', true);
end;
$$;

create or replace function public.write_away_dates(target_household uuid, before jsonb, dates jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  today date := public.household_today(target_household);
  newly_away uuid[];
begin
  update public.households
  set settings = settings || jsonb_build_object('away_dates', dates)
  where id = target_household;

  select coalesce(array_agg(n.id), '{}') into newly_away
  from public.plan_nights n
  where n.household_id = target_household and n.date >= today
    and public.away_dates_cover(dates, n.date) and not public.away_dates_cover(before, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id)
    -- Tonight's dinner may already be eaten; a planner who's leaving before it swaps it off.
    and not (n.date = today and (n.meal_id is not null or n.quick_pick is not null));

  update public.requests set status = 'open', planned_night_id = null where planned_night_id = any (newly_away);
  -- The log says Foon cleared these, not whoever changed the dates.
  perform set_config('foon.plan_change_source', 'away', true);
  update public.plan_nights set meal_id = null, quick_pick = null, reason = null, locked = false
  where id = any (newly_away);
  perform set_config('foon.plan_change_source', '', true);
  update public.night_attendance set expected = false where plan_night_id = any (newly_away);
  -- The family's away, so nobody's cooking: the promise ends here, and shortening the dates doesn't bring it back.
  update public.night_claims set released_at = now() where night_id = any (newly_away) and released_at is null;

  -- A night still holding a dinner was never cleared, so whoever's home for it stands.
  update public.night_attendance a
  set expected = public.member_usually_home(m, n.date)
  from public.plan_nights n, public.members m
  where n.id = a.plan_night_id and m.id = a.member_id and m.status <> 'removed'
    and n.household_id = target_household and n.date >= today
    and n.meal_id is null and n.quick_pick is null
    and public.away_dates_cover(before, n.date) and not public.away_dates_cover(dates, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id);

  -- And tonight, swapped off while the dates covered it: it had no dinner to keep, so it ends the same way.
  update public.night_claims c set released_at = now()
  from public.plan_nights n
  where n.id = c.night_id and c.released_at is null
    and n.household_id = target_household and n.date >= today
    and n.meal_id is null and n.quick_pick is null
    and public.away_dates_cover(before, n.date) and not public.away_dates_cover(dates, n.date)
    and not exists (select 1 from public.meal_logs l where l.night_id = n.id);

  return dates;
end;
$$;

-- Deleting, exporting, and retention ----------------------------------------------------------------------------------

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Holds the nights first, so a Swap in flight can't log a new entry after the log's been emptied and fail the erase.
  perform 1 from public.plan_nights where household_id = target for update;
  delete from public.plan_changes where household_id = target;
  delete from public.night_claims where household_id = target;
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
                      from public.freezer_stash f where household_id = target_household),
    'night_claims', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.created_at), '[]')
                     from public.night_claims c where household_id = target_household),
    'plan_changes', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.id), '[]')
                     from public.plan_changes c where household_id = target_household)
  );
end;
$$;

create or replace function public.anonymize_expired_profiles()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  removed uuid[];
  withdrawn uuid[];
begin
  select coalesce(array_agg(m.id), '{}') into removed
  from public.members m
  where m.age_group = 'kid' and m.anonymized_at is null and m.user_id is null
    and m.status = 'removed' and m.removed_at < now() - interval '12 months';

  select coalesce(array_agg(m.id), '{}') into withdrawn
  from public.members m
  where m.age_group = 'kid' and m.user_id is null and m.status <> 'removed'
    and not public.has_parental_consent(m.id)
    -- Measured from the latest withdrawal, so an older consent cycle can't shorten the 30 days;
    -- erased again only if a newer withdrawal came after the last erase.
    and (select max(c.revoked_at) from public.consents c where c.member_id = m.id and c.kind = 'parental')
        < now() - interval '30 days'
    and (m.own_data_erased_at is null
         or m.own_data_erased_at < (select max(c.revoked_at) from public.consents c
                                    where c.member_id = m.id and c.kind = 'parental'));

  delete from public.member_allergies where member_id = any (removed);
  delete from public.serving_notes where member_id = any (removed);
  update public.requests set note = null where requested_by_member_id = any (removed);
  -- A removed kid's ratings stay as anonymous history; their own words don't.
  update public.reactions set comment = null where member_id = any (removed);
  -- What a kid rated themselves (not what a parent entered for them by passing the phone) is theirs to lose.
  delete from public.reactions where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.reactions set comment = null where member_id = any (withdrawn);
  -- The thanks a kid sent from their own phone are theirs too.
  delete from public.chef_thanks where from_member_id = any (withdrawn);
  -- Notes a kid wrote themselves are theirs; ones a parent wrote for them stay.
  delete from public.serving_notes where member_id = any (withdrawn) and written_by_member_id = member_id;
  -- What a kid asked for themselves goes (the spec's "requests"), with their me-toos.
  delete from public.request_plus_ones where member_id = any (withdrawn) and entered_by_member_id = member_id;
  delete from public.request_plus_ones where request_id in
    (select id from public.requests where requested_by_member_id = any (withdrawn) and entered_by_member_id = requested_by_member_id);
  delete from public.requests where requested_by_member_id = any (withdrawn) and entered_by_member_id = requested_by_member_id;
  -- Offers to cook a kid made themselves go; ones a parent entered for them stay, and a removed kid's stay anonymous.
  delete from public.night_claims where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.night_claims set released_at = now() where member_id = any (removed) and released_at is null;
  -- A kid who plans: what they changed themselves goes. Entries about the plan itself age out below for everyone.
  delete from public.plan_changes where actor_member_id = any (withdrawn);
  delete from public.plan_changes where created_at < now() - interval '8 weeks';
  update public.members
  set first_name = 'Former member', avatar = null, attendance_defaults = '{}', notification_prefs = '{}',
      declared_age_band = null, anonymized_at = now()
  where id = any (removed);

  update public.members
  set declared_age_band = null, own_data_erased_at = now()
  where id = any (withdrawn);

  return cardinality(removed) + cardinality(withdrawn);
end;
$$;
