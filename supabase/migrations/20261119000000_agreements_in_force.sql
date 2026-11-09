-- The new wording goes into force (#277, PR D). Plan: planning/m4-277-agreements-plan.md §6. Until now every
-- agreement_versions row added by 20261117000000_agreements.sql had effective_at = null (nothing in force, every
-- agreement satisfied, no hold). From this migration:
--
-- * allergy-data-v2, own-allergy-v1, parental-invite-v2 and -v3, terms-draft-v1 and privacy-draft-v1 are in force.
--   allergy-data-v1 and parental-invite-v1 keep effective_at = null: the newest ordinal in force is what counts, and an
--   agreement to v1 is outdated because a later version requires agreeing again, whether or not v1 has a date.
-- * apply_agreement_holds() runs once here, so holds open the moment the wording changes rather than at the next hourly
--   cron run: every kid whose parental consent was given to v1 or v2 is signed out (profile kept, no erase clock), and
--   every household whose allergy agreement was v1 can't add allergies until a parent agrees again.
-- * Both renewal emails (the app's request_parental_consent and the cron's claim_consent_renewal_emails) get the same
--   fields: what changed since the wording a parent agreed to (every version that needs agreeing again, in order, up
--   to the one being emailed: v2 then v3 for a v1 kid), when a parent last agreed, whether the kid is held yet, and
--   whether they had signed in on their own device (was_linked), so the email never says a kid who never signed in
--   is "signed out".
-- * my_agreements' kids_held adds was_linked, so the app can say a kid who had their own account is signed out.
--
-- Run as the migration role (postgres, which owns these security definer functions): nobody is signed in, so
-- auth.uid() is null and household_allergy_agreement_current answers for every household, as it does for the cron job.
-- Every hold's push goes through push_outbox like any other server push ("<kid> needs a parent's OK to keep using
-- Foon." to every parent with a device, Chris's answer 7); the push sender's own cron delivers it. That needs send-push
-- with words for agreement_hold (#309) deployed first: an older send-push marks every one of these unknown_kind. The
-- renewal emails go by kick_consent_renewals, which does nothing until Vault has consent_function_url and
-- consent_cron_secret: this must not reach production before those, CONSENT_FROM and CONSENT_CRON_SECRET are set
-- (docs/parental-consent.md).

-- What changed, for a renewal email ------------------------------------------------------------------------------------

-- The "what changed" of every parental version after `agreed` up to `sent` that needs agreeing again, oldest first, as
-- one paragraph: v2's then v3's for a kid agreed to v1. An unregistered `agreed` counts from the start. With nothing
-- that needs agreeing again in between (only typo fixes), `sent`'s own summary.
create function public.parental_changes_since(agreed text, sent text)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select string_agg(v.summary, ' ' order by v.ordinal)
       from public.agreement_versions v
      where v.kind = 'parental' and v.requires_reagreement
        and v.ordinal > coalesce((select a.ordinal from public.agreement_versions a
                                   where a.version = agreed and a.kind = 'parental'), 0)
        and v.ordinal <= (select t.ordinal from public.agreement_versions t
                           where t.version = sent and t.kind = 'parental')),
    (select v.summary from public.agreement_versions v where v.version = sent and v.kind = 'parental'));
$$;

revoke execute on function public.parental_changes_since(text, text) from public, anon, authenticated;

-- The app's renewal request ----------------------------------------------------------------------------------------------

