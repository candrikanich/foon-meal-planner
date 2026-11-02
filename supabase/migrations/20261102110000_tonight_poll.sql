-- The tonight poll (#43): anyone starts one for tonight, and whoever's home votes until it closes. No vote is abstaining.
--
-- A poll says what the family would like. It doesn't change the plan: a planner makes the winner tonight's dinner, through the
-- same Swap as any other change, so nobody's cooked dinner gets voted away while they're at the store. Tables take no direct
-- writes; everything goes through functions, which read the options themselves so a poll only ever offers real things.
--
-- `options` is a JSON array: {"quick_pick": …}, {"meal_id": …, "name": …}, or that with "freezer_item_id". The name is a copy,
-- so a dish deleted or renamed later doesn't blank the poll. Allergy flags aren't stored: each phone works them out for who's
-- home now, as a night's card does.

create table public.polls (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  night_id uuid not null references public.plan_nights (id) on delete cascade,
  started_by uuid references public.members (id) on delete set null,
  options jsonb not null,
  closes_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index polls_household_idx on public.polls (household_id);
create index polls_night_idx on public.polls (night_id, created_at desc);
create index polls_started_by_idx on public.polls (started_by);

create table public.poll_votes (
  poll_id uuid not null references public.polls (id) on delete cascade,
  member_id uuid not null,
  household_id uuid not null references public.households (id),
  choice smallint not null check (choice >= 0),
  voted_at timestamptz not null default now(),
  -- Whose phone last cast it, so a kid's own vote can be told from one a parent tapped in for them when consent is withdrawn.
  entered_by_member_id uuid,
  primary key (poll_id, member_id),
  constraint poll_votes_member_fkey foreign key (member_id, household_id)
    references public.members (id, household_id) on delete cascade,
  constraint poll_votes_entered_by_fkey foreign key (entered_by_member_id, household_id)
    references public.members (id, household_id)
);

create index poll_votes_household_idx on public.poll_votes (household_id);
create index poll_votes_member_idx on public.poll_votes (member_id);

revoke all on public.polls from anon, authenticated;
revoke all on public.poll_votes from anon, authenticated;
grant select on public.polls to authenticated;
grant select on public.poll_votes to authenticated;

alter table public.polls enable row level security;
alter table public.poll_votes enable row level security;

create policy "members read polls" on public.polls
  for select to authenticated using (public.is_household_member(household_id));
create policy "members read votes" on public.poll_votes
  for select to authenticated using (public.is_household_member(household_id));

create function public.start_tonight_poll(target_night uuid, minutes integer, choices jsonb)
returns public.polls
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  starter uuid;
  choice jsonb;
  resolved jsonb := '[]';
  dish public.meals;
  stash public.freezer_stash;
  started public.polls;
begin
  -- Held to the end, so two phones starting at once can't both find no poll open.
  select * into night from public.plan_nights where id = target_night for update;
  if night.id is null or not public.is_household_member(night.household_id) then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if night.date <> public.household_today(night.household_id) then
    raise exception 'a poll is only for tonight' using errcode = '22023';
  end if;
  if exists (select 1 from public.meal_logs where night_id = night.id) then
    raise exception 'dinner''s already logged' using errcode = 'FD017';
  end if;
  if exists (select 1 from public.polls where night_id = night.id and closes_at > clock_timestamp()) then
    raise exception 'a poll is already open' using errcode = 'FD018';
  end if;
  if minutes is null or minutes not between 5 and 180 then
    raise exception 'a poll runs 5 minutes to 3 hours' using errcode = '22023';
  end if;
  if jsonb_typeof(choices) is distinct from 'array' or jsonb_array_length(choices) not between 2 and 6 then
    raise exception 'a poll has 2 to 6 options' using errcode = '22023';
  end if;

  select id into starter from public.members
  where household_id = night.household_id and user_id = (select auth.uid());

  for choice in select value from jsonb_array_elements(choices) loop
    if jsonb_typeof(choice) is distinct from 'object' then
      raise exception 'an option is a quick pick, a dish, or something from the freezer' using errcode = '22023';
    end if;
    if choice ? 'quick_pick' then
      if not exists (select 1 from pg_catalog.pg_enum e
                     where e.enumtypid = 'public.quick_pick'::regtype and e.enumlabel = choice ->> 'quick_pick') then
        raise exception 'no quick pick %', choice ->> 'quick_pick' using errcode = '22023';
      end if;
      resolved := resolved || jsonb_build_array(jsonb_build_object('quick_pick', choice ->> 'quick_pick'));
    elsif choice ? 'freezer_item_id' then
      select * into stash from public.freezer_stash
      where id = (choice ->> 'freezer_item_id')::uuid and household_id = night.household_id and state = 'in';
      select * into dish from public.meals where id = stash.meal_id and status in ('active', 'trial');
      if stash.id is null or dish.id is null then
        raise exception 'that isn''t in the freezer' using errcode = '22023';
      end if;
      resolved := resolved || jsonb_build_array(
        jsonb_build_object('meal_id', dish.id, 'name', dish.name, 'freezer_item_id', stash.id));
    elsif choice ? 'meal_id' then
      select * into dish from public.meals
      where id = (choice ->> 'meal_id')::uuid and household_id = night.household_id and status in ('active', 'trial');
      if dish.id is null then
        raise exception 'that dish isn''t in rotation' using errcode = '22023';
      end if;
      resolved := resolved || jsonb_build_array(jsonb_build_object('meal_id', dish.id, 'name', dish.name));
    else
      raise exception 'an option is a quick pick, a dish, or something from the freezer' using errcode = '22023';
    end if;
  end loop;

  if (select count(distinct coalesce(value ->> 'quick_pick', value ->> 'meal_id')) from jsonb_array_elements(resolved))
     <> jsonb_array_length(resolved) then
    raise exception 'an option is on there twice' using errcode = '22023';
  end if;

  insert into public.polls (household_id, night_id, started_by, options, closes_at)
  values (night.household_id, night.id, starter, resolved, clock_timestamp() + make_interval(mins => minutes))
  returning * into started;
  return started;
end;
$$;

revoke execute on function public.start_tonight_poll(uuid, integer, jsonb) from public, anon;
grant execute on function public.start_tonight_poll(uuid, integer, jsonb) to authenticated;

-- For themselves, or for a profile nobody has claimed, since the little ones don't have phones. Voting again changes the vote.
-- No row in attendance means home, as with allergy flags: nobody's said they're out.
create function public.vote_in_poll(target_poll uuid, target_member uuid, option_index integer)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  poll public.polls;
begin
  select * into poll from public.polls where id = target_poll for share;
  if poll.id is null or not public.is_household_member(poll.household_id) then
    raise exception 'no poll %', target_poll using errcode = 'P0002';
  end if;
  if not public.may_react_for(target_member)
     or not exists (select 1 from public.members where id = target_member and household_id = poll.household_id) then
    raise exception 'people vote for themselves (or for a profile nobody has claimed)' using errcode = '42501';
  end if;
  if exists (select 1 from public.members where id = target_member and eats_separately) then
    raise exception 'they eat separately, so they don''t vote' using errcode = 'FD004';
  end if;
  if exists (select 1 from public.night_attendance
             where plan_night_id = poll.night_id and member_id = target_member and not expected) then
    raise exception 'the vote is for whoever''s home' using errcode = 'FD019';
  end if;
  if poll.closes_at <= clock_timestamp() then
    raise exception 'the poll has closed' using errcode = 'FD020';
  end if;
  if option_index is null or option_index not between 0 and jsonb_array_length(poll.options) - 1 then
    raise exception 'no such option' using errcode = '22023';
  end if;

  insert into public.poll_votes (poll_id, member_id, household_id, choice, voted_at, entered_by_member_id)
  values (poll.id, target_member, poll.household_id, option_index, clock_timestamp(), public.my_member_id(poll.household_id))
  on conflict (poll_id, member_id) do update
    set choice = excluded.choice, voted_at = excluded.voted_at, entered_by_member_id = excluded.entered_by_member_id;
end;
$$;

revoke execute on function public.vote_in_poll(uuid, uuid, integer) from public, anon;
grant execute on function public.vote_in_poll(uuid, uuid, integer) to authenticated;

-- Everyone's answered, or plans changed. Whoever started it or a planner.
create function public.close_poll(target_poll uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  poll public.polls;
begin
  select * into poll from public.polls where id = target_poll for update;
  if poll.id is null or not public.is_household_member(poll.household_id) then
    raise exception 'no poll %', target_poll using errcode = 'P0002';
  end if;
  if not public.is_household_planner(poll.household_id)
     and not exists (select 1 from public.members where id = poll.started_by and user_id = (select auth.uid())) then
    raise exception 'whoever started it or a planner closes a poll' using errcode = '42501';
  end if;
  update public.polls set closes_at = least(closes_at, clock_timestamp()) where id = poll.id;
end;
$$;

revoke execute on function public.close_poll(uuid) from public, anon;
grant execute on function public.close_poll(uuid) to authenticated;

-- Deleting and exporting ------------------------------------------------------------------------------------------------

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Before any row: a device's write holds this while it takes its own locks, so one in flight finishes first, and a later one
  -- waits and is then refused.
  perform pg_advisory_xact_lock(public.notification_log_lock(target));
  -- Holds the nights first, so a Swap in flight can't log a new entry after the log's been emptied and fail the erase.
  perform 1 from public.plan_nights where household_id = target for update;
  delete from public.poll_votes where household_id = target;
  delete from public.polls where household_id = target;
  delete from public.notification_log where household_id = target;
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
  delete from public.consent_agreements where household_id = target;
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
    'consent_agreements', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id' - 'agreed_by' order by a.agreed_at), '[]')
                           from public.consent_agreements a where household_id = target_household),
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
    'hidden_comments', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.hidden_at), '[]')
                        from public.hidden_comments c where household_id = target_household),
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
                     from public.plan_changes c where household_id = target_household),
    'notification_log', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                         from public.notification_log l where household_id = target_household),
    'polls', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
              from public.polls p where household_id = target_household),
    'poll_votes', (select coalesce(jsonb_agg(to_jsonb(v) - 'household_id' order by v.voted_at), '[]')
                   from public.poll_votes v where household_id = target_household)
  );
