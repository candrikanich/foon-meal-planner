-- Retention cleanup (#286).
-- 1. set_meal_photo: points a meal at a newly uploaded photo and returns the path it pointed at before, read under the
--    row lock, so the app deletes exactly the object nothing points at any more, even if another phone replaced it
--    since this one last looked. Storage objects are deleted through the Storage API (the app, as a planner), never by
--    deleting storage.objects rows here, which would leave the file behind.
-- 2. The daily retention job (anonymize_expired_profiles) also prunes import_usage rows more than 7 days old, the same
--    window claim_import_slot() prunes on the way past, so an account that stops importing doesn't keep its last count.
-- 3. A withdrawn kid's list lines stay with the household (lines record no author and merge across people, so the spec
--    now says so), but stop naming the kid as who ticked them, as they already stop naming who marked them for tonight.

create function public.set_meal_photo(target_meal uuid, new_path text)
returns text
language plpgsql security invoker set search_path = ''
as $$
declare
  previous text;
begin
  -- FOR UPDATE also applies the update policy, so only the household's planners find the row.
  select photo_path into previous from public.meals where id = target_meal for update;
  if not found then
    raise exception 'no meal % to change', target_meal using errcode = '42501';
  end if;
  update public.meals set photo_path = new_path where id = target_meal;
  return previous;
end;
$$;

revoke execute on function public.set_meal_photo(uuid, text) from public, anon;
grant execute on function public.set_meal_photo(uuid, text) to authenticated;

-- As #67's, plus import_usage and a withdrawn kid's checked_by.
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
      declared_age_band = null, anonymized_at = now()
  where id = any (removed);

  update public.members
  set declared_age_band = null, own_data_erased_at = now()
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
