-- Delete everything about a child, now (#278). COPPA 312.6 lets a parent have their child's information deleted, and
-- withdrawing consent or removing a kid waits 30 days or 12 months and leaves their sign-in account. delete_kid is the
-- second exception to "never hard-delete user content" besides deleting the household (decided 2026-11-06, #278): any
-- parent (guardian) in the kid's family deletes the kid's profile, everything about them, and their sign-in account, in
-- one transaction.
--
-- What goes: the profile; their allergies; their ratings and comments (hidden ones too); thank-yous they sent, and the
-- ones sent to them for a dinner they cooked; serving notes about them or written by them; their requests and me-toos;
-- their offers to cook; their attendance on every night; their poll votes; plan changes they made; the reminder log, push
-- devices and pushes for or about them; a store run they started; invites for them; their parental consent records; their
-- part of saved schedules and of the dinner jobs' left-out list; their invite guesses; and their auth user, whose
-- sessions, identities and import counts go with it by cascade.
--
-- What stays, no longer naming them: plans and nights, dishes, dinners logged (the cook and the confirmer cleared), and
-- the household's list lines. list_items record no author, and a line merges everyone's adds (one open line per item), so
-- a kid's lines stay with the family's list, with who checked or marked them cleared, as for a withdrawn kid (#286). A
-- rating, me-too, offer, vote, request or note they entered for someone else stays that person's, without saying who
-- entered it; a plan's history, the dishes and the receipts' corrections are the family's.
--
-- The auth user is deleted here rather than by an Edge Function with the admin API: one transaction can't leave the data
-- gone and the account behind, or the other way round. No Sign in with Apple token is revoked, since only the kid's own
-- fresh sign-in could, which is why their own Delete my account still goes through delete-account.
--
-- Because it deletes an account, "kid" must mean a kid: members_guard_write now refuses to make someone who signed in as
-- an adult a kid, or one parent could flip another adult and delete them; and redeem_invite refuses someone who says
-- they're an adult a kid's profile, as it already refused a minor an adult's. The app doesn't send an age yet (#88), so
-- until it does, whoever claims a kid's invite is taken to be the kid, and their account goes with the profile.

create function public.delete_kid(target_member uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  household uuid;
  kid public.members;
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
  -- for counsel in retention.md).
  delete from public.consents where member_id = kid.id;
  delete from public.members where id = kid.id;

  -- Their sign-in. Sessions end with it, so the kid's phone loses access on its next request. An account on a kid's
  -- profile is taken to be the kid's: one account joins one household, and claiming a kid's invite is choosing to be
  -- that kid. One claimed by someone who said they're an adult (only possible before redeem_invite refused it) is only
  -- unlinked: fail closed on an account.
  if kid.user_id is not null and kid.declared_age_band is distinct from 'adult' then
    delete from public.invite_redeem_attempts where user_id = kid.user_id;
    delete from auth.users where id = kid.user_id;
  end if;
end;
$$;

revoke execute on function public.delete_kid(uuid) from public, anon;
grant execute on function public.delete_kid(uuid) to authenticated;

-- As household_shapes' (20261030230000), plus: a signed-in adult can't be made a kid (see above, #278).
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

  if caller is null or current_user <> 'authenticated' then
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

  -- delete_kid deletes a kid's sign-in account, so someone who signed in as an adult never becomes a kid: otherwise one
  -- parent could flip another adult and delete their account (#278). A kid who grows up can become an adult; to undo
  -- that, remove them.
  if old.user_id is not null and old.age_group = 'adult' and new.age_group = 'kid' and new.status <> 'removed' then
    raise exception 'someone who signed in as an adult stays an adult' using errcode = '42501';
  end if;

  if old.user_id = household_owner
     and (new.role, new.age_group, new.status, new.guardian, new.eats_separately)
         is distinct from (old.role, old.age_group, old.status, old.guardian, old.eats_separately) then
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
    if (new.first_name, new.role, new.age_group, new.status, new.away_until, new.guardian, new.eats_separately)
       is distinct from (old.first_name, old.role, old.age_group, old.status, old.away_until, old.guardian, old.eats_separately) then
      raise exception 'members can edit only their avatar, schedule, and notification settings'
        using errcode = '42501';
    end if;
  end if;

  -- A schedule saved from the app changes the keys it sends: an older app or a stale phone doesn't know them all.
  if new.attendance_defaults is distinct from old.attendance_defaults then
    -- Only the top level: a null inside a pattern is a bad pattern, not a key taken away.
    select coalesce(jsonb_object_agg(kept.key, kept.value), '{}'::jsonb) into new.attendance_defaults
    from jsonb_each(old.attendance_defaults || new.attendance_defaults) as kept
    where kept.value <> 'null'::jsonb;
  end if;

  return new;
end;
$$;

-- As parental_consent_and_retention's (20261026205731), plus: someone who says they're an adult can't claim a kid's
-- profile (#278), since a parent can delete a kid's account.
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
    if not found then
      return 'needs_consent';
    end if;
  end if;
  if (member.age_group = 'adult' and age_band in ('under_13', '13_15', '16_17'))
     or (member.age_group = 'kid' and age_band = 'adult') then
    return 'age_mismatch';
  end if;

  update public.members set user_id = caller, declared_age_band = age_band where id = invite.member_id;
  update public.invites set redeemed_at = now(), redeemed_by = caller where id = invite.id;
  insert into public.invite_redeem_attempts (user_id, succeeded) values (caller, true);
  return 'claimed';
end;
$function$;
