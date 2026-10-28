-- Onboarding (#17).
-- 1. grant_allergy_consent: the one plain sentence on the allergy screen, logged with its wording version.
--    Calling it again while consent is active is a no-op.
-- 2. set_member_allergies replaces a member's allergies in one transaction (parents only, consent required by
--    the existing row-level security), so an edit never leaves them half-saved.
-- 3. update_household_settings merges keys into households.settings, so a client that doesn't know a newer
--    key never wipes it. Planners only, as before.
-- 4. create_household takes the new household's starting settings, so onboarding's flags are written in the
--    same transaction as the household: an app killed right after creating it still finds onboarding to do.

create function public.grant_allergy_consent(target_household uuid, wording text)
returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  if not public.is_household_manager(target_household) then
    raise exception 'only parents decide about allergy data' using errcode = '42501';
  end if;
  insert into public.consents (household_id, kind, text_version) values (target_household, 'allergy_data', wording)
  on conflict (household_id, kind, member_id) where revoked_at is null do nothing;
end;
$$;

revoke execute on function public.grant_allergy_consent(uuid, text) from public, anon;
grant execute on function public.grant_allergy_consent(uuid, text) to authenticated;

create function public.set_member_allergies(target_member uuid, allergens public.allergen[], custom text[])
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
begin
  select household_id into household from public.members where id = target_member;
  if household is null then
    raise exception 'no member %', target_member using errcode = 'P0002';
  end if;
  if not public.is_household_manager(household) then
    raise exception 'only parents set allergies' using errcode = '42501';
  end if;
  if not public.has_active_consent(household, 'allergy_data') then
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

revoke execute on function public.set_member_allergies(uuid, public.allergen[], text[]) from public, anon;
grant execute on function public.set_member_allergies(uuid, public.allergen[], text[]) to authenticated;

create function public.update_household_settings(target_household uuid, patch jsonb)
returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  if jsonb_typeof(patch) is distinct from 'object' then
    raise exception 'settings must be an object' using errcode = '22023';
  end if;
  if not public.is_household_planner(target_household) then
    raise exception 'only planners change household settings' using errcode = '42501';
  end if;
  update public.households set settings = settings || patch where id = target_household;
end;
$$;

revoke execute on function public.update_household_settings(uuid, jsonb) from public, anon;
grant execute on function public.update_household_settings(uuid, jsonb) to authenticated;

drop function public.create_household(text, text, text);

create function public.create_household(household_name text, household_emoji text, owner_first_name text,
                                        household_settings jsonb default '{}')
returns public.households
language plpgsql security invoker set search_path = ''
as $$
declare
  created public.households;
begin
  if jsonb_typeof(household_settings) is distinct from 'object' then
    raise exception 'settings must be an object' using errcode = '22023';
  end if;

  insert into public.households (name, emoji, settings)
  values (btrim(household_name), nullif(btrim(household_emoji), ''), household_settings)
  returning * into created;

  insert into public.members (household_id, first_name, role, user_id)
  values (created.id, btrim(owner_first_name), 'planner', (select auth.uid()));

  return created;
end;
$$;

revoke execute on function public.create_household(text, text, text, jsonb) from public, anon;
grant execute on function public.create_household(text, text, text, jsonb) to authenticated;
