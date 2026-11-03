-- Deleting a kid's own account (#187, decided 2026-11-03, Chris): their own words go, not only their comments. Serving notes
-- they wrote themselves are deleted and notes on requests they made themselves are cleared. Ratings, list items and request
-- titles stay, as before, so nothing here is a hard delete of history.

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
    -- A vote they cast themselves goes, and a poll stops saying they started it.
    delete from public.poll_votes where member_id = profile.id and entered_by_member_id = profile.id;
    update public.polls set started_by = null where started_by = profile.id;
    -- The rest of their own words go too, by the same test of who wrote them as a withdrawn kid's (#187): serving notes they
    -- wrote, and the note on a request they made themselves. A request a parent entered for them keeps its note.
    delete from public.serving_notes where member_id = profile.id and written_by_member_id = profile.id;
    update public.requests set note = null
    where requested_by_member_id = profile.id and entered_by_member_id = profile.id;
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
