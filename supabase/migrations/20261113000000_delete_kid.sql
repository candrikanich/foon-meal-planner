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

  -- Their sign-in. Sessions end with it, so the kid's phone loses access on its next request.
  if kid.user_id is not null then
    delete from public.invite_redeem_attempts where user_id = kid.user_id;
    delete from auth.users where id = kid.user_id;
  end if;
end;
$$;

revoke execute on function public.delete_kid(uuid) from public, anon;
grant execute on function public.delete_kid(uuid) to authenticated;