-- As 20261117000000_agreements.sql's, plus `wording`: the parental wording the Edge Function will email (its
-- TEXT_VERSION). A renewal's send outcome adds what changed since the wording a parent agreed to, up to that wording
-- (or up to the version in force when it isn't a registered parental one, or an older function gives none); when a
-- parent last agreed for this kid; whether the kid is held yet; and was_linked: the hold's, or before a hold opens,
-- whether the kid is signed in now (and so will be signed out). The two-argument version goes: a caller that doesn't
-- pass `wording` gets the default.
drop function public.request_parental_consent(uuid, text);

create function public.request_parental_consent(target_member uuid, email_address text default null,
                                                wording text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  kid public.members;
  account_email text;
  address text;
  source text;
  open_request public.parental_consent_requests;
  send_id bigint;
  request_reason text;
  active uuid;
  open_hold public.agreement_holds;
  sent text;
  renewal jsonb := '{}'::jsonb;
begin
  if caller is null or not public.session_is_active() then
    -- Its own code, so the Edge Function answers 401 (sign in again), not 403.
    raise exception 'sign in first' using errcode = '28000';
  end if;

  select * into kid from public.members where id = target_member;
  if not found or not public.is_household_manager(kid.household_id) then
    raise exception 'only parents in this household ask for consent' using errcode = '42501';
  end if;
  request_reason := case when public.has_parental_consent(kid.id) then 'renewal' else 'invite' end;
  if kid.age_group <> 'kid' or kid.status = 'removed' or (kid.user_id is not null and request_reason = 'invite') then
    raise exception 'only an unclaimed kid''s profile needs consent' using errcode = '22023';
  end if;
  if public.has_current_parental_consent(kid.id) then
    return jsonb_build_object('outcome', 'already_consented');
  end if;

  account_email := public.verified_account_email(caller);
  if account_email is not null then
    address := account_email;
    source := 'account';
  elsif nullif(btrim(email_address), '') is not null then
    address := lower(btrim(email_address));
    if char_length(address) > 254 or address !~ '^[^@\s<>",;]+@[^@\s<>",;]+\.[^@\s<>",;]+$' then
      raise exception 'that email doesn''t look right' using errcode = '22000';
    end if;
    source := 'typed';
  else
    return jsonb_build_object('outcome', 'no_email');
  end if;

  -- One request at a time, so parallel ones can't each slip under the limits.
  perform pg_advisory_xact_lock(hashtext('request_parental_consent'));

  select * into open_request from public.parental_consent_requests
   where member_id = kid.id and requested_by = caller and status in ('pending', 'consented')
   order by created_at desc limit 1
   for update;
  -- An agreed request (consented) waits for email 2, which tapping I agree again resends: a new email 1 would throw
  -- the agreement away.
  if open_request.id is not null
     and (open_request.status = 'consented'
          or open_request.token_sent_at > now() - interval '10 minutes'
          or open_request.send_reserved_at > now() - interval '5 minutes') then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;
  if (select count(*) from public.parental_consent_sends
      where requested_by = caller and reserved_at > now() - interval '1 day') >= 5
     or (select count(*) from public.parental_consent_sends
         where reserved_at > now() - interval '1 hour') >= 200
     or (select count(*) from public.parental_consent_sends
         where household_id = kid.household_id and reserved_at > now() - interval '1 day') >= 10 then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  select * into open_hold from public.agreement_holds h
   where h.member_id = kid.id and h.kind = 'parental' and h.released_at is null;
  if open_request.id is null then
    insert into public.parental_consent_requests (household_id, member_id, requested_by, email_source, typed_email,
                                                  pending_email_hash, send_reserved_at, reason, hold_id)
    values (kid.household_id, kid.id, caller, source,
            case when source = 'typed' then address end, public.consent_email_hash(address), now(), request_reason,
            open_hold.id)
    returning * into open_request;
  else
    update public.parental_consent_requests
       set send_reserved_at = now(), pending_email_source = source,
           pending_typed_email = case when source = 'typed' then address end,
           pending_email_hash = public.consent_email_hash(address), reason = request_reason
     where id = open_request.id;
  end if;
  insert into public.parental_consent_sends (request_id, household_id, requested_by, reserved_at)
  values (open_request.id, kid.household_id, caller, now())
  returning id into send_id;

  -- What claim_consent_renewal_emails gives the cron's renewal email, so the app's reads the same.
  if request_reason = 'renewal' then
    select id into active from public.consents
     where member_id = kid.id and kind = 'parental' and revoked_at is null;
    sent := coalesce((select v.version from public.agreement_versions v
                       where v.version = wording and v.kind = 'parental'),
                     public.current_agreement_version('parental'));
    renewal := jsonb_build_object(
      'summary', public.parental_changes_since(public.latest_agreed_version(active, 'parental'), sent),
      'agreed_before', coalesce((select max(a.agreed_at) from public.consent_agreements a
                                  where a.consent_id = active and a.kind = 'parental'),
                                (select c.granted_at from public.consents c where c.id = active)),
      'held', open_hold.id is not null,
      'was_linked', coalesce(open_hold.was_linked, kid.user_id is not null));
  end if;

  return jsonb_build_object('outcome', 'send', 'request_id', open_request.id, 'send_id', send_id,
                            'email', address, 'email_source', source, 'first_name', kid.first_name,
                            'reason', request_reason, 'text_version', public.current_agreement_version('parental'))
         || renewal;
end;
$$;

revoke execute on function public.request_parental_consent(uuid, text, text) from public, anon;
grant execute on function public.request_parental_consent(uuid, text, text) to authenticated;

-- The cron's renewal emails --------------------------------------------------------------------------------------------

-- As 20261118000000_agreement_renewal_sends.sql's, with the same renewal fields as the app's request: "summary" is what
-- changed from the hold's held_version up to `wording` (every version that needs agreeing again, in order), and
-- "was_linked" is the hold's. Returns, oldest hold first:
--   [{"request_id", "send_id", "email", "first_name", "reminder", "held_version", "required_version", "summary",
--     "agreed_at", "was_linked"}]
create or replace function public.claim_consent_renewal_emails(batch_size int, wording text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  candidate record;
  hold public.agreement_holds;
  recipient record;
  kid_name text;
  agreed timestamptz;
  new_request uuid;
  new_send bigint;
  stale uuid;
  claimed jsonb := '[]'::jsonb;
begin
  if not public.parental_wording_ok(wording) then
    raise exception 'wording % isn''t the one in force', wording using errcode = '22023';
  end if;
  -- The same lock as request_parental_consent, so the overall cap counts both.
  perform pg_advisory_xact_lock(hashtext('request_parental_consent'));
  <<holds>>
  for candidate in select h.id, h.member_id from public.agreement_holds h
                    where h.kind = 'parental' and h.released_at is null
                    order by h.held_at loop
    -- The kid's lock before the hold's row, in the same order as activate_parental_consent and apply_agreement_holds,
    -- so a parent agreeing while their renewal email is claimed waits instead of deadlocking.
    perform pg_advisory_xact_lock(hashtextextended('parental_consent:' || candidate.member_id::text, 0));
    select * into hold from public.agreement_holds where id = candidate.id and released_at is null for update;
    continue holds when hold.id is null;
    select first_name into kid_name from public.members where id = hold.member_id;
    agreed := coalesce((select max(a.agreed_at) from public.consent_agreements a
                         where a.consent_id = hold.consent_id and a.kind = 'parental'),
                       (select c.granted_at from public.consents c where c.id = hold.consent_id));
    for recipient in select * from public.consent_renewal_recipients(hold) loop
      exit holds when jsonb_array_length(claimed) >= greatest(batch_size, 0)
                   or (select count(*) from public.parental_consent_sends
                        where reserved_at > now() - interval '1 hour') >= 200;
      for stale in select id from public.parental_consent_requests
                    where member_id = hold.member_id and requested_by = recipient.account and status = 'pending'
                    for update loop
        perform public.end_parental_consent_request(stale, 'cancelled');
      end loop;
      insert into public.parental_consent_requests (household_id, member_id, requested_by, email_source,
                                                    pending_email_hash, send_reserved_at, reason, hold_id)
      values (hold.household_id, hold.member_id, recipient.account, 'account',
              public.consent_email_hash(recipient.address), now(), 'renewal', hold.id)
      returning id into new_request;
      insert into public.parental_consent_sends (request_id, household_id, requested_by, reserved_at)
      values (new_request, hold.household_id, recipient.account, now())
      returning id into new_send;
      claimed := claimed || jsonb_build_array(jsonb_build_object(
        'request_id', new_request, 'send_id', new_send, 'email', recipient.address, 'first_name', kid_name,
        'reminder', recipient.reminder, 'held_version', hold.held_version,
        'required_version', hold.required_version,
        'summary', public.parental_changes_since(hold.held_version, wording), 'agreed_at', agreed,
        'was_linked', hold.was_linked));
    end loop;
  end loop;
  return claimed;
end;
$$;

-- What the app needs to know ---------------------------------------------------------------------------------------------

-- As 20261117000000_agreements.sql's, plus was_linked on each held kid: whether the kid had signed in on their own
-- device when the hold began, so the app can say they're signed out (older apps ignore it).
create or replace function public.my_agreements(target_household uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  me uuid;
  result jsonb;
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  result := jsonb_build_object('terms', public.account_agreement_status(caller, 'terms'),
                               'privacy', public.account_agreement_status(caller, 'privacy'),
                               'allergy', null, 'kids_held', '[]'::jsonb);
  if target_household is null then
    return result;
  end if;
  if not (public.is_household_member(target_household) or public.is_household_planner(target_household)) then
    raise exception 'not in this household' using errcode = '42501';
  end if;

  select id into me from public.members where household_id = target_household and user_id = caller;
  result := result || jsonb_build_object('allergy', jsonb_build_object(
    'current', public.current_agreement_version('allergy_data'),
    'summary', (select v.summary from public.agreement_versions v
                 where v.version = public.current_agreement_version('allergy_data')),
    'consented', exists (select 1 from public.consents c
                          where c.household_id = target_household and c.kind = 'allergy_data'
                            and c.member_id is null and c.revoked_at is null),
    'household_current', public.household_allergy_agreement_current(target_household),
    'held', exists (select 1 from public.agreement_holds h
                     where h.household_id = target_household and h.kind = 'allergy_data' and h.released_at is null),
    'own_current', me is null or public.own_allergy_agreement_current(me),
    'own_version', public.current_agreement_version('own_allergy_data'),
    'own_summary', (select v.summary from public.agreement_versions v
                     where v.version = public.current_agreement_version('own_allergy_data'))));

  if public.is_household_manager(target_household) then
    result := result || jsonb_build_object('kids_held', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'member_id', h.member_id, 'first_name', m.first_name, 'held_at', h.held_at,
               'emailed_at', h.emailed_at, 'reminded_at', h.reminded_at,
               'held_version', h.held_version, 'required_version', h.required_version,
               'was_linked', h.was_linked,
               'summary', (select v.summary from public.agreement_versions v where v.version = h.required_version),
               'emailed_me_at', (select max(r.token_sent_at) from public.parental_consent_requests r
                                  where r.hold_id = h.id and r.requested_by = caller))
             order by h.held_at, m.first_name), '[]'::jsonb)
        from public.agreement_holds h
        join public.members m on m.id = h.member_id
       where h.household_id = target_household and h.kind = 'parental' and h.released_at is null));
  end if;
  return result;
end;
$$;

-- Turn it on ----------------------------------------------------------------------------------------------------------------

-- now() is this transaction's start, so current_agreement_version (effective_at <= now()) sees these at once.
update public.agreement_versions
   set effective_at = now()
 where version in ('allergy-data-v2', 'own-allergy-v1', 'parental-invite-v2', 'parental-invite-v3', 'terms-draft-v1',
                   'privacy-draft-v1')
   and effective_at is null;

-- Holds now, not at the hourly job's next run (see the top). Safe to run here: it's the cron job's own call, takes the
-- same per-kid locks, and opens nothing twice (one open hold per kid and per household).
select public.apply_agreement_holds();
