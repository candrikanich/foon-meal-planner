-- People rules and allergy consent (#75).
-- * Who someone is (age_group adult|kid) is separate from what they can do (role planner|member).
-- * Ownership lives only in households.owner; transfer goes to an active adult planner.
-- * Managing people (add, roles, age group, removal, others' profiles) is for adult planners and the owner.
-- * Allergies: adult planners and the owner edit anyone's; other adults edit their own and kids'.
-- * Members can be removed: the account is unlinked, history stays.
-- * Allergy data needs a household opt-in; revoking it deletes the household's allergies.

-- Retype enums. Constraints that compare against enum literals are rebuilt around the change.
drop index public.members_one_owner_per_household;
alter table public.members drop constraint members_away_until_only_when_away;

alter type public.member_role rename to member_role_old;
create type public.member_role as enum ('planner', 'member');
alter table public.members alter column role drop default;
alter table public.members alter column role type public.member_role
  using (case role::text when 'owner' then 'planner' else role::text end)::public.member_role;
alter table public.members alter column role set default 'member';
drop type public.member_role_old;

alter type public.member_status rename to member_status_old;
create type public.member_status as enum ('active', 'away', 'removed');
alter table public.members alter column status drop default;
alter table public.members alter column status type public.member_status using status::text::public.member_status;
alter table public.members alter column status set default 'active';
drop type public.member_status_old;

alter type public.subscription_status rename to subscription_status_old;
-- lapsed: payment failed or in billing retry. cancelled: auto-renew turned off, then expired.
create type public.subscription_status as enum ('none', 'trial', 'active', 'lapsed', 'cancelled');
alter table public.households alter column subscription_status drop default;
alter table public.households alter column subscription_status type public.subscription_status
  using subscription_status::text::public.subscription_status;
alter table public.households alter column subscription_status set default 'none';
drop type public.subscription_status_old;

create type public.age_group as enum ('adult', 'kid');
alter table public.members add column age_group public.age_group not null default 'adult';

alter table public.members
  add constraint members_away_until_only_when_away check (away_until is null or status = 'away'),
  add constraint members_removed_are_unlinked check (status <> 'removed' or user_id is null);

grant insert (age_group), update (age_group) on public.members to authenticated;

-- Helpers -----------------------------------------------------------------------------------

create or replace function public.is_household_planner(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid()) and role = 'planner'
  ) or exists (
    -- The owner manages the household before their own member row exists (onboarding).
    select 1 from public.households where id = target_household and owner = (select auth.uid())
  );
$$;

create function public.is_household_adult(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid()) and age_group = 'adult'
  ) or exists (
    select 1 from public.households where id = target_household and owner = (select auth.uid())
  );
$$;

-- Adult planners and the owner manage people.
create function public.is_household_manager(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid())
      and role = 'planner' and age_group = 'adult'
  ) or exists (
    select 1 from public.households where id = target_household and owner = (select auth.uid())
  );
$$;

create function public.can_edit_allergies_of(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.members target
    join public.members caller
      on caller.household_id = target.household_id and caller.user_id = (select auth.uid())
    where target.id = target_member
      and caller.age_group = 'adult'
      and (caller.role = 'planner' or caller.id = target.id or target.age_group = 'kid')
  ) or exists (
    select 1
    from public.members target
    join public.households h on h.id = target.household_id
    where target.id = target_member and h.owner = (select auth.uid())
  );
$$;

-- Consent log -------------------------------------------------------------------------------

create type public.consent_kind as enum ('allergy_data', 'parental');

