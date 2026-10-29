-- Delete household (owner): erase the household and everything in it, for everyone, and keep the account. Account
-- deletion already erased the owner's household; that erase now lives in one place, erase_household, which both use.
-- A migration that adds a household table adds its delete to erase_household (children before parents). pgTAP
-- 30_delete_household seeds every table with a household_id (and fails until a new one is seeded there), then checks
-- none keeps rows after an erase; the NO ACTION foreign keys to households also make a forgotten table fail loudly.

create function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  delete from public.request_plus_ones where household_id = target;
  delete from public.requests where household_id = target;
  delete from public.serving_notes where household_id = target;
  delete from public.chef_thanks where household_id = target;
  delete from public.reactions where household_id = target;
  delete from public.meal_logs where household_id = target;
  delete from public.night_attendance where household_id = target;
  delete from public.list_items where household_id = target;
  delete from public.plan_nights where household_id = target;
  delete from public.plans where household_id = target;
  delete from public.traditions where household_id = target;
  delete from public.meal_sides where household_id = target;
  delete from public.meal_ingredients where household_id = target;
  delete from public.meals where household_id = target;
  delete from public.items where household_id = target;
  delete from public.member_allergies where household_id = target;
  delete from public.invites where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;
revoke execute on function public.erase_household(uuid) from public, anon, authenticated;

-- Called by the delete-account Edge Function (service role) after it removes the household's photos.
create function public.delete_household_data(target_user uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  owned uuid;
begin
  select id into owned from public.households where owner = target_user;
  if owned is null then
    return 'not_owner';
  end if;
  perform public.erase_household(owned);
  return 'household_deleted';
end;
$$;
revoke execute on function public.delete_household_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_household_data(uuid) to service_role;

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
