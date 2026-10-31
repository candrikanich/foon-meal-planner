-- The notification log (#40 part 1). Mostly type, night, and timestamps: what a device scheduled or sent to whom, and what
-- was answered. It's what budgets and (later) ignore handling read, for both delivery paths. It holds no message text and
-- nothing about allergies, by having no column to put them in.
-- A device writes its own rows through record_notifications when it can: nobody else's, and nothing blocks on it. A row whose
-- sent_at stays null was scheduled and then called off. Planners read the household's, everyone reads their own.
-- Eight weeks are kept. Deleting an account, removing a kid under retention, and withdrawing a kid's consent delete their rows.

create table public.notification_log (
  -- Made on the device, so sending the same row twice is one row.
  id uuid primary key,
  household_id uuid not null references public.households (id),
  member_id uuid not null,
  -- Open-ended, so a newer app's type doesn't need a migration before an older database takes it.
  type text not null check (type ~ '^[a-z][a-z_]{0,39}$'),
  channel text not null default 'device' check (channel in ('device', 'push')),
  -- Set null, not cascade: the log outlives a night, and nothing here is worth refusing a delete over.
  night_id uuid references public.plan_nights (id) on delete set null,
  scheduled_for timestamptz not null,
  sent_at timestamptz,
  responded_at timestamptz,
  response text check (response in ('opened', 'done', 'snoozed', 'swap')),
  created_at timestamptz not null default now(),
  constraint notification_log_member_fkey foreign key (member_id, household_id)
    references public.members (id, household_id)
);

create index notification_log_household_idx on public.notification_log (household_id, created_at);
create index notification_log_member_idx on public.notification_log (member_id, scheduled_for);
create index notification_log_night_idx on public.notification_log (night_id);

revoke all on public.notification_log from anon, authenticated;
grant select on public.notification_log to authenticated;

alter table public.notification_log enable row level security;

create policy "planners read the log, everyone their own" on public.notification_log
  for select to authenticated
  using (public.is_household_member(household_id)
         and (public.is_household_planner(household_id) or member_id = public.my_member_id(household_id)));

-- Writes the caller's own rows and nobody else's. A row sent again (the device didn't hear back, or it's been answered since)
-- only fills in: a sent or answered time, once known, stays, and a row someone else owns is left alone. A night that isn't
-- this household's, or has gone since, reads as no night, so one old row can't hold the rest back.
create function public.record_notifications(target_household uuid, entries jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me uuid := public.my_member_id(target_household);
begin
  if me is null then
    raise exception 'not a member of this household' using errcode = '42501';
  end if;
  if jsonb_typeof(entries) <> 'array' or jsonb_array_length(entries) > 200 then
    raise exception 'entries must be an array of at most 200' using errcode = '22023';
  end if;

  insert into public.notification_log as log
    (id, household_id, member_id, type, night_id, scheduled_for, sent_at, responded_at, response)
  select e.id, target_household, me, e.type,
         (select n.id from public.plan_nights n where n.id = e.night_id and n.household_id = target_household),
         e.scheduled_for, e.sent_at, e.responded_at, e.response
  from jsonb_to_recordset(entries) as e(
    id uuid, type text, night_id uuid, scheduled_for timestamptz, sent_at timestamptz, responded_at timestamptz,
    response text)
  on conflict (id) do update
    set scheduled_for = excluded.scheduled_for,
        sent_at = coalesce(log.sent_at, excluded.sent_at),
        responded_at = coalesce(log.responded_at, excluded.responded_at),
        response = coalesce(log.response, excluded.response)
    where log.member_id = me and log.household_id = target_household;
end;
$$;

revoke execute on function public.record_notifications(uuid, jsonb) from public, anon;
grant execute on function public.record_notifications(uuid, jsonb) to authenticated;

-- Deleting and exporting ------------------------------------------------------------------------------------------------

create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Holds the nights first, so a Swap in flight can't log a new entry after the log's been emptied and fail the erase.
  perform 1 from public.plan_nights where household_id = target for update;
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
                         from public.notification_log l where household_id = target_household)
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

  -- What was sent to them is about them, kid or adult.
  delete from public.notification_log where member_id = profile.id;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    -- What they promised is off. Their profile stays, so nothing else would end it.
    update public.night_claims set released_at = now() where member_id = profile.id and released_at is null;
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
