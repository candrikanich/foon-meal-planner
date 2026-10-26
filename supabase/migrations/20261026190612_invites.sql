-- Invites (#9): parents invite an unclaimed profile; the code links one account to it, once.
-- Codes are shown once and stored only as SHA-256 hashes. Redeeming is a SECURITY DEFINER
-- function (not an Edge Function): one transaction validates, rate-limits, and links.

create table public.invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  member_id uuid not null,
  -- SHA-256 of the code's 8 random characters; the household prefix is cosmetic.
  code_hash text not null unique,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  redeemed_at timestamptz,
  redeemed_by uuid,
  revoked_at timestamptz,
  foreign key (member_id, household_id) references public.members (id, household_id)
);

create unique index invites_one_open_per_member on public.invites (member_id)
  where redeemed_at is null and revoked_at is null;

create table public.invite_redeem_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null
);

create index invite_redeem_attempts_recent on public.invite_redeem_attempts (user_id, attempted_at);

revoke all on public.invites, public.invite_redeem_attempts from anon, authenticated;
-- No code_hash: 40-bit codes hashed without salt could be cracked offline.
grant select (id, household_id, member_id, created_by, created_at, expires_at, redeemed_at, redeemed_by, revoked_at)
  on public.invites to authenticated;

alter table public.invites enable row level security;
alter table public.invite_redeem_attempts enable row level security;

-- Parents see their household's invites (to show "Invite sent"); no plain codes are stored.
create policy "parents read invites" on public.invites
  for select to authenticated using (public.is_household_manager(household_id));

-- Unambiguous: no 0, O, 1, or I. 32 symbols, so each random byte maps without bias.
create function public.invite_code_alphabet()
returns text
language sql immutable set search_path = ''
as $$ select '23456789ABCDEFGHJKLMNPQRSTUVWXYZ' $$;

create function public.create_invite(target_member uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
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
$$;

-- Returns a status rather than raising, so failed attempts are recorded for the rate limit:
-- claimed | invalid | expired | used | has_household | rate_limited.
create function public.redeem_invite(code text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  normalized text := upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g'));
  invite public.invites;
  member public.members;
begin
  if caller is null then
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

revoke execute on function public.create_invite(uuid), public.redeem_invite(text), public.invite_code_alphabet()
  from public, anon;
grant execute on function public.create_invite(uuid), public.redeem_invite(text) to authenticated;

-- Member guard: privileged database functions (redeem_invite runs as its owner, not as
-- `authenticated`) may link user_id, as the service role already could. Any future SECURITY DEFINER
-- function that writes members skips these rules too, so it must enforce its own.
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

  if old.user_id = household_owner
     and (new.role, new.age_group, new.status, new.guardian)
         is distinct from (old.role, old.age_group, old.status, old.guardian) then
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
    if (new.first_name, new.role, new.age_group, new.status, new.away_until, new.guardian)
       is distinct from (old.first_name, old.role, old.age_group, old.status, old.away_until, old.guardian) then
      raise exception 'members can edit only their avatar, schedule, and notification settings'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- Removing a profile cancels its open invites, so a code already texted out can't link anyone
-- later, even if the profile is restored. SECURITY DEFINER: clients have no write access to invites.
create function public.members_revoke_invites_on_removal()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'removed' and old.status <> 'removed' then
    update public.invites set revoked_at = now()
    where member_id = new.id and redeemed_at is null and revoked_at is null;
  end if;
  return null;
end;
$$;

create trigger members_revoke_invites_on_removal
  after update of status on public.members
  for each row execute function public.members_revoke_invites_on_removal();
