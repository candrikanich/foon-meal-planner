-- Dinner logs and reactions (#42, part 1). "The plan is the log by default": one log per night records what was
-- actually eaten, who cooked, and leftovers; one reaction per person rates the dish (never the cook).
--   * confirm_dinner(night): the first tap from anyone confirms the planned dinner. react_to_dinner confirms and saves
--     a person's reaction in one go, the one-tap prompt. Only a dinner that has happened, and had something planned,
--     can be logged (an empty night is logged by swapping in what was eaten first); only dishes are rated, not quick
--     picks.
--   * Pass the phone: anyone in the household can react for a profile nobody has claimed (kids without phones);
--     claimed profiles react for themselves. Who entered each reaction is kept, for kid retention below.
--   * Reactions can be changed for 24 hours, then they lock into history. Logs and reactions are never deleted, except
--     by the retention rules (a withdrawn kid's self-entered ratings) and deleting the household.
--   * No answer: an hourly job saves the last week's planned nights of approved weeks as unverified once the
--     household's day is over, so the planner can spot gaps. An unverified log follows later changes to the plan.
--   * Who confirmed a log and who entered a reaction are member ids stamped by the server: never account ids, never
--     claimed by the client.
-- The household's day comes from settings.time_zone (the app writes it), else America/New_York (US launch).

create type public.reaction_kind as enum ('favorite', 'good', 'not_for_me', 'tired_of_it');

-- A time zone name, if Postgres knows it. Cheap: no scan of pg_timezone_names.
create function public.valid_time_zone(name text)
returns text
language plpgsql immutable set search_path = ''
as $$
begin
  if name is null then
    return null;
  end if;
  perform now() at time zone name;
  return name;
exception when invalid_parameter_value then
  return null;
end;
$$;

-- Runs as the caller: members get their household's day; anyone else gets the default (no leak of a time zone).
create function public.household_today(target_household uuid)
returns date
language sql stable security invoker set search_path = ''
as $$
  select (now() at time zone coalesce(
    (select public.valid_time_zone(settings ->> 'time_zone') from public.households where id = target_household),
    'America/New_York'))::date;
$$;

revoke execute on function public.household_today(uuid) from public, anon;
grant execute on function public.household_today(uuid) to authenticated;

-- The caller's own profile in a household.
create function public.my_member_id(target_household uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.members
  where household_id = target_household and user_id = (select auth.uid()) and status <> 'removed'
    and public.session_is_active();
$$;

revoke execute on function public.my_member_id(uuid) from public, anon;
grant execute on function public.my_member_id(uuid) to authenticated;

create table public.meal_logs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  night_id uuid not null,
  -- What was actually eaten: the planned dish unless someone said "We had something else".
  meal_id uuid,
  quick_pick public.quick_pick,
  cooked_by_member_id uuid,
  leftovers boolean,
  -- False when saved overnight with no answer.
  verified boolean not null default true,
  confirmed_by_member_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint meal_logs_one_per_night unique (night_id),
  constraint meal_logs_id_household_key unique (id, household_id),
  constraint meal_logs_night_fkey foreign key (night_id, household_id) references public.plan_nights (id, household_id),
  constraint meal_logs_meal_fkey foreign key (meal_id, household_id) references public.meals (id, household_id),
  constraint meal_logs_cook_fkey foreign key (cooked_by_member_id, household_id)
    references public.members (id, household_id),
  constraint meal_logs_confirmer_fkey foreign key (confirmed_by_member_id, household_id)
    references public.members (id, household_id),
  constraint meal_logs_one_kind check (meal_id is null or quick_pick is null)
);

create index meal_logs_household_idx on public.meal_logs (household_id);
create index meal_logs_meal_idx on public.meal_logs (meal_id);
-- The overnight job looks nights up by date.
create index plan_nights_date_idx on public.plan_nights (date);

create table public.reactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  meal_log_id uuid not null,
  member_id uuid not null,
  reaction public.reaction_kind not null,
  -- "It was off tonight": a bad night, not a bad recipe.
  off_tonight boolean not null default false,
  comment text check (char_length(btrim(comment)) between 1 and 140),
  -- Whose phone last wrote it: the member themselves, or someone passing the phone.
  entered_by_member_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint reactions_one_per_member unique (meal_log_id, member_id),
  constraint reactions_log_fkey foreign key (meal_log_id, household_id) references public.meal_logs (id, household_id),
  constraint reactions_member_fkey foreign key (member_id, household_id) references public.members (id, household_id),
  constraint reactions_entered_by_fkey foreign key (entered_by_member_id, household_id)
    references public.members (id, household_id)
);

create index reactions_household_idx on public.reactions (household_id);
create index reactions_member_idx on public.reactions (member_id);

create trigger meal_logs_set_updated_at before update on public.meal_logs
  for each row execute function public.set_updated_at();
create trigger reactions_set_updated_at before update on public.reactions
  for each row execute function public.set_updated_at();

-- The rules for what people write into a log (the overnight job and other privileged code run as the owner and skip
-- them): only a night that has happened and had something planned; a confirmation can't be taken back; the confirmer
-- is whoever verified it, as a member.
create function public.meal_logs_guard()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  night public.plan_nights;
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    select * into night from public.plan_nights where id = new.night_id;
    if night.date > public.household_today(new.household_id) then
      raise exception 'that dinner hasn''t happened yet' using errcode = '22023';
    end if;
    if night.meal_id is null and night.quick_pick is null then
      raise exception 'nothing was planned that night; swap in what you had first' using errcode = '22023';
    end if;
    new.verified := true;
    new.confirmed_by_member_id := public.my_member_id(new.household_id);
    return new;
  end if;
  if old.verified and not new.verified then
    raise exception 'a confirmed dinner stays confirmed' using errcode = '42501';
  end if;
  new.confirmed_by_member_id := case when not old.verified and new.verified
                                     then public.my_member_id(new.household_id)
                                     else old.confirmed_by_member_id end;
  return new;
end;
$$;

create trigger meal_logs_guard before insert or update on public.meal_logs
  for each row execute function public.meal_logs_guard();

-- Reactions lock into history after 24 hours, and only dishes are rated. Whoever's phone it is gets recorded.
create function public.reactions_guard()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if old.created_at < now() - interval '24 hours' then
      raise exception 'reactions lock after 24 hours' using errcode = '42501';
    end if;
    -- The last writer, so a rating a parent entered and a kid later changed counts as the kid's.
    new.entered_by_member_id := public.my_member_id(new.household_id);
    return new;
  end if;
  if not public.is_household_member(new.household_id) then
    raise exception 'not your household' using errcode = '42501';
  end if;
  if (select meal_id from public.meal_logs where id = new.meal_log_id) is null then
    raise exception 'only dishes are rated, not quick picks' using errcode = '22023';
  end if;
  new.entered_by_member_id := public.my_member_id(new.household_id);
  return new;
end;
$$;

create trigger reactions_guard before insert or update on public.reactions
  for each row execute function public.reactions_guard();

-- Who may react for a member: themselves, or anyone in the household for a profile nobody has claimed.
create function public.may_react_for(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members m
    where m.id = target_member and m.status <> 'removed'
      and ((m.user_id = (select auth.uid()) and public.session_is_active())
           or (m.user_id is null and public.is_household_member(m.household_id)))
  );
$$;

revoke execute on function public.may_react_for(uuid) from public, anon;
grant execute on function public.may_react_for(uuid) to authenticated;

revoke all on public.meal_logs from anon, authenticated;
grant select on public.meal_logs to authenticated;
grant insert (household_id, night_id, meal_id, quick_pick, cooked_by_member_id, leftovers) on public.meal_logs
  to authenticated;
-- `verified` only ever turns on (the guard), which confirm_dinner's upsert needs.
grant update (meal_id, quick_pick, cooked_by_member_id, leftovers, verified) on public.meal_logs to authenticated;

alter table public.meal_logs enable row level security;

create policy "members read dinner logs" on public.meal_logs
  for select to authenticated using (public.is_household_member(household_id));
create policy "members log dinners" on public.meal_logs
  for insert to authenticated with check (public.is_household_member(household_id));
create policy "members correct dinner logs" on public.meal_logs
  for update to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

revoke all on public.reactions from anon, authenticated;
grant select on public.reactions to authenticated;
grant insert (household_id, meal_log_id, member_id, reaction, off_tonight, comment) on public.reactions to authenticated;
grant update (reaction, off_tonight, comment) on public.reactions to authenticated;

alter table public.reactions enable row level security;

-- Reactions are visible to the whole family.
create policy "members read reactions" on public.reactions
  for select to authenticated using (public.is_household_member(household_id));
create policy "members react" on public.reactions
  for insert to authenticated
  with check (public.is_household_member(household_id) and public.may_react_for(member_id));
create policy "members change their reaction" on public.reactions
  for update to authenticated
  using (public.may_react_for(member_id))
  with check (public.may_react_for(member_id));

-- The first tap from anyone confirms the planned dinner, or verifies one saved overnight (which first catches up with
-- any change to the plan since). Returns the log's id.
create function public.confirm_dinner(target_night uuid)
returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  night public.plan_nights;
  log_id uuid;
begin
  select * into night from public.plan_nights where id = target_night;
  if night.id is null then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  insert into public.meal_logs as existing (household_id, night_id, meal_id, quick_pick)
  values (night.household_id, night.id, night.meal_id, night.quick_pick)
  on conflict (night_id) do update
    set verified = true,
        meal_id = case when existing.verified then existing.meal_id else excluded.meal_id end,
        quick_pick = case when existing.verified then existing.quick_pick else excluded.quick_pick end
  returning id into log_id;
  return log_id;
end;
$$;

revoke execute on function public.confirm_dinner(uuid) from public, anon;
grant execute on function public.confirm_dinner(uuid) to authenticated;

-- One tap: confirms the dinner and saves (or changes) a person's reaction. Returns the log's id.
create function public.react_to_dinner(target_night uuid, target_member uuid, kind public.reaction_kind)
returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  log_id uuid;
begin
  if not public.may_react_for(target_member) then
    raise exception 'people rate for themselves (or for a profile nobody has claimed)' using errcode = '42501';
  end if;
  log_id := public.confirm_dinner(target_night);
  insert into public.reactions (household_id, meal_log_id, member_id, reaction)
  select household_id, log_id, target_member, kind from public.meal_logs where id = log_id
  on conflict (meal_log_id, member_id) do update set reaction = excluded.reaction;
  return log_id;
end;
$$;

revoke execute on function public.react_to_dinner(uuid, uuid, public.reaction_kind) from public, anon;
grant execute on function public.react_to_dinner(uuid, uuid, public.reaction_kind) to authenticated;

-- An unverified log follows the plan if it changes later ("we ate out after all").
create function public.plan_nights_refresh_unverified_log()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (new.meal_id, new.quick_pick) is distinct from (old.meal_id, old.quick_pick) then
    update public.meal_logs set meal_id = new.meal_id, quick_pick = new.quick_pick
    where night_id = new.id and not verified;
  end if;
  return null;
end;
$$;

create trigger plan_nights_refresh_unverified_log after update on public.plan_nights
  for each row execute function public.plan_nights_refresh_unverified_log();

-- No answer: last week's approved, planned nights before the household's today with no log are saved as unverified.
-- Each household's day is worked out once, and only nights within a few days of now are looked at.
create function public.confirm_overnight_dinners()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  saved integer;
begin
  with recent as (
    select n.id, n.household_id, n.date, n.meal_id, n.quick_pick
    from public.plan_nights n
    join public.plans p on p.id = n.plan_id
    where n.date between current_date - 9 and current_date + 1
      and p.approved_at is not null
      and (n.meal_id is not null or n.quick_pick is not null)
  ),
  days as (
    select h.id as household_id,
           (now() at time zone coalesce(public.valid_time_zone(h.settings ->> 'time_zone'), 'America/New_York'))::date
             as today
    from public.households h
    where h.id in (select household_id from recent)
  )
  insert into public.meal_logs (household_id, night_id, meal_id, quick_pick, verified)
  select r.household_id, r.id, r.meal_id, r.quick_pick, false
  from recent r join days d using (household_id)
  where r.date < d.today and r.date >= d.today - 7
  on conflict (night_id) do nothing;
  get diagnostics saved = row_count;
  return saved;
end;
$$;

revoke execute on function public.confirm_overnight_dinners() from public, anon, authenticated;

select cron.schedule('confirm-overnight-dinners', '7 * * * *', 'select public.confirm_overnight_dinners()');

-- Kid retention covers reactions: a removed kid's comments go with their name; a withdrawn kid's own ratings go.
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
  -- A removed kid's ratings stay as anonymous history; their own words don't.
  update public.reactions set comment = null where member_id = any (removed);
  -- What a kid rated themselves (not what a parent entered for them by passing the phone) is theirs to lose.
  delete from public.reactions where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.reactions set comment = null where member_id = any (withdrawn);
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


-- Account deletion and export cover the new tables.
create or replace function public.delete_account_data(target_user uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  owned uuid;
  profile public.members;
begin
  -- Rate-limit bookkeeping keyed by the account; nothing to keep once it's gone.
  delete from public.invite_redeem_attempts where user_id = target_user;

  select id into owned from public.households where owner = target_user;
  if owned is not null then
    delete from public.reactions where household_id = owned;
    delete from public.meal_logs where household_id = owned;
    delete from public.night_attendance where household_id = owned;
    delete from public.list_items where household_id = owned;
    delete from public.plan_nights where household_id = owned;
    delete from public.plans where household_id = owned;
    delete from public.traditions where household_id = owned;
    delete from public.meal_sides where household_id = owned;
    delete from public.meal_ingredients where household_id = owned;
    delete from public.meals where household_id = owned;
    delete from public.items where household_id = owned;
    delete from public.member_allergies where household_id = owned;
    delete from public.invites where household_id = owned;
    delete from public.consents where household_id = owned;
    delete from public.members where household_id = owned;
    delete from public.households where id = owned;
    return 'household_deleted';
  end if;

  select * into profile from public.members where user_id = target_user;
  if profile.id is null then
    return 'no_household';
  end if;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    return 'unlinked';
  end if;

  delete from public.member_allergies where member_id = profile.id;
  -- Their ratings stay as anonymous history; what they wrote in their own words doesn't.
  update public.reactions set comment = null where member_id = profile.id;
  update public.members
  set status = 'removed', removed_at = now(), first_name = 'Former member', avatar = null,
      attendance_defaults = '{}', notification_prefs = '{}', declared_age_band = null, anonymized_at = now()
  where id = profile.id;
  return 'profile_anonymized';
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
                  from public.reactions r where household_id = target_household)
  );
end;
$$;