end;
$$;

-- Keeping and letting go ------------------------------------------------------------------------------------------------

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
  -- A vote a kid cast themselves goes, and a poll stops saying they started it. One a parent tapped in for them stays until it ages out.
  delete from public.poll_votes where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.polls set started_by = null where started_by = any (withdrawn);
  -- A poll is about one dinner, so it ages out like the log, for everyone, and its votes go with it.
  delete from public.polls where created_at < now() - interval '8 weeks';
  -- A kid who plans: what they changed themselves goes. Entries about the plan itself age out below for everyone.
  delete from public.plan_changes where actor_member_id = any (withdrawn);
  delete from public.plan_changes where created_at < now() - interval '8 weeks';
  -- What was sent to a kid goes with them, and the log ages out for everyone.
  delete from public.notification_log where member_id = any (removed) or member_id = any (withdrawn);
  delete from public.notification_log where created_at < now() - interval '8 weeks';
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

  -- What was sent to them is about them, kid or adult. The lock lasts until they're unlinked or removed, so their device can't
  -- log a reminder after this: it waits, then finds it's no longer in the family.
  perform pg_advisory_xact_lock(public.notification_log_lock(profile.household_id));
  delete from public.notification_log where member_id = profile.id;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    -- Their profile stays, but the words were theirs. The ratings stay with the profile, as they do for an adult.
    update public.reactions set comment = null where member_id = profile.id;
    -- What they promised is off. Their profile stays, so nothing else would end it.
    update public.night_claims set released_at = now() where member_id = profile.id and released_at is null;
    -- A vote they cast themselves goes, and a poll stops saying they started it.
    delete from public.poll_votes where member_id = profile.id and entered_by_member_id = profile.id;
    update public.polls set started_by = null where started_by = profile.id;
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
