-- Keep only kid or adult after a claim, not Apple's age band (#88, Texas §121.055(b); decided by Chris 2026-11-11).
-- Texas says age data from the app store is deleted once it has been used to verify age. redeem_invite still takes the
-- band and still refuses a mismatch (age_mismatch) with it, but keeps only what the claim said: adult (true), a minor
-- (false), or nothing (null, when Apple didn't say).
--
-- * members.declared_adult replaces members.declared_age_band. Its one reader is delete_kid: an account on a kid's
--   profile whose claim said adult (only possible before 20261113000000 refused it) is only unlinked, never deleted.
-- * Existing bands become declared_adult, then the band column is dropped. No app build reads it; the app only sends
--   the band to redeem_invite, whose signature doesn't change.
-- * delete_account_data, anonymize_expired_profiles and delete_kid are their latest definitions with the column renamed.

alter table public.members add column declared_adult boolean;

comment on column public.members.declared_adult is
  'What the claim''s Declared Age Range said: true adult, false a minor, null not said or not claimed. Never the band (#88, Texas §121.055(b)).';

update public.members
set declared_adult = case declared_age_band when 'adult' then true when 'unknown' then null else false end
where declared_age_band is not null;

-- As agreements' (20261117000000), keeping only kid or adult.
CREATE OR REPLACE FUNCTION public.redeem_invite(code text, age_band public.age_band DEFAULT 'unknown')
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  caller uuid := (select auth.uid());
  normalized text := upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g'));
  invite public.invites;
  member public.members;
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '42501';
  end if;

  -- One redeem at a time per account, so a burst of parallel guesses can't outrun the count.
  perform pg_advisory_xact_lock(hashtextextended(caller::text, 0));

  if (select count(*) from public.invite_redeem_attempts
      where user_id = caller and not succeeded and attempted_at > now() - interval '15 minutes') >= 5 then
    return 'rate_limited';
  end if;

  if public.user_has_household() then
    return 'has_household';
  end if;

  if length(normalized) >= 8 then
    select * into invite from public.invites
    where code_hash = encode(extensions.digest(right(normalized, 8), 'sha256'), 'hex')
    for update;
  end if;

  if invite.id is null then
    insert into public.invite_redeem_attempts (user_id, succeeded) values (caller, false);
    return 'invalid';
  end if;
  if invite.redeemed_at is not null then
    return 'used';
  end if;
  if invite.revoked_at is not null or invite.expires_at < now() then
    return 'expired';
  end if;
  if not exists (
    select 1 from public.members
    where household_id = invite.household_id and user_id = invite.created_by
      and guardian and status <> 'removed'
  ) and not exists (
    select 1 from public.households where id = invite.household_id and owner = invite.created_by
  ) then
    return 'expired';
  end if;

  select * into member from public.members where id = invite.member_id for update;
  if member.user_id is not null or member.status = 'removed' then
    return 'used';
  end if;
  if member.age_group = 'kid' then
    -- Lock the consent so a parent withdrawing it at this moment waits for this claim (and then unlinks it).
    perform 1 from public.consents
    where member_id = member.id and kind = 'parental' and revoked_at is null
    for share;
    if not found or not public.has_current_parental_consent(member.id) then
      return 'needs_consent';
    end if;
  end if;
  if (member.age_group = 'adult' and age_band in ('under_13', '13_15', '16_17'))
     or (member.age_group = 'kid' and age_band = 'adult') then
    return 'age_mismatch';
  end if;

  -- Only kid or adult is kept, never the band (Texas §121.055(b)); unknown keeps nothing.
  update public.members
  set user_id = caller,
      declared_adult = case age_band when 'adult' then true when 'unknown' then null else false end
  where id = invite.member_id;
  update public.invites set redeemed_at = now(), redeemed_by = caller where id = invite.id;
  insert into public.invite_redeem_attempts (user_id, succeeded) values (caller, true);
  return 'claimed';
end;
$function$;

revoke execute on function public.redeem_invite(text, public.age_band) from public, anon;
grant execute on function public.redeem_invite(text, public.age_band) to authenticated;

-- As agreements' (20261117000000), reading declared_adult.
create or replace function public.delete_kid(target_member uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  household uuid;
  kid public.members;
  held_account uuid;
  account uuid;
begin
  select household_id into household from public.members where id = target_member;
  if household is null then
    raise exception 'they''re no longer in the family' using errcode = 'P0002';
  end if;
  -- Before the row: a device's reminder write holds this while it takes its own locks, the same order as
  -- delete_account_data and erase_household.
  perform pg_advisory_xact_lock(public.notification_log_lock(household));
  -- Locking the profile makes any write that points at it (a rating, a vote, a swap's plan change) wait for this and then
  -- fail, so nothing new can name them after their rows are gone and block the delete.
  select * into kid from public.members where id = target_member for update;
  if kid.id is null then
    raise exception 'they''re no longer in the family' using errcode = 'P0002';
  end if;
  if not public.is_household_manager(kid.household_id) then
    raise exception 'only a parent in their family deletes a kid' using errcode = '42501';
  end if;
  if kid.age_group <> 'kid' then
    raise exception 'only a kid''s profile is deleted this way' using errcode = '22023';
  end if;
  select h.held_user_id into held_account from public.agreement_holds h
   where h.member_id = kid.id and h.kind = 'parental' and h.released_at is null;

  -- After dinner. Deleting a reaction takes its hidden comment with it (cascade).
  delete from public.reactions where member_id = kid.id;
  update public.reactions set entered_by_member_id = null where entered_by_member_id = kid.id;
  -- Thanks for a dinner they cooked are about them, whoever sent them.
  delete from public.chef_thanks
  where from_member_id = kid.id or meal_log_id in (select id from public.meal_logs where cooked_by_member_id = kid.id);
  update public.meal_logs set cooked_by_member_id = null where cooked_by_member_id = kid.id;
  update public.meal_logs set confirmed_by_member_id = null where confirmed_by_member_id = kid.id;
  update public.meals set made_by_member_id = null where made_by_member_id = kid.id;
  -- A note they wrote about someone else is still their words.
  delete from public.serving_notes where member_id = kid.id or written_by_member_id = kid.id;

  -- Everyone's say.
  delete from public.request_plus_ones
  where member_id = kid.id or request_id in (select id from public.requests where requested_by_member_id = kid.id);
  update public.request_plus_ones set entered_by_member_id = null where entered_by_member_id = kid.id;
  -- Their own words on a request they entered for someone else go too; the request stays that person's.
  update public.requests set entered_by_member_id = null, note = null where entered_by_member_id = kid.id;
  delete from public.requests where requested_by_member_id = kid.id;
  delete from public.night_claims where member_id = kid.id;
  update public.night_claims set entered_by_member_id = null where entered_by_member_id = kid.id;
  delete from public.poll_votes where member_id = kid.id;
  update public.poll_votes set entered_by_member_id = null where entered_by_member_id = kid.id;
  update public.polls set started_by = null where started_by = kid.id;

  -- The week.
  delete from public.night_attendance where member_id = kid.id;
  delete from public.plan_changes where actor_member_id = kid.id;
  update public.attendance_templates set schedules = schedules - kid.id::text
  where household_id = kid.household_id and schedules ? kid.id::text;
  update public.households
  set settings = jsonb_set(settings, '{dinner_jobs,left_out}', (settings -> 'dinner_jobs' -> 'left_out') - kid.id::text)
  where id = kid.household_id and jsonb_typeof(settings -> 'dinner_jobs' -> 'left_out') = 'array'
    and settings -> 'dinner_jobs' -> 'left_out' ? kid.id::text;
  -- Lines stay with the family's list (see above); they just stop naming them.
  update public.list_items set checked_by = null where checked_by = kid.id;
  update public.list_items set urgent_by = null where urgent_by = kid.id;
  delete from public.store_runs where started_by = kid.id;

  -- Reminders. A digest is also a planner's once-a-day mark, so it stays, no longer naming them, as for a withdrawn kid.
  delete from public.notification_log where member_id = kid.id;
  update public.push_outbox set args = args - 'name', about_member_id = null
  where kind = 'new_requests' and about_member_id = kid.id;
  delete from public.push_outbox where member_id = kid.id or about_member_id = kid.id;
  delete from public.push_devices where member_id = kid.id;

  -- Who they are.
  delete from public.member_allergies where member_id = kid.id;
  delete from public.invites where member_id = kid.id;
  -- The parent asked for everything about the kid to go, and the record of consent is about the kid (#278; a Review note
  -- for counsel in retention.md). Agreements and holds first: they point at the consents.
  delete from public.agreement_holds where member_id = kid.id;
  delete from public.consent_agreements where member_id = kid.id;
  delete from public.consents where member_id = kid.id;
  delete from public.members where id = kid.id;

  -- Their sign-in. Sessions end with it, so the kid's phone loses access on its next request. An account on a kid's
  -- profile is taken to be the kid's: one account joins one household, and claiming a kid's invite is choosing to be
  -- that kid. One claimed by someone who said they're an adult (only possible before redeem_invite refused it) is only
  -- unlinked: fail closed on an account. declared_adult is all that's kept of the claim's age range (#88). A held kid's
  -- account counts while it hasn't joined a family since.
  account := kid.user_id;
  if account is null and held_account is not null
     and not exists (select 1 from public.members where user_id = held_account) then
    account := held_account;
  end if;
  if account is not null and kid.declared_adult is not true then
    delete from public.invite_redeem_attempts where user_id = account;
    delete from public.account_agreements where user_id = account;
    delete from auth.users where id = account;
  end if;
end;
$$;

revoke execute on function public.delete_kid(uuid) from public, anon;
grant execute on function public.delete_kid(uuid) to authenticated;

-- As kid_delete_own_words' (20261103040000), clearing declared_adult.
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
    update public.members set user_id = null, declared_adult = null where id = profile.id;
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
      attendance_defaults = '{}', notification_prefs = '{}', declared_adult = null, anonymized_at = now()
  where id = profile.id;
  return 'profile_anonymized';
end;
$$;

revoke execute on function public.delete_account_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_account_data(uuid) to service_role;

-- As retention_cleanup's (20261110000000), clearing declared_adult.
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
  -- Anyone removed from the family, kid or adult (#67). An adult who deletes their account is anonymized at once instead.
  where m.anonymized_at is null and m.user_id is null
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
  delete from public.serving_notes where member_id = any (removed);
  update public.requests set note = null where requested_by_member_id = any (removed);
  -- A removed person's ratings stay as anonymous history; their own words don't.
  update public.reactions set comment = null where member_id = any (removed);
  -- What a kid rated themselves (not what a parent entered for them by passing the phone) is theirs to lose.
  delete from public.reactions where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.reactions set comment = null where member_id = any (withdrawn);
  -- The thanks a kid sent from their own phone are theirs too.
  delete from public.chef_thanks where from_member_id = any (withdrawn);
  -- Notes a kid wrote themselves are theirs; ones a parent wrote for them stay.
  delete from public.serving_notes where member_id = any (withdrawn) and written_by_member_id = member_id;
  -- What a kid asked for themselves goes (the spec's "requests"), with their me-toos.
  delete from public.request_plus_ones where member_id = any (withdrawn) and entered_by_member_id = member_id;
  delete from public.request_plus_ones where request_id in
    (select id from public.requests where requested_by_member_id = any (withdrawn) and entered_by_member_id = requested_by_member_id);
  delete from public.requests where requested_by_member_id = any (withdrawn) and entered_by_member_id = requested_by_member_id;
  -- Offers to cook a kid made themselves go; ones a parent entered for them stay, and a removed kid's stay anonymous.
  delete from public.night_claims where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.night_claims set released_at = now() where member_id = any (removed) and released_at is null;
  -- A vote a kid cast themselves goes, and a poll stops saying they started it. One a parent tapped in for them stays until it ages out.
  delete from public.poll_votes where member_id = any (withdrawn) and entered_by_member_id = member_id;
  update public.polls set started_by = null where started_by = any (withdrawn);
  -- The pushes about a poll they started or something they marked for tonight were about what they did themselves, sent
  -- ones too; and a line stops saying they marked it.
  delete from public.push_outbox
  where kind in ('tonight_poll', 'urgent_item') and about_member_id = any (withdrawn);
  -- A digest is also a planner's once-a-day mark, so it stays, just no longer naming them.
  update public.push_outbox set args = args - 'name', about_member_id = null
  where kind = 'new_requests' and about_member_id = any (withdrawn);
  update public.list_items set urgent_by = null where urgent_by = any (withdrawn);
  -- A line belongs to the household (one open line per item, merged across people), so it stays; it just stops saying
  -- the kid ticked it, as it stops saying they marked it (#286).
  update public.list_items set checked_by = null where checked_by = any (withdrawn);
  -- A poll is about one dinner, so it ages out like the log, for everyone, and its votes go with it.
  delete from public.polls where created_at < now() - interval '8 weeks';
  -- A kid who plans: what they changed themselves goes. Entries about the plan itself age out below for everyone.
  delete from public.plan_changes where actor_member_id = any (withdrawn);
  delete from public.plan_changes where created_at < now() - interval '8 weeks';
  -- What was sent to someone removed or withdrawn goes with them, and the log ages out for everyone.
  delete from public.notification_log where member_id = any (removed) or member_id = any (withdrawn);
  delete from public.notification_log where created_at < now() - interval '8 weeks';
  update public.members
  set first_name = 'Former member', avatar = null, attendance_defaults = '{}', notification_prefs = '{}',
      declared_adult = null, anonymized_at = now()
  where id = any (removed);

  update public.members
  set declared_adult = null, own_data_erased_at = now()
  where id = any (withdrawn);

  -- An invite is only needed while it can be used: 30 days after it expired, was redeemed or was revoked, it goes (#67).
  -- least() skips nulls, and expires_at is never null.
  delete from public.invites where least(expires_at, redeemed_at, revoked_at) < now() - interval '30 days';
  -- The redeem rate limit looks back 15 minutes; a day is plenty.
  delete from public.invite_redeem_attempts where attempted_at < now() - interval '1 day';
  -- The import cap counts only today (UTC); keep the week claim_import_slot() keeps, for every account (#286).
  delete from public.import_usage where day < (now() at time zone 'utc')::date - 7;

  return cardinality(removed) + cardinality(withdrawn);
end;
$$;

revoke execute on function public.anonymize_expired_profiles() from public, anon, authenticated;

alter table public.members drop column declared_age_band;
