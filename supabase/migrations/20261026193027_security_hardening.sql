-- Security hardening (#14).
-- 1. Signing out everywhere ends household access immediately. Supabase revokes refresh tokens,
--    but an access token stays valid until it expires (up to an hour). Every access token names
--    its session, so the RLS helpers now also require that session to still exist.
-- 2. An invite stops working once the parent who sent it no longer manages the household.

-- True when the caller's session is live. Tokens without a session claim (service role, database
-- tests) pass: only GoTrue can mint user tokens, and it always includes the session.
create function public.session_is_active()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select auth.jwt()) ->> 'session_id', '') = ''
      or exists (
        select 1 from auth.sessions
        where id = ((select auth.jwt()) ->> 'session_id')::uuid
          and (not_after is null or not_after > now())
      );
$$;

revoke execute on function public.session_is_active() from public, anon;
grant execute on function public.session_is_active() to authenticated;

create or replace function public.is_household_member(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.session_is_active() and exists (
    select 1 from public.members
    where household_id = target_household and user_id = (select auth.uid())
  );
$$;

create or replace function public.is_household_planner(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.session_is_active() and (
    exists (
      select 1 from public.members
      where household_id = target_household and user_id = (select auth.uid()) and role = 'planner'
    ) or exists (
      -- The owner manages the household before their own member row exists (onboarding).
      select 1 from public.households where id = target_household and owner = (select auth.uid())
    )
  );
$$;

create or replace function public.is_household_manager(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.session_is_active() and (
    exists (
      select 1 from public.members
      where household_id = target_household and user_id = (select auth.uid()) and guardian
    ) or exists (
      select 1 from public.households where id = target_household and owner = (select auth.uid())
    )
  );
$$;

-- The owner shortcut in the household read policy gets the same session check.
drop policy "members read their household" on public.households;
create policy "members read their household" on public.households
  for select to authenticated
  using (public.is_household_member(id) or (owner = (select auth.uid()) and public.session_is_active()));

-- The members self-edit branch checks auth.uid() directly, so it needs the session check too.
drop policy "guardians and planners edit members, members edit themselves" on public.members;
create policy "guardians and planners edit members, members edit themselves" on public.members
  for update to authenticated
  using (public.is_household_manager(household_id) or public.is_household_planner(household_id)
         or (user_id = (select auth.uid()) and public.session_is_active()))
  with check (public.is_household_manager(household_id) or public.is_household_planner(household_id)
              or (user_id = (select auth.uid()) and public.session_is_active()));

-- redeem_invite: refuses signed-out sessions, and treats an invite whose sender is no longer a
-- parent (or the owner) of the household as expired.
create or replace function public.redeem_invite(code text)
returns text
language plpgsql security definer set search_path = ''
as $$
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

  update public.members set user_id = caller where id = invite.member_id;
  update public.invites set redeemed_at = now(), redeemed_by = caller where id = invite.id;
  insert into public.invite_redeem_attempts (user_id, succeeded) values (caller, true);
  return 'claimed';
end;
$$;
