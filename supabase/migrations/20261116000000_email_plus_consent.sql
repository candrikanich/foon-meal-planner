-- Verifiable parental consent by COPPA "email plus" (#275, 16 CFR 312.5(b)(2)(viii)). Plan:
-- planning/m4-275-email-plus-plan.md; decisions by Chris, 2026-11-08.
--
-- A parent's consent for a kid is no longer written by the app. The parental-consent Edge Function emails the direct
-- notice (email 1) to the address on the parent's own sign-in, or to one they typed when their account has none. The
-- parent opens the link and taps I agree on getfoon.com; Foon then sends the confirming email (email 2, with a link to
-- withdraw), and only once that has gone out does the consents row exist. create_invite, redeem_invite and the
-- retention jobs already gate on that row, so none of them change.
--
-- * consents gains method (in_app | email_plus), confirmed_at (when email 2 went out; granted_at is when the parent
--   tapped I agree) and request_id. Existing rows are in_app and nothing is revoked: no carry-over is assumed, and #277
--   holds them later.
-- * Parental rows are inserted only by activate_parental_consent (service role). A guardian still inserts allergy
--   consent and still withdraws either kind in the app.
-- * parental_consent_requests: one row per emailed request. Only token hashes are stored. A typed email is kept only on
--   the row, and is cleared once email 2 goes out or the request ends (refused, cancelled, expired, purged).
-- * The account's email is used only when the account signs in with Apple, which vouches for it (Foon is Sign in with
--   Apple only, and email_confirmed_at proves nothing while sign-ups autoconfirm). Otherwise the parent is asked to
--   type one: that's their own claim, and the notice sent there is what confirms it. Email 2 goes only to the address
--   email 1 went to (compared by hash).
-- * Rate limits: one email 1 per request every 10 minutes, 5 a day per parent, 10 a day per household, 200 an hour
--   overall. The overall cap is a cost and abuse ceiling like the waitlist's: it means a flood of parents could delay
--   others by up to an hour, which we accept. A send is reserved under a lock before it starts; a failed one is
--   released. A reservation nobody settled keeps counting toward the daily and hourly limits (only release_send
--   clears it), so calling the RPC directly and never sending can't hold the pool; only the per-request "sending
--   now" check lapses after 5 minutes.
-- * Retention: a daily job marks requests whose link lapsed (7 days) as expired, and deletes a request 30 days after it
--   ended, which also ends its withdraw link. A kid's requests go with the kid (delete_kid) and the household
--   (erase_household), by cascade.

create type public.consent_method as enum ('in_app', 'email_plus');

alter table public.consents
  add column method public.consent_method not null default 'in_app',
  add column confirmed_at timestamptz,
  -- No foreign key: the consent record outlives the request, which is purged 30 days after it ends.
  add column request_id uuid;

-- From now on only allergy consent is inserted by a guardian; parental consent comes from activate_parental_consent.
drop policy "guardians give consent" on public.consents;
create policy "guardians give allergy consent" on public.consents
  for insert to authenticated
  with check (
    granted_by = (select auth.uid())
    and public.is_household_manager(household_id)
    and kind = 'allergy_data'
  );

create table public.parental_consent_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  member_id uuid not null,
  -- No foreign key, like consents.granted_by: the record outlives the account that asked.
  requested_by uuid not null,
  -- pending: email 1 is out (or being sent, while token_sent_at is null). consented: the parent tapped I agree and
  -- email 2 hasn't gone out yet. confirmed: email 2 went out and the consents row exists. The rest have ended.
  status text not null default 'pending'
    check (status in ('pending', 'consented', 'confirmed', 'refused', 'cancelled', 'expired')),
  -- Where email 1 went: the address on the parent's sign-in, or one they typed because it had none.
  email_source text not null check (email_source in ('account', 'typed')),
  typed_email text check (typed_email is null or char_length(typed_email) between 3 and 254),
  -- SHA-256 of the address email 1 went to (pending_: of the send in flight), so email 2 goes only to that same address
  -- without keeping a copy of an account's email. Cleared when the request ends.
  email_hash text,
  pending_email_hash text,
  -- Where a Send again is going, until it's out: a failed resend leaves the live link's address as it was.
  pending_email_source text check (pending_email_source in ('account', 'typed')),
  pending_typed_email text check (pending_typed_email is null or char_length(pending_typed_email) between 3 and 254),
  -- The wording emailed; set with the token when email 1 goes out.
  text_version text check (text_version is null or char_length(btrim(text_version)) between 1 and 40),
  token_hash text unique,
  token_sent_at timestamptz,
  expires_at timestamptz,
  send_reserved_at timestamptz,
  decided_at timestamptz,
  confirm_reserved_at timestamptz,
  confirmed_at timestamptz,
  withdraw_token_hash text unique,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (member_id, household_id) references public.members (id, household_id) on delete cascade,
  constraint parental_consent_requests_typed_email check ((email_source = 'typed') or typed_email is null),
  constraint parental_consent_requests_ended check ((status in ('pending', 'consented')) = (ended_at is null))
);
create index parental_consent_requests_member_idx on public.parental_consent_requests (member_id, created_at);
create index parental_consent_requests_ended_idx on public.parental_consent_requests (ended_at)
  where ended_at is not null;

