-- Claim a night and dinner jobs (#50).
-- 1. night_claims: "I'll cook Thursday", a promise, one row per promise. A night has at most one open claim. Nothing writes
--    it but claim_night, release_claim and the functions below; claims are read, not mirrored, so no trigger keeps them
--    in step with the night. What a claim means at any moment comes from the night as it is now:
--    - a different dish, an empty night, Double it, a freezer dish: the promise stands;
--    - a quick pick (nothing to cook) or the person marked out: it's on hold. It counts again if that changes, and while
--      it's on hold because they're out, someone else can take the night;
--    - away dates: it ends, in write_away_dates;
--    - a removed member, or one who now eats separately: it doesn't count.
--    Who can claim: yourself, or (pass the phone) a profile nobody has claimed. Who can take one back: the same, or a planner.
-- 2. A claim is a promise and a log is what happened, so credit only ever comes from meal_logs. A claim fills in
--    meal_logs.cooked_by_member_id as the default when a dish is logged (confirm_dinner and the overnight job). After that
--    the log stands on its own.
-- 3. M2 car 6 (push): planners see new claims in the app today (ClaimNewsSection). The push reads the same thing, rows in
--    night_claims with released_at null, sending to the household's planners except entered_by_member_id, and it asks
--    household_away_on before it sends, like everything else in that car.
-- 4. Dinner jobs have no table. households.settings.dinner_jobs is {"jobs": [...], "left_out": [member ids]}, off until a
--    planner picks a job; only set_dinner_job and set_dinner_job_person write it, under a lock on the household, and the
--    trigger that keeps away_dates keeps this too. Who does what is worked out on the device from who's home, so nothing
--    is assigned, tracked, or missed (DinnerJobs). left_out can hold a removed member's id: that's their anonymized profile.
--
-- Errors the app words itself: FD005 someone else has the night; FD006 the night's gone by or its dinner is logged; FD007
-- the family is away; FD008 they eat separately; FD009 a quick pick, so nothing to cook; FD010 they're out that night.

create table public.night_claims (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  night_id uuid not null,
  member_id uuid not null,
  -- Whose phone it was: the person themselves, or someone passing the phone.
  entered_by_member_id uuid,
  created_at timestamptz not null default now(),
  -- Taken back, or ended by away dates. Kept, since it's what someone said.
  released_at timestamptz,
  constraint night_claims_night_fkey foreign key (night_id, household_id) references public.plan_nights (id, household_id),
  constraint night_claims_member_fkey foreign key (member_id, household_id) references public.members (id, household_id),
  constraint night_claims_entered_by_fkey foreign key (entered_by_member_id, household_id)
    references public.members (id, household_id)
);

create unique index night_claims_one_open on public.night_claims (night_id) where released_at is null;
create index night_claims_household_idx on public.night_claims (household_id);
create index night_claims_member_idx on public.night_claims (member_id);

-- 1. Claiming ---------------------------------------------------------------------------------------------------------

revoke all on public.night_claims from anon, authenticated;
grant select on public.night_claims to authenticated;

alter table public.night_claims enable row level security;

create policy "members read claims" on public.night_claims
  for select to authenticated using (public.is_household_member(household_id));

-- Whether this person can be the night's cook as things stand: still in the family, not someone who eats separately, and
-- not marked out. No attendance row (added after the week was made) doesn't say they're out.
create function public.can_cook_night(target_member uuid, target_night uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members m
    where m.id = target_member and m.status <> 'removed' and not m.eats_separately
      and coalesce((select a.expected from public.night_attendance a
                    where a.plan_night_id = target_night and a.member_id = m.id), true)
  );
$$;

revoke execute on function public.can_cook_night(uuid, uuid) from public, anon, authenticated;

-- Holds the night, so two people claiming it get one answer. Asking again for the same person changes nothing. A claim
-- that doesn't count any more (they're out, or gone) doesn't stop someone else, and ends when they take the night.
create function public.claim_night(target_night uuid, target_member uuid)
returns public.night_claims
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  person public.members;
  held public.night_claims;
  saved public.night_claims;
  today date;