create table public.consents (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  -- Null for household-wide consent (allergy_data); a member for per-child consent (parental, #12).
  member_id uuid,
  kind public.consent_kind not null,
  -- No foreign key: the log outlives the account that gave consent.
  granted_by uuid not null default auth.uid(),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  -- Which wording the person agreed to.
  text_version text not null check (char_length(btrim(text_version)) between 1 and 40),
  foreign key (member_id, household_id) references public.members (id, household_id),
  constraint consents_revoked_after_granted check (revoked_at is null or revoked_at >= granted_at),
  constraint consents_scope_matches_kind check (
    (kind = 'allergy_data' and member_id is null) or (kind = 'parental' and member_id is not null)
  )
);

create unique index consents_one_active
  on public.consents (household_id, kind, member_id) nulls not distinct
  where revoked_at is null;

create function public.has_active_consent(target_household uuid, consent public.consent_kind)
returns boolean
language sql stable security definer set search_path = ''
as $$
  -- Answers only for the caller's own household: whether a family stores allergy data is private.
  select (public.is_household_member(target_household) or public.is_household_planner(target_household))
     and exists (
       select 1 from public.consents
       where household_id = target_household and kind = consent and member_id is null and revoked_at is null
     );
$$;

revoke execute on function
  public.is_household_adult(uuid), public.is_household_manager(uuid),
  public.can_edit_allergies_of(uuid), public.has_active_consent(uuid, public.consent_kind)
  from public, anon;
grant execute on function
  public.is_household_adult(uuid), public.is_household_manager(uuid),
  public.can_edit_allergies_of(uuid), public.has_active_consent(uuid, public.consent_kind)
  to authenticated;

revoke all on public.consents from anon, authenticated;
grant select on public.consents to authenticated;
grant insert (household_id, member_id, kind, text_version) on public.consents to authenticated;
grant update (revoked_at) on public.consents to authenticated;

alter table public.consents enable row level security;

create policy "members read household consents" on public.consents
  for select to authenticated
  using (public.is_household_member(household_id) or public.is_household_planner(household_id));

create policy "adults give consent" on public.consents
  for insert to authenticated
  with check (
    granted_by = (select auth.uid())
    and case kind
      when 'allergy_data' then public.is_household_adult(household_id)
      -- Parental consent is given for a kid's profile by an adult who manages the household.
      when 'parental' then public.is_household_manager(household_id)
        and exists (select 1 from public.members where id = member_id and age_group = 'kid')
    end
  );

create policy "adults revoke consent" on public.consents
  for update to authenticated
  using (public.is_household_adult(household_id))
  with check (public.is_household_adult(household_id));

create function public.consents_guard_update()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise exception 'a revoked consent stays revoked' using errcode = '42501';
  end if;
  -- The log records when revocation happened, not a time the client chose.
  if old.revoked_at is null and new.revoked_at is not null then
    new.revoked_at := now();
  end if;
  return new;
end;
$$;

create trigger consents_guard_update
  before update on public.consents
  for each row execute function public.consents_guard_update();

-- Revoking allergy consent erases the household's allergy data. SECURITY DEFINER because the
-- adult revoking may not be allowed to delete every member's allergies themselves.
create function public.consents_erase_on_revoke()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.kind = 'allergy_data' and new.member_id is null
     and old.revoked_at is null and new.revoked_at is not null then
    delete from public.member_allergies where household_id = new.household_id;
  end if;
  return null;
end;
$$;

create trigger consents_erase_on_revoke
  after update on public.consents
  for each row execute function public.consents_erase_on_revoke();

-- Allergy policies --------------------------------------------------------------------------

drop policy "planners add allergies" on public.member_allergies;
drop policy "planners edit allergies" on public.member_allergies;

grant delete on public.member_allergies to authenticated;

create policy "adults add allergies with consent" on public.member_allergies
  for insert to authenticated
  with check (
    public.can_edit_allergies_of(member_id)
    and public.has_active_consent(household_id, 'allergy_data')
  );

create policy "adults edit allergies" on public.member_allergies
  for update to authenticated
  using (public.can_edit_allergies_of(member_id))
  with check (public.can_edit_allergies_of(member_id));

-- Removing an allergy is a correction, not lost history.
create policy "adults remove allergies" on public.member_allergies
  for delete to authenticated
  using (public.can_edit_allergies_of(member_id));

-- Member policies and guard -----------------------------------------------------------------

drop policy "planners add members" on public.members;

create policy "managers add members" on public.members
  for insert to authenticated
  with check (public.is_household_manager(household_id));

-- The update policy stays planner-or-self so a kid planner's attempt reaches the guard and gets
-- a clear error instead of silently matching nothing.

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
    if new.user_id = household_owner and (new.role <> 'planner' or new.age_group <> 'adult') then
      raise exception 'the owner is an adult planner' using errcode = '42501';
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
     and (new.role, new.age_group, new.status) is distinct from (old.role, old.age_group, old.status) then
    if caller <> household_owner then
      raise exception 'only the owner changes the owner''s profile' using errcode = '42501';
    end if;
    if new.role <> 'planner' or new.age_group <> 'adult' or new.status = 'removed' then
      raise exception 'the owner stays an adult planner; transfer ownership first' using errcode = '42501';
    end if;
  end if;

  if not public.is_household_manager(old.household_id) then
    if old.user_id is distinct from caller then
      raise exception 'only adult planners manage other members' using errcode = '42501';
    end if;
    if (new.first_name, new.role, new.age_group, new.status, new.away_until)
       is distinct from (old.first_name, old.role, old.age_group, old.status, old.away_until) then
      raise exception 'members can edit only their avatar, schedule, and notification settings'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- Ownership transfer ------------------------------------------------------------------------

grant update (owner) on public.households to authenticated;

create function public.households_guard_owner()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.owner is distinct from old.owner and (select auth.uid()) is not null then
    if old.owner is distinct from (select auth.uid()) then
      raise exception 'only the owner transfers ownership' using errcode = '42501';
    end if;
    if new.owner is null or not exists (
      select 1 from public.members
      where household_id = old.id and user_id = new.owner
        and role = 'planner' and age_group = 'adult' and status = 'active'
    ) then
      raise exception 'ownership goes to an active adult planner in the household' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger households_guard_owner
  before update on public.households
  for each row execute function public.households_guard_owner();

-- An allergy insert locks the household's active consent, so a concurrent revoke waits for it
-- (and the insert fails if the revoke commits first). SECURITY DEFINER because row locks need
-- privileges the inserting adult may not hold on consents.
create function public.member_allergies_lock_consent()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;
  perform 1 from public.consents
  where household_id = new.household_id and kind = 'allergy_data' and member_id is null and revoked_at is null
  for share;
  if not found then
    raise exception 'allergy data needs the household''s consent' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger member_allergies_lock_consent
  before insert on public.member_allergies
  for each row execute function public.member_allergies_lock_consent();
