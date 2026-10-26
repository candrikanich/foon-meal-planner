-- Parental consent and retention (#12, part 1). Decisions: planning/12-age-assurance-decisions.md.
-- * A kid's profile is invited and claimed only while a parent's consent for that kid is active.
-- * A minor's Apple account (age band from the Declared Age Range API, #88) can't claim an adult profile.
-- * Revoking a kid's parental consent unlinks their account at once and cancels open invites.
-- * Retention (COPPA): removed kid profiles are anonymized after 12 months. When a parent withdraws a
--   kid's own-device consent and doesn't give it again, what the kid added themselves is erased after
--   30 days; the parent-entered profile (name, avatar, allergies) stays while they're in the family.
--   A daily pg_cron job does both.

create extension if not exists pg_cron;

create type public.age_band as enum ('under_13', '13_15', '16_17', 'adult', 'unknown');

alter table public.members
  add column declared_age_band public.age_band,
  add column removed_at timestamptz,
  add column anonymized_at timestamptz,
  add column own_data_erased_at timestamptz;

-- Backfill: profiles already removed start their retention clock now.
update public.members set removed_at = now() where status = 'removed';

create function public.members_track_removal()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.status = 'removed' and old.status <> 'removed' then
    new.removed_at := now();
  elsif new.status <> 'removed' and old.status = 'removed' then
    new.removed_at := null;
  end if;
  return new;
end;
$$;

create trigger members_track_removal
  before update of status on public.members
  for each row execute function public.members_track_removal();

create function public.has_parental_consent(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.consents
    where member_id = target_member and kind = 'parental' and revoked_at is null
  );
$$;

revoke execute on function public.has_parental_consent(uuid) from public, anon, authenticated;

-- Revoking a kid's parental consent unlinks their account and cancels open invites.
-- SECURITY DEFINER: the guardian revoking has no direct write access to user_id or invites.
create function public.consents_unlink_on_parental_revoke()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.kind = 'parental' and old.revoked_at is null and new.revoked_at is not null then
    -- Invites first: this waits for any redeem holding an invite lock, so the unlink below sees its
    -- result instead of missing a kid who was linked a moment ago.
    update public.invites set revoked_at = now()
    where member_id = new.member_id and redeemed_at is null and revoked_at is null;
    update public.members set user_id = null where id = new.member_id and user_id is not null;
  end if;
  return null;
end;
$$;

create trigger consents_unlink_on_parental_revoke
  after update on public.consents
  for each row execute function public.consents_unlink_on_parental_revoke();

-- create_invite: a kid's profile needs an active parental consent first.
CREATE OR REPLACE FUNCTION public.create_invite(target_member uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  member public.members;
  prefix text;
  secret text;
  attempt int := 0;
begin
  -- Two parents re-inviting the same person at once take turns instead of colliding.
  perform pg_advisory_xact_lock(hashtextextended(target_member::text, 0));

  select * into member from public.members where id = target_member;
  -- The same answer whether the profile doesn't exist or isn't theirs.
  if not found or not public.is_household_manager(member.household_id) then
    raise exception 'only parents in this household can invite' using errcode = '42501';
  end if;
  if member.user_id is not null or member.status = 'removed' then
    raise exception 'only unclaimed profiles can be invited' using errcode = '22023';
  end if;
  if member.age_group = 'kid' and not public.has_parental_consent(target_member) then
    raise exception 'a parent must consent before a kid is invited' using errcode = '22023';
  end if;

  update public.invites set revoked_at = now()
  where member_id = target_member and redeemed_at is null and revoked_at is null;

  select coalesce(nullif(left(regexp_replace(upper(name), '[^A-Z]', '', 'g'), 5), ''), 'FOON')
  into prefix from public.households where id = member.household_id;

  loop
    attempt := attempt + 1;
    select string_agg(substr(public.invite_code_alphabet(), (get_byte(bytes, i) & 31) + 1, 1), '' order by i)
    into secret
    from (select extensions.gen_random_bytes(8) as bytes) random, generate_series(0, 7) as i;
    begin
      insert into public.invites (household_id, member_id, code_hash, created_by)
      values (member.household_id, target_member,
              encode(extensions.digest(secret, 'sha256'), 'hex'), (select auth.uid()));
      exit;
    exception when unique_violation then
      if attempt >= 5 then raise; end if;
    end;
  end loop;

  return prefix || '-' || left(secret, 4) || '-' || right(secret, 4);
end;
$function$;

-- redeem_invite gains the age band (from #88's Declared Age Range check; 'unknown' when there is none).
drop function public.redeem_invite(text);

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
  if member.age_group = 'adult' and age_band in ('under_13', '13_15', '16_17') then
    return 'age_mismatch';
  end if;

  update public.members set user_id = caller, declared_age_band = age_band where id = invite.member_id;
  update public.invites set redeemed_at = now(), redeemed_by = caller where id = invite.id;
  insert into public.invite_redeem_attempts (user_id, succeeded) values (caller, true);
  return 'claimed';
end;
$function$;

revoke execute on function public.redeem_invite(text, public.age_band) from public, anon;
grant execute on function public.redeem_invite(text, public.age_band) to authenticated;

-- Retention (COPPA). Returns how many profiles it changed.
-- 1. A removed kid profile, 12 months after removal: anonymized (name, avatar, allergies, settings).
-- 2. A kid whose own-device consent was withdrawn 30 days ago and not given again: what the kid added
--    themselves is erased, plus their age band. Parent-entered data stays while they're in the family.
--    Tables that store a kid's own contributions (requests, reactions, comments; M1 and M2) must add
--    their deletes here.
create function public.anonymize_expired_profiles()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  removed uuid[];
  withdrawn uuid[];
begin
  select coalesce(array_agg(m.id), '{}') into removed
  from public.members m
  where m.age_group = 'kid' and m.anonymized_at is null and m.user_id is null
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
  update public.members
  set first_name = 'Former member', avatar = null, attendance_defaults = '{}', notification_prefs = '{}',
      declared_age_band = null, anonymized_at = now()
  where id = any (removed);

  update public.members
  set declared_age_band = null, own_data_erased_at = now()
  where id = any (withdrawn);

  return cardinality(removed) + cardinality(withdrawn);
end;
$$;

revoke execute on function public.anonymize_expired_profiles() from public, anon, authenticated;

select cron.schedule('anonymize-expired-profiles', '17 3 * * *', 'select public.anonymize_expired_profiles()');