begin
  select * into night from public.plan_nights n
  where n.id = target_night and public.is_household_member(n.household_id) for update;
  if night.id is null then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  select * into person from public.members where id = target_member and household_id = night.household_id;
  if person.id is null or not public.may_react_for(target_member) then
    raise exception 'people offer for themselves (or for a profile nobody has claimed)' using errcode = '42501';
  end if;
  if person.eats_separately then
    raise exception 'they eat separately, so they aren''t asked to cook' using errcode = 'FD008';
  end if;

  today := public.household_today(night.household_id);
  if night.date < today or exists (select 1 from public.meal_logs l where l.night_id = night.id) then
    raise exception 'that dinner has already happened' using errcode = 'FD006';
  end if;
  -- As the card reads it: tonight keeps a dinner it already has, inside away dates or not.
  if public.household_away_on(night.household_id, night.date)
     and not (night.date = today and (night.meal_id is not null or night.quick_pick is not null)) then
    raise exception 'the family is away that night' using errcode = 'FD007';
  end if;
  if night.quick_pick is not null then
    raise exception 'there''s nothing to cook that night' using errcode = 'FD009';
  end if;
  if not public.can_cook_night(target_member, night.id) then
    raise exception 'they''re out that night' using errcode = 'FD010';
  end if;

  select * into held from public.night_claims where night_id = night.id and released_at is null;
  if held.member_id = target_member then
    return held;
  end if;
  if held.id is not null then
    if public.can_cook_night(held.member_id, night.id) then
      raise exception 'someone else is cooking that night' using errcode = 'FD005';
    end if;
    update public.night_claims set released_at = now() where id = held.id;
  end if;

  insert into public.night_claims (household_id, night_id, member_id, entered_by_member_id)
  values (night.household_id, night.id, target_member, public.my_member_id(night.household_id))
  returning * into saved;
  return saved;
end;
$$;

revoke execute on function public.claim_night(uuid, uuid) from public, anon;
grant execute on function public.claim_night(uuid, uuid) to authenticated;