alter table public.parental_consent_requests enable row level security;
revoke all on table public.parental_consent_requests from public, anon, authenticated;
-- Never the token hashes, the typed address or the send bookkeeping.
grant select (id, household_id, member_id, requested_by, status, email_source, text_version, token_sent_at, expires_at,
              decided_at, confirmed_at, ended_at, created_at)
  on public.parental_consent_requests to authenticated;

create policy "parents read their kids' consent requests" on public.parental_consent_requests
  for select to authenticated
  using (public.is_household_manager(household_id));

-- Email 1 sends, for the per-parent, per-household and overall limits. Who asked and for which household are stored on
-- the send itself, so deleting a request or the kid doesn't reset a count; rows go after a day, or with the household.
create table public.parental_consent_sends (
  id bigint generated always as identity primary key,
  request_id uuid references public.parental_consent_requests (id) on delete set null,
  household_id uuid not null references public.households (id) on delete cascade,
  requested_by uuid not null,
  created_at timestamptz not null default now(),
  -- Cleared only by release_send, when the send failed. Counted toward every limit while set.
  reserved_at timestamptz,
  sent boolean not null default false
);
create index parental_consent_sends_by_idx on public.parental_consent_sends (requested_by, reserved_at);
create index parental_consent_sends_household_idx on public.parental_consent_sends (household_id, reserved_at);
alter table public.parental_consent_sends enable row level security;
revoke all on table public.parental_consent_sends from public, anon, authenticated;

-- Whether this account is still a parent (guardian or owner) in the household. For the service-role functions, which
-- have no auth.uid().
create function public.is_parent_in(target_household uuid, account uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members
    where household_id = target_household and user_id = account and guardian and status <> 'removed'
  ) or exists (
    select 1 from public.households where id = target_household and owner = account
  );
$$;
revoke execute on function public.is_parent_in(uuid, uuid) from public, anon, authenticated;

-- Ends a request: clears the typed address and anything still reserved.
create function public.end_parental_consent_request(target uuid, final_status text)
returns void
language sql security definer set search_path = ''
as $$
  update public.parental_consent_requests
     set status = final_status, ended_at = now(), typed_email = null, email_hash = null, pending_email_hash = null,
         pending_email_source = null, pending_typed_email = null, send_reserved_at = null, confirm_reserved_at = null
   where id = target and status in ('pending', 'consented');
$$;
revoke execute on function public.end_parental_consent_request(uuid, text) from public, anon, authenticated;

