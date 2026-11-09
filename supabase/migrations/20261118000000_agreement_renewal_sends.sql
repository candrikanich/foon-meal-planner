-- Renewal emails, after review of #306 (#277, PR B). Still dormant: nothing is in force until PR D.
--
-- * The Edge Function sends its wording (TEXT_VERSION) whenever that wording is registered and satisfies what's in
--   force, not only when it equals one exact version: a function deployed ahead with newer registered wording keeps
--   sending through a rollout, and one left on outdated wording never sends. parental_wording_ok says which, and
--   claim_consent_renewal_emails takes the wording and refuses (22023) before reserving anything.
-- * A hold's round clock (emailed_at, reminded_at) starts when an email is recorded as sent, not when it's reserved:
--   a reservation released after a failed send leaves the hold as it was, and the parent is claimed again next run
--   (parental_consent_release_send deletes a request whose email never went out).
-- * parental_consent_decide also returns the request's reason, so the confirming email after a renewal says the kid is
--   back in, not "invite them now".

-- Whether the Edge Function may send this parental wording: registered, and satisfying what's in force (any registered
-- wording while none is). Service role only.
create function public.parental_wording_ok(wording text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.agreement_versions where version = wording and kind = 'parental')
         and public.agreement_satisfies(wording, 'parental');
$$;

revoke execute on function public.parental_wording_ok(text) from public, anon, authenticated;
grant execute on function public.parental_wording_ok(text) to service_role;

-- From 20261117000000_agreements.sql, plus: recording a renewal's email starts its hold's round clock. In the
-- reminder window (first email over 7 days ago, as consent_renewal_recipients decides) it's the reminder.
create or replace function public.parental_consent_mark_sent(p_request_id uuid, p_send_id bigint, p_token_hash text,
                                                             p_text_version text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
  other uuid;
  kid uuid;
begin
  if not public.parental_wording_ok(p_text_version) then
    raise exception 'wording % isn''t the one in force', p_text_version using errcode = '22023';
  end if;
  -- The same per-kid lock as activate, before any row lock: two parents' sends for one kid cancel each other's pending
  -- request, and would otherwise lock the two rows in opposite orders.
  select member_id into kid from public.parental_consent_requests where id = p_request_id;
  if kid is not null then
    perform pg_advisory_xact_lock(hashtextextended('parental_consent:' || kid::text, 0));
  end if;
  update public.parental_consent_requests
     set token_hash = p_token_hash, token_sent_at = now(), expires_at = now() + interval '7 days',
         email_hash = pending_email_hash, pending_email_hash = null,
         email_source = coalesce(pending_email_source, email_source),
         typed_email = case pending_email_source when 'typed' then pending_typed_email when 'account' then null
                            else typed_email end,
         pending_email_source = null, pending_typed_email = null, send_reserved_at = null,
         text_version = p_text_version
   where id = p_request_id and status = 'pending'
  returning * into request;
  update public.parental_consent_sends set sent = true where id = p_send_id;
  if request.id is null then return false; end if;
  if request.reason = 'invite' then
    for other in select id from public.parental_consent_requests
                  where member_id = request.member_id and id <> request.id and status = 'pending'
                  for update loop
      perform public.end_parental_consent_request(other, 'cancelled');
    end loop;
  elsif request.hold_id is not null then
    update public.agreement_holds
       set reminded_at = case when emailed_at < now() - interval '7 days' then coalesce(reminded_at, now())
                              else reminded_at end,
           emailed_at = coalesce(emailed_at, now())
     where id = request.hold_id and released_at is null;
  end if;
  return true;
end;
$$;

-- From 20261117000000_agreements.sql, with the wording the function will send: refused (22023) before anything is
-- reserved unless parental_wording_ok, and its "what changed" is the one returned. Reserving no longer touches the
-- hold; parental_consent_mark_sent does once the email is out.
drop function public.claim_consent_renewal_emails(int);

-- Reserves renewal emails for up to `batch_size` parents and returns them, oldest hold first:
--   [{"request_id", "send_id", "email", "first_name", "reminder", "held_version", "required_version", "summary",
--     "agreed_at"}]
-- For each: email, then parental_consent_mark_sent with the same wording; or parental_consent_release_send if it
-- didn't go out (the parent is claimed again on the next run while the round is open). Only the 200-an-hour overall
-- cap applies; the per-parent and per-household limits are for sends a parent asks for. An older open request from the
-- same parent is cancelled: the new link replaces it.
create function public.claim_consent_renewal_emails(batch_size int, wording text)
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
  what_changed text;
  claimed jsonb := '[]'::jsonb;
begin
  if not public.parental_wording_ok(wording) then
    raise exception 'wording % isn''t the one in force', wording using errcode = '22023';
  end if;
  select v.summary into what_changed from public.agreement_versions v where v.version = wording;
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
        'required_version', hold.required_version, 'summary', what_changed, 'agreed_at', agreed));
    end loop;
  end loop;
  return claimed;
end;
$$;

revoke execute on function public.claim_consent_renewal_emails(int, text) from public, anon, authenticated;
grant execute on function public.claim_consent_renewal_emails(int, text) to service_role;

-- From 20261116000000_email_plus_consent.sql (not redefined since), plus the request's reason in send_confirmation.
create or replace function public.parental_consent_decide(p_token_hash text, p_decision text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
  ended text;
  address text;
begin
  if p_decision not in ('agree', 'refuse') then
    raise exception 'decision must be agree or refuse' using errcode = '22023';
  end if;
  select * into request from public.parental_consent_requests where token_hash = p_token_hash for update;
  if not found then return jsonb_build_object('outcome', 'invalid'); end if;
  ended := public.parental_consent_settled(request);
  if ended is not null then
    if request.status in ('pending', 'consented') then
      perform public.end_parental_consent_request(request.id,
        case when ended = 'already_consented' then 'cancelled' else 'expired' end);
    end if;
    return jsonb_build_object('outcome', ended);
  end if;
  ended := public.parental_consent_still_valid(request);
  if ended is not null then return jsonb_build_object('outcome', ended); end if;

  -- Email 2 may be on its way right now; a no waits until it has settled.
  if request.confirm_reserved_at > now() - interval '5 minutes' then
    return jsonb_build_object('outcome', 'busy');
  end if;

  if p_decision = 'refuse' then
    update public.parental_consent_requests set decided_at = now() where id = request.id;
    perform public.end_parental_consent_request(request.id, 'refused');
    return jsonb_build_object('outcome', 'refused');
  end if;

  address := case when request.email_source = 'typed' then request.typed_email
                  else public.verified_account_email(request.requested_by) end;
  if address is null or public.consent_email_hash(address) is distinct from request.email_hash then
    perform public.end_parental_consent_request(request.id, 'cancelled');
    return jsonb_build_object('outcome', 'expired');
  end if;
  update public.parental_consent_requests
     set status = 'consented', decided_at = coalesce(decided_at, now()), confirm_reserved_at = now()
   where id = request.id
  returning * into request;
  return jsonb_build_object(
    'outcome', 'send_confirmation', 'request_id', request.id, 'decided_at', request.decided_at,
    'first_name', (select first_name from public.members where id = request.member_id),
    'email', address, 'reason', request.reason);
end;
$$;