-- By the claim, not the night: a device that's behind can't take back someone's newer claim. Already taken back is nothing
-- to do. Once the night's gone by or its dinner is logged the claim is history, and who cooked is corrected on the log.
create function public.release_claim(target_claim uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  claim public.night_claims;
  night public.plan_nights;
begin
  select * into claim from public.night_claims c
  where c.id = target_claim and public.is_household_member(c.household_id);
  if claim.id is null then
    raise exception 'no claim %', target_claim using errcode = 'P0002';
  end if;
  if not public.may_react_for(claim.member_id) and not public.is_household_planner(claim.household_id) then
    raise exception 'only they or a planner can take it back' using errcode = '42501';
  end if;

  select * into night from public.plan_nights where id = claim.night_id for update;
  if night.date < public.household_today(claim.household_id)
     or exists (select 1 from public.meal_logs l where l.night_id = night.id) then
    raise exception 'that dinner has already happened' using errcode = 'FD006';
  end if;
  update public.night_claims set released_at = now() where id = claim.id and released_at is null;
end;
$$;

revoke execute on function public.release_claim(uuid) from public, anon;
grant execute on function public.release_claim(uuid) to authenticated;

-- 2. Who a dish was promised by ---------------------------------------------------------------------------------------

-- The night's cook by promise, if its dish can be credited: a quick pick isn't cooking, and someone out didn't cook.
create function public.night_claimer(target_night uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select c.member_id
  from public.night_claims c
  join public.plan_nights n on n.id = c.night_id
  where c.night_id = target_night and c.released_at is null and n.meal_id is not null
    and public.can_cook_night(c.member_id, c.night_id);
$$;

revoke execute on function public.night_claimer(uuid) from public, anon, authenticated;

-- For confirm_dinner, which runs as the caller. Nothing for someone outside the household. It doesn't hold the night: two
-- phones confirming would then deadlock with meal_logs_follow_what_was_eaten. claim_night holds it and refuses once there's
-- a log, so the worst timing leaves the cook blank to fill in, never wrong.
create function public.claimed_cook_for_logging(target_night uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select public.night_claimer(n.id) from public.plan_nights n
  where n.id = target_night and public.is_household_member(n.household_id);
$$;

revoke execute on function public.claimed_cook_for_logging(uuid) from public, anon;
grant execute on function public.claimed_cook_for_logging(uuid) to authenticated;

-- 3. What a claim feeds ------------------------------------------------------------------------------------------------

create or replace function public.confirm_dinner(target_night uuid)
returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  night public.plan_nights;
  log_id uuid;
  cook uuid;
begin
  select * into night from public.plan_nights where id = target_night;
  if night.id is null then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  cook := public.claimed_cook_for_logging(night.id);
  insert into public.meal_logs as existing (household_id, night_id, meal_id, quick_pick, cooked_by_member_id)
  values (night.household_id, night.id, night.meal_id, night.quick_pick, cook)
  on conflict (night_id) do update
    set verified = true,
        meal_id = case when existing.verified then existing.meal_id else excluded.meal_id end,
        quick_pick = case when existing.verified then existing.quick_pick else excluded.quick_pick end,
        -- Only as it's first confirmed: after that a cook left blank was left blank by someone.
        cooked_by_member_id = case when existing.verified then existing.cooked_by_member_id
                                   else coalesce(existing.cooked_by_member_id, excluded.cooked_by_member_id) end
  returning id into log_id;
  return log_id;
end;
$$;

create or replace function public.confirm_overnight_dinners()
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
  insert into public.meal_logs (household_id, night_id, meal_id, quick_pick, cooked_by_member_id, verified)
  select r.household_id, r.id, r.meal_id, r.quick_pick, public.night_claimer(r.id), false
  from recent r join days d using (household_id)
  where r.date < d.today and r.date >= d.today - 7
  on conflict (night_id) do nothing;
  get diagnostics saved = row_count;
  return saved;
end;
$$;

create or replace function public.set_not_home(target_night uuid, target_member uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
begin
  select * into night from public.plan_nights where id = target_night;
  if night.id is null or not public.is_household_member(night.household_id) then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if not public.may_react_for(target_member)
     or not exists (select 1 from public.members where id = target_member and household_id = night.household_id) then
    raise exception 'people say for themselves (or for a profile nobody has claimed)' using errcode = '42501';
  end if;
  if night.date > public.household_today(night.household_id) then
    raise exception 'that dinner hasn''t happened yet' using errcode = '22023';
  end if;
  -- The after-dinner card's reach, like the overnight job: older attendance is history.
  if night.date < public.household_today(night.household_id) - 7 then
    raise exception 'that dinner was too long ago' using errcode = '22023';
  end if;
  insert into public.night_attendance (household_id, plan_night_id, member_id, expected)
  values (night.household_id, night.id, target_member, false)
  on conflict (plan_night_id, member_id) do update set expected = false;
  -- They weren't there, so they didn't cook it, whatever was promised. A cook someone has thanked stays, as they do for
  -- every other change.
  update public.meal_logs l set cooked_by_member_id = null
  where l.night_id = night.id and l.cooked_by_member_id = target_member
    and not exists (select 1 from public.chef_thanks t where t.meal_log_id = l.id);
end;
$$;

-- 4. Away dates end a claim --------------------------------------------------------------------------------------------

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
  update public.plan_nights set meal_id = null, quick_pick = null, reason = null, locked = false
  where id = any (newly_away);
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

  return dates;
end;
$$;

-- 5. Dinner jobs ------------------------------------------------------------------------------------------------------

-- Each change is to the list as it is now, so a device with an old copy can't undo another planner's. Both return the
-- whole setting. Security definer: the trigger below keeps the key from everyone else.
create function public.set_dinner_job(target_household uuid, job text, is_on boolean)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  config jsonb;
  jobs jsonb;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners change dinner jobs' using errcode = '42501';
  end if;
  if job is null or job not in ('set_table', 'clear_table', 'dishes') or is_on is null then
    raise exception 'not a dinner job Foon knows' using errcode = '22023';
  end if;

  select coalesce(settings -> 'dinner_jobs', '{}') into config from public.households where id = target_household for update;
  select coalesce(jsonb_agg(entry order by position), '[]'::jsonb) into jobs
  from jsonb_array_elements(case when jsonb_typeof(config -> 'jobs') = 'array' then config -> 'jobs' else '[]'::jsonb end)
       with ordinality as listed (entry, position)
  where entry <> to_jsonb(job);
  if is_on then
    jobs := jobs || to_jsonb(job);
  end if;

  config := config || jsonb_build_object('jobs', jobs);
  update public.households set settings = settings || jsonb_build_object('dinner_jobs', config)
  where id = target_household;
  return config;
end;
$$;

revoke execute on function public.set_dinner_job(uuid, text, boolean) from public, anon;
grant execute on function public.set_dinner_job(uuid, text, boolean) to authenticated;

-- Everyone's in unless left out, so someone new joins the rotation without anyone having to remember.
create function public.set_dinner_job_person(target_household uuid, target_member uuid, is_in boolean)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  config jsonb;
  left_out jsonb;
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners change dinner jobs' using errcode = '42501';
  end if;
  if is_in is null then
    raise exception 'in or out' using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m
                 where m.id = target_member and m.household_id = target_household and m.status <> 'removed') then
    raise exception 'no member %', target_member using errcode = 'P0002';
  end if;

  select coalesce(settings -> 'dinner_jobs', '{}') into config from public.households where id = target_household for update;
  select coalesce(jsonb_agg(entry order by position), '[]'::jsonb) into left_out
  from jsonb_array_elements(case when jsonb_typeof(config -> 'left_out') = 'array' then config -> 'left_out' else '[]'::jsonb end)
       with ordinality as listed (entry, position)
  where entry <> to_jsonb(target_member);
  if not is_in then
    left_out := left_out || to_jsonb(target_member);
  end if;

  config := config || jsonb_build_object('left_out', left_out);
  update public.households set settings = settings || jsonb_build_object('dinner_jobs', config)
  where id = target_household;
  return config;
end;
$$;

revoke execute on function public.set_dinner_job_person(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_dinner_job_person(uuid, uuid, boolean) to authenticated;

create or replace function public.households_keep_away_dates()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  kept text;
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  foreach kept in array array['away_dates', 'food_rules', 'dinner_jobs'] loop
    if tg_op = 'INSERT' then
      new.settings := new.settings - kept;
    elsif old.settings ? kept then
      new.settings := new.settings || jsonb_build_object(kept, old.settings -> kept);
    else
      new.settings := new.settings - kept;
    end if;
  end loop;
  return new;
end;
$$;

-- 6. Deleting, exporting, and retention --------------------------------------------------------------------------------

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
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
                     from public.night_claims c where household_id = target_household)
  );
end;
$$;

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
    perform public.erase_household(owned);
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
  -- Notes about how someone likes their food are about them; they go with the name.
  delete from public.serving_notes where member_id = profile.id;
  -- Their requests stay (the family's history of what was wanted), without their own words.
  update public.requests set note = null where requested_by_member_id = profile.id;
  -- Their ratings stay as anonymous history; what they wrote in their own words doesn't.
  update public.reactions set comment = null where member_id = profile.id;
  -- What they promised and didn't get to is off; what's past stays as anonymous history.
  update public.night_claims set released_at = now() where member_id = profile.id and released_at is null;
  update public.members
  set status = 'removed', removed_at = now(), first_name = 'Former member', avatar = null,
      attendance_defaults = '{}', notification_prefs = '{}', declared_age_band = null, anonymized_at = now()
  where id = profile.id;
  return 'profile_anonymized';
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
