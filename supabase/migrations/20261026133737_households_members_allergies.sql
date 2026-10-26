-- Core tenancy (#4): households, members, member allergies, and the RLS helpers every
-- household-owned table uses. Nothing here is hard-deleted through the API.

create type public.member_role as enum ('owner', 'planner', 'member');
create type public.member_status as enum ('active', 'away');
create type public.subscription_status as enum ('none', 'trial', 'active', 'lapsed');
create type public.allergen as enum (
  'milk', 'eggs', 'fish', 'shellfish', 'tree_nuts', 'peanuts', 'wheat', 'soy', 'sesame', 'custom'
);

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 50),
  emoji text check (char_length(emoji) <= 16),
  -- Null after the owner deletes their account; the household and its history stay.
  owner uuid default auth.uid() references auth.users (id) on delete set null,
  settings jsonb not null default '{}' check (jsonb_typeof(settings) = 'object'),
  founding boolean not null default false,
  subscription_status public.subscription_status not null default 'none',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One household per person in v1.
create unique index households_owner_key on public.households (owner);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  first_name text not null check (char_length(btrim(first_name)) between 1 and 30),
  avatar text check (char_length(avatar) <= 64),
  role public.member_role not null default 'member',
  status public.member_status not null default 'active',
  away_until date,
  -- Null until the person signs in and claims the profile. Account deletion keeps the profile's history.
  user_id uuid references auth.users (id) on delete set null,
  attendance_defaults jsonb not null default '{}' check (jsonb_typeof(attendance_defaults) = 'object'),
  notification_prefs jsonb not null default '{}' check (jsonb_typeof(notification_prefs) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint members_away_until_only_when_away check (away_until is null or status = 'away'),
  -- Target for composite foreign keys so child rows can't cross households.
  constraint members_id_household_key unique (id, household_id)
);

create index members_household_id_idx on public.members (household_id);
create unique index members_user_id_key on public.members (user_id) where user_id is not null;
create unique index members_one_owner_per_household on public.members (household_id) where role = 'owner';

create table public.member_allergies (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  member_id uuid not null,
  category public.allergen not null,
  custom_text text check (char_length(custom_text) <= 60),
  created_at timestamptz not null default now(),
  foreign key (member_id, household_id) references public.members (id, household_id),
  constraint member_allergies_custom_needs_text
    check ((category = 'custom') = (custom_text is not null and btrim(custom_text) <> ''))
);

create index member_allergies_household_id_idx on public.member_allergies (household_id);
create unique index member_allergies_standard_key
  on public.member_allergies (member_id, category) where category <> 'custom';

-- RLS helpers -------------------------------------------------------------------------------
-- SECURITY DEFINER so policies on members can call them without recursing into members' own RLS.

create function public.is_household_member(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid())
  );
$$;

create function public.is_household_planner(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid()) and role in ('owner', 'planner')
  ) or exists (
    -- The owner manages the household before their own member row exists (onboarding).
    select 1 from public.households where id = target_household and owner = (select auth.uid())
  );
$$;

-- One household per person in v1: owning one or holding a profile in one both count.
create function public.user_has_household()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.members where user_id = (select auth.uid()))
      or exists (select 1 from public.households where owner = (select auth.uid()));
$$;

revoke execute on function
  public.is_household_member(uuid), public.is_household_planner(uuid), public.user_has_household()
  from public, anon;
grant execute on function
  public.is_household_member(uuid), public.is_household_planner(uuid), public.user_has_household()
  to authenticated;

-- Grants: no anon access, no client deletes, server-owned columns not writable ------------

revoke all on public.households, public.members, public.member_allergies from anon, authenticated;

grant select on public.households to authenticated;
grant insert (id, name, emoji, settings) on public.households to authenticated;
grant update (name, emoji, settings) on public.households to authenticated;

grant select on public.members to authenticated;
grant insert (id, household_id, first_name, avatar, role, status, away_until, user_id,
              attendance_defaults, notification_prefs) on public.members to authenticated;
grant update (first_name, avatar, role, status, away_until, attendance_defaults, notification_prefs)
  on public.members to authenticated;

grant select on public.member_allergies to authenticated;
grant insert (id, household_id, member_id, category, custom_text) on public.member_allergies to authenticated;
grant update (category, custom_text) on public.member_allergies to authenticated;

-- Policies ----------------------------------------------------------------------------------

alter table public.households enable row level security;
alter table public.members enable row level security;
alter table public.member_allergies enable row level security;

create policy "members read their household" on public.households
  for select to authenticated
  using (public.is_household_member(id) or owner = (select auth.uid()));

create policy "users create a household they own" on public.households
  for insert to authenticated
  with check (owner = (select auth.uid()) and not public.user_has_household());

create policy "planners edit their household" on public.households
  for update to authenticated
  using (public.is_household_planner(id))
  with check (public.is_household_planner(id));

create policy "members read household members" on public.members
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));

create policy "planners add members" on public.members
  for insert to authenticated
  with check (public.is_household_planner(household_id));

-- Column limits for non-planners are enforced by members_guard_update below.
create policy "planners edit members, members edit themselves" on public.members
  for update to authenticated
  using (public.is_household_planner(household_id) or user_id = (select auth.uid()))
  with check (public.is_household_planner(household_id) or user_id = (select auth.uid()));

create policy "members read household allergies" on public.member_allergies
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));

create policy "planners add allergies" on public.member_allergies
  for insert to authenticated
  with check (public.is_household_planner(household_id));

create policy "planners edit allergies" on public.member_allergies
  for update to authenticated
  using (public.is_household_planner(household_id))
  with check (public.is_household_planner(household_id));

-- Member write guard ------------------------------------------------------------------------
-- Row policies can't limit columns per caller, so this trigger does. It skips trusted
-- contexts with no signed-in user (service role in Edge Functions, migrations, seeds).

create function public.members_guard_write()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  caller_is_owner boolean;
begin
  if caller is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- Only the owner's own first profile is linked at insert; everyone else claims via the server (#9).
    if new.user_id is not null and new.user_id <> caller then
      raise exception 'profiles are claimed through an invite' using errcode = '42501';
    end if;
    if new.role = 'owner'
       and not exists (select 1 from public.households where id = new.household_id and owner = caller) then
      raise exception 'only the household owner holds the owner role' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.household_id <> old.household_id then
    raise exception 'members cannot move between households' using errcode = '42501';
  end if;
  if new.user_id is distinct from old.user_id then
    raise exception 'profiles are claimed through an invite' using errcode = '42501';
  end if;

  if not public.is_household_planner(old.household_id) then
    if (new.first_name, new.role, new.status, new.away_until)
       is distinct from (old.first_name, old.role, old.status, old.away_until) then
      raise exception 'members can edit only their avatar, schedule, and notification settings'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if (old.role = 'owner' or new.role = 'owner') and new.role is distinct from old.role then
    select exists (select 1 from public.households where id = old.household_id and owner = caller)
      into caller_is_owner;
    if not caller_is_owner then
      raise exception 'only the owner can change the owner role' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger members_guard_write
  before insert or update on public.members
  for each row execute function public.members_guard_write();

-- updated_at --------------------------------------------------------------------------------

create function public.set_updated_at()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger households_set_updated_at before update on public.households
  for each row execute function public.set_updated_at();
create trigger members_set_updated_at before update on public.members
  for each row execute function public.set_updated_at();
