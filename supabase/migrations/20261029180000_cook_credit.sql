-- Cook credit (#46, part 1). Every logged dinner already records who cooked (meal_logs.cooked_by_member_id). A one-tap
-- "Thanks, chef" from anyone else at the table makes it visible: one thanks per person per dinner, never to yourself,
-- for a dinner from the last week (the card's reach), and never deleted (except by retention and deleting the
-- household). The monthly tally is counted in the app from the logs.

create table public.chef_thanks (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  meal_log_id uuid not null,
  -- Who said thanks: the signed-in person's own profile, stamped by the server.
  from_member_id uuid not null,
  created_at timestamptz not null default now(),
  constraint chef_thanks_once unique (meal_log_id, from_member_id),
  constraint chef_thanks_log_fkey foreign key (meal_log_id, household_id) references public.meal_logs (id, household_id),
  constraint chef_thanks_from_fkey foreign key (from_member_id, household_id)
    references public.members (id, household_id)
);

create index chef_thanks_household_idx on public.chef_thanks (household_id);

revoke all on public.chef_thanks from anon, authenticated;
grant select on public.chef_thanks to authenticated;

alter table public.chef_thanks enable row level security;

create policy "members read thanks" on public.chef_thanks
  for select to authenticated using (public.is_household_member(household_id));

-- Thanks, chef: from your own profile, to whoever cooked a dinner in the last week, once. Returns nothing; saying it
-- twice is fine.
create function public.thank_the_chef(target_log uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  log public.meal_logs;
  night_date date;
  me uuid;
begin
  select * into log from public.meal_logs where id = target_log;
  if log.id is null or not public.is_household_member(log.household_id) then
    raise exception 'no dinner %', target_log using errcode = 'P0002';
  end if;
  me := public.my_member_id(log.household_id);
  if me is null then
    raise exception 'thanks come from your own profile' using errcode = '42501';
  end if;
  if log.cooked_by_member_id is null then
    raise exception 'nobody is down as the cook' using errcode = '22023';
  end if;
  if log.meal_id is null then
    raise exception 'thanks are for a cooked dish' using errcode = '22023';
  end if;
  if log.cooked_by_member_id = me then
    raise exception 'no thanking yourself' using errcode = '22023';
  end if;
  select date into night_date from public.plan_nights where id = log.night_id;
  if night_date < public.household_today(log.household_id) - 7 then
    raise exception 'that dinner was too long ago' using errcode = '22023';
  end if;
  insert into public.chef_thanks (household_id, meal_log_id, from_member_id)
  values (log.household_id, log.id, me)
  on conflict (meal_log_id, from_member_id) do nothing;
end;
$$;

revoke execute on function public.thank_the_chef(uuid) from public, anon;
grant execute on function public.thank_the_chef(uuid) to authenticated;

-- Thanks are for the person who cooked. Once someone has said it, the cook (and the dish) stay as they were, so a
-- later edit can't move the thanks to someone else, or to the person who sent them.
create function public.meal_logs_keep_the_thanked_cook()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user = 'authenticated'
     and (new.cooked_by_member_id, new.meal_id) is distinct from (old.cooked_by_member_id, old.meal_id)
     and exists (select 1 from public.chef_thanks where meal_log_id = old.id) then
    raise exception 'someone already thanked the cook for this dinner' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger meal_logs_keep_the_thanked_cook before update on public.meal_logs
  for each row execute function public.meal_logs_keep_the_thanked_cook();

-- Deletion, export, and kid retention cover thanks.
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
                    from public.chef_thanks t where household_id = target_household)
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
  -- A removed kid's ratings stay as anonymous history; their own words don't.
  update public.reactions set comment = null where member_id = any (removed);
  -- What a kid rated themselves (not what a parent entered for them by passing the phone) is theirs to lose.
  delete from public.reactions where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.reactions set comment = null where member_id = any (withdrawn);
  -- The thanks a kid sent from their own phone are theirs too.
  delete from public.chef_thanks where from_member_id = any (withdrawn);
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
