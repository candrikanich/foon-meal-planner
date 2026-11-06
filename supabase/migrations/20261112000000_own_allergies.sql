-- Adults can remove their own allergies (#285). Allergy consent is one household-wide agreement by a parent, and only
-- parents could change allergies, so an adult who isn't a parent had no way to delete their own health data in the
-- app (Washington's My Health My Data Act expects one). Now an adult on their own claimed profile can clear their
-- allergies. Adding and changing stay with parents, and kids' allergies stay with their parents.

-- An adult's own profile: claimed by this account, still in the family. Kids are left out on purpose. Checks the
-- session like every other access helper (#14), so a signed-out session is refused rather than told it deleted nothing.
create function public.is_own_adult_profile(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.session_is_active() and exists (
    select 1 from public.members
    where id = target_member and user_id = (select auth.uid()) and age_group = 'adult' and status <> 'removed'
  );
$$;

revoke execute on function public.is_own_adult_profile(uuid) from public, anon;
grant execute on function public.is_own_adult_profile(uuid) to authenticated;

-- Removing is the only thing it grants: insert and update keep their guardian-only policies.
create policy "adults remove their own allergies" on public.member_allergies
  for delete to authenticated
  using (public.is_household_member(household_id) and public.is_own_adult_profile(member_id));

-- Copied from 20261031020000_consent_agreements.sql; only the permission check changes. Someone who isn't a parent may
-- call it on their own adult profile with an empty answer, which deletes their allergies and keeps nothing.
create or replace function public.set_member_allergies(target_member uuid, allergens public.allergen[], custom text[])
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
  keeps_something boolean;
begin
  select household_id into household from public.members where id = target_member;
  if household is null then
    raise exception 'no member %', target_member using errcode = 'P0002';
  end if;
  keeps_something := exists (select 1 from unnest(allergens) as allergen where allergen <> 'custom')
                     or exists (select 1 from unnest(custom) as text where btrim(text) <> '');
  if not public.is_household_manager(household)
     and (keeps_something or not public.is_own_adult_profile(target_member)) then
    raise exception 'only parents set allergies' using errcode = '42501';
  end if;
  -- Keeping something needs consent. Clearing keeps nothing, so it doesn't.
  if keeps_something and not public.has_active_consent(household, 'allergy_data') then
    raise exception 'the household has not agreed to keep allergy data' using errcode = '42501';
  end if;

  delete from public.member_allergies where member_id = target_member;

  insert into public.member_allergies (household_id, member_id, category)
  select distinct household, target_member, allergen
  from unnest(allergens) as allergen
  where allergen <> 'custom';

  insert into public.member_allergies (household_id, member_id, category, custom_text)
  select distinct household, target_member, 'custom'::public.allergen, btrim(text)
  from unnest(custom) as text
  where btrim(text) <> '';
end;
$$;
