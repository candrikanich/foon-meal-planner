-- Adults edit their own allergies one at a time (follow-up to #285). An adult who isn't a parent could only remove all of
-- theirs at once, but nobody outgrows every allergy together: someone may handle one now and not the others. Now an
-- adult on their own claimed profile can add and remove single allergies too. Adding keeps the same rule as a parent's:
-- the household must have agreed to keep allergy data, and only a parent gives that agreement. Kids' allergies, and
-- everyone else's, stay with parents. A parent can still add an allergy back after an adult removed it.

-- Same gate as "guardians add allergies with consent", on the adult's own profile only. The consent trigger
-- (member_allergies_lock_consent) also runs, so a revoke racing this insert still wins. Updates stay a parent's: the app
-- edits by removing and adding rows, never by rewriting one.
create policy "adults add their own allergies with consent" on public.member_allergies
  for insert to authenticated
  with check (
    public.is_household_member(household_id)
    and public.is_own_adult_profile(member_id)
    and public.has_active_consent(household_id, 'allergy_data')
  );

-- Copied from 20261112000000_own_allergies.sql; only the permission check changes. An adult may now set their own list
-- to anything, not just clear it. The consent check below is the one parents already go through.
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
  if not public.is_household_manager(household) and not public.is_own_adult_profile(target_member) then
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
