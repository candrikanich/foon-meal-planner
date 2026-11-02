-- Deleting a kid's own account now clears their comments. Every other way out of the family already did: an adult's deletion,
-- a removed kid's anonymizing, a withdrawn kid's 30 days. The comment card (#149) is the first way a kid writes free text.
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

  -- What was sent to them is about them, kid or adult. The lock lasts until they're unlinked or removed, so their device can't
  -- log a reminder after this: it waits, then finds it's no longer in the family.
  perform pg_advisory_xact_lock(public.notification_log_lock(profile.household_id));
  delete from public.notification_log where member_id = profile.id;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    -- Their profile stays, but the words were theirs. The ratings stay with the profile, as they do for an adult.
    update public.reactions set comment = null where member_id = profile.id;
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
