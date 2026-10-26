-- Guardians (#78). Parents are the guardians: they manage people, edit allergies, and give or
-- revoke consent. Everyone else (kids, nannies, grandparents) can see but not change those.
-- Planner stays a planning permission only; a grandparent who cooks can plan without being a guardian.

alter table public.members
  add column guardian boolean not null default false,
  add constraint members_guardians_are_adults check (not guardian or age_group = 'adult');

-- Each household's owner profile becomes its first guardian.
update public.members m set guardian = true
from public.households h
where h.id = m.household_id and h.owner = m.user_id;

grant insert (guardian), update (guardian) on public.members to authenticated;

-- A guardian whose role is Member still manages people. Planners stay in the policy so a
-- non-guardian planner reaches the guard trigger and gets a clear error, not "0 rows".
drop policy "planners edit members, members edit themselves" on public.members;
create policy "guardians and planners edit members, members edit themselves" on public.members
  for update to authenticated
  using (public.is_household_manager(household_id) or public.is_household_planner(household_id)
         or user_id = (select auth.uid()))
  with check (public.is_household_manager(household_id) or public.is_household_planner(household_id)
              or user_id = (select auth.uid()));

-- Guardians manage the household's people. The owner counts during onboarding, before their
-- own profile exists.
create or replace function public.is_household_manager(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid()) and guardian
  ) or exists (
    select 1 from public.households where id = target_household and owner = (select auth.uid())
  );
$$;

-- Allergies: guardians edit, everyone in the household reads (select policy unchanged).
drop policy "adults add allergies with consent" on public.member_allergies;
drop policy "adults edit allergies" on public.member_allergies;
drop policy "adults remove allergies" on public.member_allergies;

create policy "guardians add allergies with consent" on public.member_allergies
  for insert to authenticated
  with check (
    public.is_household_manager(household_id)
    and public.has_active_consent(household_id, 'allergy_data')
  );

create policy "guardians edit allergies" on public.member_allergies
  for update to authenticated
  using (public.is_household_manager(household_id))
  with check (public.is_household_manager(household_id));

create policy "guardians remove allergies" on public.member_allergies
  for delete to authenticated
  using (public.is_household_manager(household_id));

-- Consents: guardians give and revoke; everyone in the household reads.
drop policy "adults give consent" on public.consents;
drop policy "adults revoke consent" on public.consents;

create policy "guardians give consent" on public.consents
  for insert to authenticated
  with check (
    granted_by = (select auth.uid())
    and public.is_household_manager(household_id)
    and (kind = 'allergy_data'
         or exists (select 1 from public.members where id = member_id and age_group = 'kid'))
  );

create policy "guardians revoke consent" on public.consents
  for update to authenticated
  using (public.is_household_manager(household_id))
  with check (public.is_household_manager(household_id));

drop function public.can_edit_allergies_of(uuid);
drop function public.is_household_adult(uuid);

-- Member guard: adds guardian to the people fields only guardians change, makes the owner's
-- own profile a guardian, and keeps the owner a guardian until they transfer ownership.
create or replace function public.members_guard_write()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  household_owner uuid;
begin
  if tg_op = 'UPDATE' and new.status = 'removed' and old.status <> 'removed' then
    new.user_id := null;
    new.away_until := null;
    -- A removed profile could be re-claimed later (#9); it must not carry guardian rights.
    new.guardian := false;
  end if;

  if caller is null then
    return new;
  end if;

  select owner into household_owner from public.households where id = new.household_id;

  if tg_op = 'INSERT' then
    -- Only the owner's own first profile is linked at insert; everyone else claims via the server (#9).
    if new.user_id is not null and new.user_id <> caller then
      raise exception 'profiles are claimed through an invite' using errcode = '42501';
    end if;
    if new.user_id = household_owner then
      new.guardian := true;
    end if;
    return new;
  end if;

  if new.household_id <> old.household_id then
    raise exception 'members cannot move between households' using errcode = '42501';
  end if;
  if new.user_id is distinct from old.user_id and new.status <> 'removed' then
    raise exception 'profiles are claimed through an invite' using errcode = '42501';
  end if;

  if old.user_id = household_owner
     and (new.role, new.age_group, new.status, new.guardian)
         is distinct from (old.role, old.age_group, old.status, old.guardian) then
    if caller <> household_owner then
      raise exception 'only the owner changes the owner''s profile' using errcode = '42501';
    end if;
    if not new.guardian or new.status = 'removed' then
      raise exception 'the owner stays a guardian; transfer ownership first' using errcode = '42501';
    end if;
  end if;

  if not public.is_household_manager(old.household_id) then
    if old.user_id is distinct from caller then
      raise exception 'only guardians manage other members' using errcode = '42501';
    end if;
    if (new.first_name, new.role, new.age_group, new.status, new.away_until, new.guardian)
       is distinct from (old.first_name, old.role, old.age_group, old.status, old.away_until, old.guardian) then
      raise exception 'members can edit only their avatar, schedule, and notification settings'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- Ownership goes to an active guardian.
create or replace function public.households_guard_owner()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.owner is distinct from old.owner and (select auth.uid()) is not null then
    if old.owner is distinct from (select auth.uid()) then
      raise exception 'only the owner transfers ownership' using errcode = '42501';
    end if;
    -- Lock the new owner's profile so a concurrent change can't un-guardian them mid-transfer.
    perform 1 from public.members
    where household_id = old.id and user_id = new.owner and guardian and status = 'active'
    for update;
    if new.owner is null or not found then
      raise exception 'ownership goes to an active guardian in the household' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
