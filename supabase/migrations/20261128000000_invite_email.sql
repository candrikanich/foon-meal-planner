-- Email an adult's invite (#48 PR B). A parent who can invite an adult's profile types the adult's address in the app;
-- the account-email Edge Function checks the request here (as the parent, with their JWT), then sends one email with
-- the link and the code. The address never reaches the database: this function never sees it, and nothing here stores
-- it. What's kept is the send itself (who sent it, for which household, when), for the rate limit, for a day.

-- One row per invite email about to go. Who sent it and the household are on the row, so the limits survive the invite
-- or the profile changing; rows go after a day (prune_invite_email_sends), or with the household (cascade).
create table public.invite_email_sends (
  id bigint generated always as identity primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  sent_by uuid not null,
  created_at timestamptz not null default now()
);
create index invite_email_sends_by_idx on public.invite_email_sends (sent_by, created_at);
create index invite_email_sends_household_idx on public.invite_email_sends (household_id, created_at);
create index invite_email_sends_created_idx on public.invite_email_sends (created_at);
-- The server's alone: no client policy, so no household can read another's, or its own.
alter table public.invite_email_sends enable row level security;
revoke all on table public.invite_email_sends from public, anon, authenticated;

-- Checks a request to email `code` for `target_member` and, when it can go, records the send and returns what the email
-- says. The code must be the member's open invite (its last 8 characters hash to the invite's code_hash), so the email
-- carries only a code this household made for this person, rebuilt here from those 8 characters. Raises 28000 (not
-- signed in) and 42501 (not a parent in that household, or no such profile: the same answer, as create_invite);
-- otherwise returns {outcome}: kid | not_invitable | email_off | wrong_code | rate_limited | send (with send_id, code,
-- first_name, inviter, household, expires_at, time_zone).
create function public.reserve_invite_email(target_member uuid, code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  normalized text := upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g'));
  member public.members;
  home public.households;
  invite public.invites;
  inviter text;
  prefix text;
  secret text;
  send_id bigint;
begin
  if caller is null then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  -- One at a time per parent, so a burst of parallel sends can't outrun the count.
  perform pg_advisory_xact_lock(hashtextextended('invite_email:' || caller::text, 0));

  select * into member from public.members where id = target_member;
  if not found or not public.is_household_manager(member.household_id) then
    raise exception 'only parents in this household can invite' using errcode = '42501';
  end if;
  -- Foon never emails kids. A kid's invite goes through a parent's consent and the share sheet.
  if member.age_group <> 'adult' then
    return jsonb_build_object('outcome', 'kid');
  end if;
  if member.user_id is not null or member.status = 'removed' then
    return jsonb_build_object('outcome', 'not_invitable');
  end if;
  if not coalesce((select c.account_email_enabled from public.app_config c), false) then
    return jsonb_build_object('outcome', 'email_off');
  end if;

  if length(normalized) >= 8 then
    secret := right(normalized, 8);
    select * into invite from public.invites i
    where i.member_id = target_member and i.code_hash = encode(extensions.digest(secret, 'sha256'), 'hex')
      and i.redeemed_at is null and i.revoked_at is null and i.expires_at > now();
  end if;
  if invite.id is null then
    return jsonb_build_object('outcome', 'wrong_code');
  end if;

  -- 5 a day for each parent, 10 a day for each household, 200 an hour across Foon (Resend's sending budget is shared
  -- with the account emails). Which limit is never said.
  if (select count(*) from public.invite_email_sends
      where sent_by = caller and created_at > now() - interval '1 day') >= 5
     or (select count(*) from public.invite_email_sends
         where household_id = member.household_id and created_at > now() - interval '1 day') >= 10
     or (select count(*) from public.invite_email_sends where created_at > now() - interval '1 hour') >= 200 then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  select * into home from public.households where id = member.household_id;
  select m.first_name into inviter from public.members m
  where m.household_id = member.household_id and m.user_id = caller and m.status <> 'removed';
  prefix := coalesce(nullif(left(regexp_replace(upper(home.name), '[^A-Z]', '', 'g'), 5), ''), 'FOON');

  insert into public.invite_email_sends (household_id, sent_by) values (member.household_id, caller)
  returning id into send_id;

  return jsonb_build_object(
    'outcome', 'send',
    'send_id', send_id,
    'code', prefix || '-' || left(secret, 4) || '-' || right(secret, 4),
    'first_name', member.first_name,
    'inviter', inviter,
    'household', home.name,
    'expires_at', invite.expires_at,
    'time_zone', home.settings ->> 'time_zone'
  );
end;
$$;
revoke execute on function public.reserve_invite_email(uuid, text) from public, anon;
grant execute on function public.reserve_invite_email(uuid, text) to authenticated;

create function public.prune_invite_email_sends()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.invite_email_sends where created_at < now() - interval '1 day';
$$;
revoke execute on function public.prune_invite_email_sends() from public, anon, authenticated;

select cron.schedule('prune-invite-email-sends', '59 4 * * *', 'select public.prune_invite_email_sends()');
