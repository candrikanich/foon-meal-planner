-- The idea inbox (#38, part 1): requests from anyone, and "me too" from anyone else. Requests drive planning: a dated
-- one lands on its night in Build my week. No hard decline and no limits (docs/spec.md → Inbox rules).
--   * A request is a library dish, a typed name ("crab legs"), or a link, with an optional note and an optional night.
--   * Who asked: yourself, or (passing the phone) a profile nobody has claimed, the same rule as reactions. Whoever's
--     phone it was is kept, for kid retention.
--   * Status, as stored: open, planned (with the night it landed on), special (saved for a special occasion), archived.
--     "Someday" (no date, or a date gone by) and "Tried" (its planned night has passed) are worked out from the dates.
--   * The requester edits or archives their own; planners plan, save for a special occasion, move to someday ("Not
--     this week"), archive, and link it to a library dish (Save to library). Nothing is deleted.

create type public.request_status as enum ('open', 'planned', 'special', 'archived');

create table public.requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  requested_by_member_id uuid not null,
  meal_id uuid,
  title text check (char_length(btrim(title)) between 1 and 80),
  link text check (char_length(link) <= 2048 and link ~* '^https?://'),
  note text check (char_length(btrim(note)) between 1 and 200),
  target_date date,
  status public.request_status not null default 'open',
  planned_night_id uuid,
  entered_by_member_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint requests_id_household_key unique (id, household_id),
  constraint requests_member_fkey foreign key (requested_by_member_id, household_id)
    references public.members (id, household_id),
  constraint requests_meal_fkey foreign key (meal_id, household_id) references public.meals (id, household_id),
  constraint requests_night_fkey foreign key (planned_night_id, household_id)
    references public.plan_nights (id, household_id),
  constraint requests_entered_by_fkey foreign key (entered_by_member_id, household_id)
    references public.members (id, household_id),
  constraint requests_something check (meal_id is not null or title is not null or link is not null),
  constraint requests_planned_has_night check ((status = 'planned') = (planned_night_id is not null))
);

create index requests_household_idx on public.requests (household_id);

create table public.request_plus_ones (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  request_id uuid not null,
  member_id uuid not null,
  entered_by_member_id uuid,
  created_at timestamptz not null default now(),
  constraint request_plus_ones_once unique (request_id, member_id),
  constraint request_plus_ones_request_fkey foreign key (request_id, household_id)
    references public.requests (id, household_id),
  constraint request_plus_ones_member_fkey foreign key (member_id, household_id)
    references public.members (id, household_id),
  constraint request_plus_ones_entered_by_fkey foreign key (entered_by_member_id, household_id)
    references public.members (id, household_id)
);

create index request_plus_ones_household_idx on public.request_plus_ones (household_id);

create trigger requests_set_updated_at before update on public.requests
  for each row execute function public.set_updated_at();

revoke all on public.requests, public.request_plus_ones from anon, authenticated;
grant select on public.requests, public.request_plus_ones to authenticated;

alter table public.requests enable row level security;
alter table public.request_plus_ones enable row level security;

create policy "members read requests" on public.requests
  for select to authenticated using (public.is_household_member(household_id));
create policy "members read me-toos" on public.request_plus_ones
  for select to authenticated using (public.is_household_member(household_id));

-- I want...: from yourself, or a profile nobody has claimed. Returns the new request's id.
create function public.make_request(
  target_household uuid, from_member uuid, wanted_meal uuid, wanted_title text, wanted_link text, request_note text,
  wanted_on date
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  created uuid;
begin
  if not public.is_household_member(target_household) then
    raise exception 'not your household' using errcode = '42501';
  end if;
  if not public.may_react_for(from_member)
     or not exists (select 1 from public.members where id = from_member and household_id = target_household) then
    raise exception 'requests come from you (or a profile nobody has claimed)' using errcode = '42501';
  end if;
  if wanted_on is not null and wanted_on < public.household_today(target_household) then
    raise exception 'that night has passed' using errcode = '22023';
  end if;
  insert into public.requests (household_id, requested_by_member_id, meal_id, title, link, note, target_date,
                               entered_by_member_id)
  values (target_household, from_member, wanted_meal, nullif(btrim(wanted_title), ''), nullif(btrim(wanted_link), ''),
          nullif(btrim(request_note), ''), wanted_on, public.my_member_id(target_household))
  returning id into created;
  return created;
end;
$$;

revoke execute on function public.make_request(uuid, uuid, uuid, text, text, text, date) from public, anon;
grant execute on function public.make_request(uuid, uuid, uuid, text, text, text, date) to authenticated;

-- Me too (or, again, not anymore: a me-too is a vote, so it can be taken back). Returns whether it's on now.
create function public.toggle_me_too(target_request uuid, from_member uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  request public.requests;
begin
  select * into request from public.requests where id = target_request;
  if request.id is null or not public.is_household_member(request.household_id) then
    raise exception 'no request %', target_request using errcode = 'P0002';
  end if;
  if not public.may_react_for(from_member)
     or not exists (select 1 from public.members where id = from_member and household_id = request.household_id) then
    raise exception 'me too comes from you (or a profile nobody has claimed)' using errcode = '42501';
  end if;
  if from_member = request.requested_by_member_id then
    raise exception 'it''s already your request' using errcode = '22023';
  end if;
  delete from public.request_plus_ones where request_id = target_request and member_id = from_member;
  if found then
    return false;
  end if;
  -- Two first taps at once both land here; the second simply finds it already on.
  insert into public.request_plus_ones (household_id, request_id, member_id, entered_by_member_id)
  values (request.household_id, target_request, from_member, public.my_member_id(request.household_id))
  on conflict (request_id, member_id) do nothing;
  return true;
end;
$$;

revoke execute on function public.toggle_me_too(uuid, uuid) from public, anon;
grant execute on function public.toggle_me_too(uuid, uuid) to authenticated;

-- What happens to a request next. Planners: plan (with the night), special, archive, someday (Not this week: the date
-- is cleared), open again, and link it to a library dish. The requester: change the note or night, or archive it.
create function public.update_request(
  target_request uuid, new_status public.request_status, night uuid, clear_date boolean, link_meal uuid,
  new_note text, new_date date
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  request public.requests;
  planner boolean;
  mine boolean;
begin
  select * into request from public.requests where id = target_request;
  if request.id is null or not public.is_household_member(request.household_id) then
    raise exception 'no request %', target_request using errcode = 'P0002';
  end if;
  planner := public.is_household_planner(request.household_id);
  -- Your own request, or one entered on your phone (passing it for someone without one). Passing the phone means
  -- asking as them at that moment, not owning everything they've ever asked for.
  mine := public.may_react_for(request.requested_by_member_id)
          and public.my_member_id(request.household_id) in (request.requested_by_member_id, request.entered_by_member_id);
  if not planner and not (mine and coalesce(new_status, 'archived') = 'archived' and night is null and link_meal is null) then
    raise exception 'planners decide what happens to a request; you can change or archive your own'
      using errcode = '42501';
  end if;
  if not planner and request.status = 'planned' and (clear_date or new_date is not null) then
    raise exception 'it''s already planned; ask a planner to move it' using errcode = '42501';
  end if;
  if coalesce(new_status, request.status) = 'planned' and coalesce(night, request.planned_night_id) is null then
    raise exception 'pick a night to plan it on' using errcode = '22023';
  end if;
  if night is not null and coalesce(new_status, request.status) <> 'planned' then
    raise exception 'a night is only for planning it' using errcode = '22023';
  end if;
  if night is not null and not exists (select 1 from public.plan_nights
                                       where id = night and household_id = request.household_id) then
    raise exception 'no night %', night using errcode = 'P0002';
  end if;
  if link_meal is not null and not exists (select 1 from public.meals
                                           where id = link_meal and household_id = request.household_id) then
    raise exception 'no meal %', link_meal using errcode = 'P0002';
  end if;
  if new_date is not null and new_date < public.household_today(request.household_id) then
    raise exception 'that night has passed' using errcode = '22023';
  end if;
  update public.requests
  set status = coalesce(new_status, status),
      planned_night_id = case
        when coalesce(new_status, status) = 'planned' then coalesce(night, planned_night_id)
        else null end,
      target_date = case when clear_date then null else coalesce(new_date, target_date) end,
      meal_id = coalesce(link_meal, meal_id),
      note = case when new_note is null then note else nullif(btrim(new_note), '') end
  where id = target_request;
end;
$$;

revoke execute on function public.update_request(uuid, public.request_status, uuid, boolean, uuid, text, date)
  from public, anon;
grant execute on function public.update_request(uuid, public.request_status, uuid, boolean, uuid, text, date)
  to authenticated;

-- Deletion, export, and retention cover requests.
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
    delete from public.request_plus_ones where household_id = owned;
    delete from public.requests where household_id = owned;
    delete from public.serving_notes where household_id = owned;
    delete from public.chef_thanks where household_id = owned;
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
  -- Notes about how someone likes their food are about them; they go with the name.
  delete from public.serving_notes where member_id = profile.id;
  -- Their requests stay (the family's history of what was wanted), without their own words.
  update public.requests set note = null where requested_by_member_id = profile.id;
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
                  from public.reactions r where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household)
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