-- The email Apple gave for the account's Sign in with Apple identity, which Apple vouches for. Not auth.users.email: a
-- signed-in user can change that through Auth while the Apple identity stays, and email_confirmed_at proves nothing
-- while sign-ups autoconfirm. An identity that says its email isn't verified doesn't count. Null otherwise, so an
-- address nobody vouched for is never emailed a notice in someone's name.
create function public.verified_account_email(account uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select nullif(btrim(i.identity_data ->> 'email'), '') from auth.identities i
   where i.user_id = account and i.provider = 'apple'
     and nullif(btrim(i.identity_data ->> 'email'), '') is not null
     and coalesce(lower(i.identity_data ->> 'email_verified'), 'true') in ('true', 't', '1')
   order by i.updated_at desc nulls last, i.created_at desc nulls last
   limit 1;
$$;
revoke execute on function public.verified_account_email(uuid) from public, anon, authenticated;

create function public.consent_email_hash(address text)
returns text
language sql immutable set search_path = ''
as $$ select encode(extensions.digest(lower(btrim(address)), 'sha256'), 'hex') $$;
revoke execute on function public.consent_email_hash(text) from public, anon, authenticated;

-- Called by the Edge Function with the parent's JWT, so auth.uid() and the session check apply. Reserves an email 1
-- send and says what the function should do:
--   {"outcome": "already_consented"}
--   {"outcome": "no_email"}       the account has no verified email and none was typed
--   {"outcome": "rate_limited"}
--   {"outcome": "send", "request_id", "send_id", "email", "email_source", "first_name"}
--     email, then parental_consent_mark_sent; or parental_consent_release_send if it didn't go out
-- A typed email is used only when the account has no verified one. Raises 28000 without a signed-in, active session,
-- 42501 for someone who isn't a parent in the kid's
-- household (or no such profile), 22023 for a profile that isn't an unclaimed kid's, and 22000 for a typed email that
-- isn't one.
create function public.request_parental_consent(target_member uuid, email_address text default null)
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
begin
  if caller is null or not public.session_is_active() then
    -- Its own code, so the Edge Function answers 401 (sign in again), not 403.
    raise exception 'sign in first' using errcode = '28000';
  end if;

  select * into kid from public.members where id = target_member;
  if not found or not public.is_household_manager(kid.household_id) then
    raise exception 'only parents in this household ask for consent' using errcode = '42501';
  end if;
  if kid.age_group <> 'kid' or kid.user_id is not null or kid.status = 'removed' then
    raise exception 'only an unclaimed kid''s profile needs consent' using errcode = '22023';
  end if;
  if public.has_parental_consent(kid.id) then
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

  if open_request.id is null then
    insert into public.parental_consent_requests (household_id, member_id, requested_by, email_source, typed_email,
                                                  pending_email_hash, send_reserved_at)
    values (kid.household_id, kid.id, caller, source,
            case when source = 'typed' then address end, public.consent_email_hash(address), now())
    returning * into open_request;
  else
    update public.parental_consent_requests
       set send_reserved_at = now(), pending_email_source = source,
           pending_typed_email = case when source = 'typed' then address end,
           pending_email_hash = public.consent_email_hash(address)
     where id = open_request.id;
  end if;
  insert into public.parental_consent_sends (request_id, household_id, requested_by, reserved_at)
  values (open_request.id, kid.household_id, caller, now())
  returning id into send_id;

  return jsonb_build_object('outcome', 'send', 'request_id', open_request.id, 'send_id', send_id,
                            'email', address, 'email_source', source, 'first_name', kid.first_name);
end;
$$;

-- Email 1 went out: its token is the one that works (an earlier link stops working), for 7 days, with the address it
-- went to. Any other parent's pending request for the kid is cancelled, so only one link is live; one already agreed
-- (consented) is left to finish. False when the request wasn't pending any more, so the token went nowhere.
create function public.parental_consent_mark_sent(p_request_id uuid, p_send_id bigint, p_token_hash text,
                                                  p_text_version text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
  other uuid;
  kid uuid;
begin
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
  for other in select id from public.parental_consent_requests
                where member_id = request.member_id and id <> request.id and status = 'pending'
                for update loop
    perform public.end_parental_consent_request(other, 'cancelled');
  end loop;
  return true;
end;
$$;

-- Email 1 didn't go out (Resend failed, or email is off): give the reservation back so a retry sends. A request that
-- never sent anything is deleted, typed address and all.
create function public.parental_consent_release_send(p_request_id uuid, p_send_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.parental_consent_sends set reserved_at = null where id = p_send_id and not sent;
  delete from public.parental_consent_requests where id = p_request_id and token_sent_at is null;
  update public.parental_consent_requests
     set send_reserved_at = null, pending_email_hash = null, pending_email_source = null, pending_typed_email = null
   where id = p_request_id;
end;
$$;

-- Checks a request can still lead to consent; ends it if not. Returns null when it can, else the outcome to report.
create function public.parental_consent_still_valid(request public.parental_consent_requests)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  kid public.members;
begin
  if public.has_parental_consent(request.member_id) then
    perform public.end_parental_consent_request(request.id, 'cancelled');
    return 'already_consented';
  end if;
  if request.expires_at is null or request.expires_at < now() then
    perform public.end_parental_consent_request(request.id, 'expired');
    return 'expired';
  end if;
  select * into kid from public.members where id = request.member_id;
  if kid.age_group <> 'kid' or kid.user_id is not null or kid.status = 'removed'
     or not public.is_parent_in(request.household_id, request.requested_by) then
    perform public.end_parental_consent_request(request.id, 'cancelled');
    return 'expired';
  end if;
  return null;
end;
$$;
revoke execute on function public.parental_consent_still_valid(public.parental_consent_requests)
  from public, anon, authenticated;

-- What a consent link's request has come to, or null while it's still open for an answer. Read only.
--   confirmed: this request's consent is active. withdrawn: it was, and has been withdrawn. refused.
--   already_consented: another parent (or an earlier consent) already consented for the kid; this request goes no
--   further. expired: lapsed or cancelled.
create function public.parental_consent_settled(request public.parental_consent_requests)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when request.status = 'confirmed' then
      case when exists (select 1 from public.consents c where c.request_id = request.id and c.revoked_at is null)
           then 'confirmed' else 'withdrawn' end
    when request.status = 'refused' then 'refused'
    when public.has_parental_consent(request.member_id) then 'already_consented'
    when request.status in ('cancelled', 'expired') or request.expires_at < now() then 'expired'
  end;
$$;
revoke execute on function public.parental_consent_settled(public.parental_consent_requests)
  from public, anon, authenticated;

-- What the site's /consent page shows, without changing anything (only parental_consent_decide does):
--   {"outcome": "pending", "first_name", "expires_at"}
--   | {"outcome": "confirmed" | "withdrawn" | "refused" | "already_consented" | "expired" | "invalid"}
create function public.parental_consent_lookup(p_token_hash text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
begin
  select * into request from public.parental_consent_requests where token_hash = p_token_hash;
  if not found then return jsonb_build_object('outcome', 'invalid'); end if;
  if public.parental_consent_settled(request) is not null then
    return jsonb_build_object('outcome', public.parental_consent_settled(request));
  end if;
  return jsonb_build_object('outcome', 'pending', 'expires_at', request.expires_at,
                            'first_name', (select first_name from public.members where id = request.member_id));
end;
$$;

-- The parent's answer, from the site's button. p_decision is 'agree' or 'refuse'.
--   {"outcome": "refused" | "confirmed" | "withdrawn" | "already_consented" | "expired" | "invalid" | "busy"}
--   {"outcome": "send_confirmation", "request_id", "email", "first_name", "decided_at"}
--     agreed: send email 2, then activate_parental_consent; or parental_consent_release_confirmation if it didn't go out
-- Email 2 goes to the address email 1 went to, derived the same way and checked against its hash: if the account's
-- email changed (or stopped being verified) in between, the request is cancelled and the parent asks again.
-- confirmed covers a consent that already exists (this request's, or another parent's). busy: email 2 is being sent
-- right now (for agree or refuse).
create function public.parental_consent_decide(p_token_hash text, p_decision text)
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
    'email', address);
end;
$$;

-- Email 2 didn't go out: the parent's agreement stands (status stays consented) and tapping I agree again resends.
create function public.parental_consent_release_confirmation(p_request_id uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.parental_consent_requests set confirm_reserved_at = null
   where id = p_request_id and status = 'consented';
$$;

-- Email 2 went out: consent is active. Checks everything again first (the kid is still an unclaimed kid in the family,
-- the parent who asked is still a parent there), and cancels the request if not.
--   'confirmed' | 'already_consented' (another consent got there first) | 'expired' (the request ended, or can't lead
--   to consent any more). Email 2 has gone out by now either way: a known limit, since the checks run again here for
--   whatever changed while it was sending (docs/parental-consent.md).
create function public.activate_parental_consent(p_request_id uuid, p_withdraw_token_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
  ended text;
  other uuid;
  kid uuid;
begin
  -- One activation per kid at a time, so two parents' activations serialize instead of deadlocking.
  select member_id into kid from public.parental_consent_requests where id = p_request_id;
  if kid is null then return 'expired'; end if;
  perform pg_advisory_xact_lock(hashtextextended('parental_consent:' || kid::text, 0));
  select * into request from public.parental_consent_requests where id = p_request_id for update;
  if not found or request.status <> 'consented' then
    return case when request.status = 'confirmed' then 'confirmed' else 'expired' end;
  end if;
  -- The link may lapse while email 2 is on its way; the parent agreed in time.
  if request.expires_at < now() then
    update public.parental_consent_requests set expires_at = now() + interval '1 minute' where id = request.id
    returning * into request;
  end if;
  ended := public.parental_consent_still_valid(request);
  if ended is not null then return ended; end if;

  insert into public.consents (household_id, member_id, kind, granted_by, granted_at, text_version, method,
                               confirmed_at, request_id)
  values (request.household_id, request.member_id, 'parental', request.requested_by, request.decided_at,
          request.text_version, 'email_plus', now(), request.id)
  on conflict do nothing;
  update public.parental_consent_requests
     set status = 'confirmed', confirmed_at = now(), ended_at = now(), withdraw_token_hash = p_withdraw_token_hash,
         typed_email = null, email_hash = null, pending_email_hash = null, pending_email_source = null,
         pending_typed_email = null, confirm_reserved_at = null, send_reserved_at = null
   where id = request.id;
  for other in select id from public.parental_consent_requests
                where member_id = request.member_id and id <> request.id and status in ('pending', 'consented')
                for update loop
    perform public.end_parental_consent_request(other, 'cancelled');
  end loop;
  return 'confirmed';
end;
$$;

-- The withdraw link from email 2 works for 30 days; withdrawing in the app always works.
--   {"outcome": "active", "first_name"} | {"outcome": "withdrawn" | "expired" | "invalid"}
create function public.parental_consent_withdraw_lookup(p_token_hash text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
begin
  select * into request from public.parental_consent_requests
   where withdraw_token_hash = p_token_hash and status = 'confirmed';
  if not found then return jsonb_build_object('outcome', 'invalid'); end if;
  if request.confirmed_at < now() - interval '30 days' then return jsonb_build_object('outcome', 'expired'); end if;
  if not exists (select 1 from public.consents where request_id = request.id and revoked_at is null) then
    return jsonb_build_object('outcome', 'withdrawn');
  end if;
  return jsonb_build_object('outcome', 'active',
                            'first_name', (select first_name from public.members where id = request.member_id));
end;
$$;

-- Withdraws the consent this request gave. consents_unlink_on_parental_revoke then unlinks the kid and cancels invites,
-- as when a parent withdraws in the app. 'withdrawn' (also when it already was) | 'expired' | 'invalid'
create function public.withdraw_parental_consent(p_token_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
begin
  select * into request from public.parental_consent_requests
   where withdraw_token_hash = p_token_hash and status = 'confirmed';
  if not found then return 'invalid'; end if;
  if request.confirmed_at < now() - interval '30 days' then return 'expired'; end if;
  update public.consents set revoked_at = now() where request_id = request.id and revoked_at is null;
  return 'withdrawn';
end;
$$;

-- Daily: a lapsed link ends its request, a reservation that never sent is dropped, an ended request goes after 30 days,
-- and send bookkeeping after a day.
create function public.purge_parental_consent_requests()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  lapsed uuid;
begin
  for lapsed in select id from public.parental_consent_requests
                 where status in ('pending', 'consented') and expires_at < now() loop
    perform public.end_parental_consent_request(lapsed, 'expired');
  end loop;
  delete from public.parental_consent_requests
   where token_sent_at is null and status = 'pending' and created_at < now() - interval '1 hour';
  delete from public.parental_consent_requests where ended_at < now() - interval '30 days';
  delete from public.parental_consent_sends where created_at < now() - interval '1 day';
end;
$$;

revoke execute on function public.request_parental_consent(uuid, text) from public, anon;
grant execute on function public.request_parental_consent(uuid, text) to authenticated;
revoke execute on function public.parental_consent_mark_sent(uuid, bigint, text, text) from public, anon, authenticated;
revoke execute on function public.parental_consent_release_send(uuid, bigint) from public, anon, authenticated;
revoke execute on function public.parental_consent_lookup(text) from public, anon, authenticated;
revoke execute on function public.parental_consent_decide(text, text) from public, anon, authenticated;
revoke execute on function public.parental_consent_release_confirmation(uuid) from public, anon, authenticated;
revoke execute on function public.activate_parental_consent(uuid, text) from public, anon, authenticated;
revoke execute on function public.parental_consent_withdraw_lookup(text) from public, anon, authenticated;
revoke execute on function public.withdraw_parental_consent(text) from public, anon, authenticated;
revoke execute on function public.purge_parental_consent_requests() from public, anon, authenticated;
grant execute on function public.parental_consent_mark_sent(uuid, bigint, text, text) to service_role;
grant execute on function public.parental_consent_release_send(uuid, bigint) to service_role;
grant execute on function public.parental_consent_lookup(text) to service_role;
grant execute on function public.parental_consent_decide(text, text) to service_role;
grant execute on function public.parental_consent_release_confirmation(uuid) to service_role;
grant execute on function public.activate_parental_consent(uuid, text) to service_role;
grant execute on function public.parental_consent_withdraw_lookup(text) to service_role;
grant execute on function public.withdraw_parental_consent(text) to service_role;
grant execute on function public.purge_parental_consent_requests() to service_role;

select cron.schedule('purge-parental-consent-requests', '23 4 * * *',
                     'select public.purge_parental_consent_requests()');

-- The latest definition (20261111000000_guardian_review.sql), plus parental_consent_requests: status and times only,
-- the columns a parent can read (a planner who isn't a parent gets none).
create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not (public.is_household_planner(target_household) or public.is_household_manager(target_household)) then
    raise exception 'only planners and parents export the household' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'household', (select to_jsonb(h) - 'owner' from public.households h where id = target_household),
    'members', (select coalesce(jsonb_agg(to_jsonb(m) - 'user_id' - 'household_id' order by m.created_at), '[]')
                from public.members m where household_id = target_household),
    'allergies', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                  from public.member_allergies a where household_id = target_household),
    'consents', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' - 'granted_by' order by c.granted_at), '[]')
                 from public.consents c where household_id = target_household),
    'consent_agreements', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id' - 'agreed_by' order by a.agreed_at), '[]')
                           from public.consent_agreements a where household_id = target_household),
    'parental_consent_requests', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]')
      from (select id, member_id, status, email_source, text_version, token_sent_at, expires_at, decided_at,
                   confirmed_at, ended_at, created_at
            from public.parental_consent_requests where household_id = target_household) r),
    'meals', (select coalesce(jsonb_agg(to_jsonb(m) - 'household_id' order by m.name), '[]')
              from public.meals m where household_id = target_household),
    'meal_ingredients', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id'), '[]')
                         from public.meal_ingredients i where household_id = target_household),
    'meal_sides', (select coalesce(jsonb_agg(to_jsonb(s) - 'household_id'), '[]')
                   from public.meal_sides s where household_id = target_household),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) - 'household_id' order by i.canonical_name), '[]')
              from public.items i where household_id = target_household),
    'traditions', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id'), '[]')
                   from public.traditions t where household_id = target_household),
    'plans', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.week_start), '[]')
              from public.plans p where household_id = target_household),
    'nights', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.date), '[]')
               from public.plan_nights n where household_id = target_household),
    'attendance', (select coalesce(jsonb_agg(to_jsonb(a) - 'household_id'), '[]')
                   from public.night_attendance a where household_id = target_household),
    'list_items', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id'), '[]')
                   from public.list_items l where household_id = target_household),
    'meal_logs', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                  from public.meal_logs l where household_id = target_household),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                  from public.reactions r where household_id = target_household),
    'hidden_comments', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.hidden_at), '[]')
                        from public.hidden_comments c where household_id = target_household),
    'chef_thanks', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                    from public.chef_thanks t where household_id = target_household),
    'serving_notes', (select coalesce(jsonb_agg(to_jsonb(n) - 'household_id' order by n.created_at), '[]')
                      from public.serving_notes n where household_id = target_household),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.created_at), '[]')
                 from public.requests r where household_id = target_household),
    'request_plus_ones', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
                          from public.request_plus_ones p where household_id = target_household),
    'attendance_templates', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.created_at), '[]')
                             from public.attendance_templates t where household_id = target_household),
    'freezer_stash', (select coalesce(jsonb_agg(to_jsonb(f) - 'household_id' order by f.created_at), '[]')
                      from public.freezer_stash f where household_id = target_household),
    'night_claims', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.created_at), '[]')
                     from public.night_claims c where household_id = target_household),
    'plan_changes', (select coalesce(jsonb_agg(to_jsonb(c) - 'household_id' order by c.id), '[]')
                     from public.plan_changes c where household_id = target_household),
    'notification_log', (select coalesce(jsonb_agg(to_jsonb(l) - 'household_id' order by l.created_at), '[]')
                         from public.notification_log l where household_id = target_household),
    'polls', (select coalesce(jsonb_agg(to_jsonb(p) - 'household_id' order by p.created_at), '[]')
              from public.polls p where household_id = target_household),
    'poll_votes', (select coalesce(jsonb_agg(to_jsonb(v) - 'household_id' order by v.voted_at), '[]')
                   from public.poll_votes v where household_id = target_household),
    'receipt_aliases', (select coalesce(jsonb_agg(to_jsonb(r) - 'household_id' order by r.raw_text), '[]')
                        from public.receipt_aliases r where household_id = target_household),
    'ai_jobs', (select coalesce(jsonb_agg(to_jsonb(j) - 'household_id' order by j.created_at), '[]')
                from public.ai_jobs j where household_id = target_household)
  );
end;
$$;
