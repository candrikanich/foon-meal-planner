-- Founding-family waitlist (#34). Adults only: an email and an optional first name, kept until the person unsubscribes
-- (which deletes the row).
-- Only the `waitlist` Edge Function (service role) touches these tables; the site never reads or writes them directly,
-- so there is no client grant and no policy. RLS is on as a second lock.
-- * Double opt-in: a signup is `pending` until its emailed link is confirmed. Only the SHA-256 of the token is stored,
--   and only once the email has really gone out (waitlist_mark_sent).
-- * A pending signup is deleted 30 days after its last email (or its creation, if none went out); an attempt record is
--   deleted after a day. Both by a daily cron, so an address's hash can be on file for up to about 2 days.
-- * Rate limits: 5 attempts per hour from one address (kept as a keyed hash, never the address), 200 emails sent an hour
--   overall, and a signup's email goes out at most once every 10 minutes. Both overall figures count real sends only.
--   The answer never says whether the email was already here.

create extension if not exists citext with schema extensions;

create table public.waitlist_signups (
  id uuid primary key default gen_random_uuid(),
  email extensions.citext not null unique check (length(email) between 3 and 254),
  first_name text check (first_name is null or length(first_name) between 1 and 60),
  status text not null default 'pending' check (status in ('pending', 'confirmed')),
  token_hash text,
  token_sent_at timestamptz,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz
);
alter table public.waitlist_signups enable row level security;
revoke all on table public.waitlist_signups from public, anon, authenticated;

create table public.waitlist_attempts (
  id bigint generated always as identity primary key,
  ip_hash text not null,
  attempted_at timestamptz not null default now(),
  -- True only once an email for this attempt has really been sent: the overall cap counts these, so failures and refused
  -- attempts from one address can't use it up for everyone else.
  sent boolean not null default false
);
create index waitlist_attempts_ip_idx on public.waitlist_attempts (ip_hash, attempted_at);
alter table public.waitlist_attempts enable row level security;
revoke all on table public.waitlist_attempts from public, anon, authenticated;

-- Records an attempt and says what the function should do:
--   {"outcome": "rate_limited"}
--   {"outcome": "skip"}   already confirmed, or emailed moments ago: the person is told nothing different
--   {"outcome": "send", "signup_id", "attempt_id"}   send the email, then call waitlist_mark_sent
create function public.waitlist_join(p_email text, p_first_name text, p_ip_hash text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  existing public.waitlist_signups;
  attempt_id bigint;
begin
  -- One join at a time, so two requests can't both count the same four attempts and each squeeze in a fifth. The attempt
  -- is recorded first and counted with the others: a refused attempt still counts toward its own address's 5 an hour.
  perform pg_advisory_xact_lock(hashtext('waitlist_join'));
  insert into public.waitlist_attempts (ip_hash) values (p_ip_hash) returning id into attempt_id;
  if (select count(*) from public.waitlist_attempts
      where ip_hash = p_ip_hash and attempted_at > now() - interval '1 hour') > 5
     or (select count(*) from public.waitlist_attempts where sent and attempted_at > now() - interval '1 hour') >= 200 then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  -- Qualified because search_path is empty: a bare = would quietly compare as text, and "Pat@" would not match "pat@".
  select * into existing from public.waitlist_signups where email operator(extensions.=) p_email::extensions.citext for update;
  if not found then
    insert into public.waitlist_signups (email, first_name) values (p_email, nullif(trim(p_first_name), ''))
    returning * into existing;
  elsif existing.status = 'confirmed' or existing.token_sent_at > now() - interval '10 minutes' then
    return jsonb_build_object('outcome', 'skip');
  end if;
  return jsonb_build_object('outcome', 'send', 'signup_id', existing.id, 'attempt_id', attempt_id);
end;
$$;

-- After the email went out: the token becomes the one that works, and the send counts toward the throttle and the cap.
create function public.waitlist_mark_sent(p_signup_id uuid, p_attempt_id bigint, p_token_hash text, p_first_name text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.waitlist_signups
     set token_hash = p_token_hash, token_sent_at = now(),
         first_name = coalesce(nullif(trim(p_first_name), ''), first_name)
   where id = p_signup_id and status = 'pending';
  update public.waitlist_attempts set sent = true where id = p_attempt_id;
end;
$$;

-- 'confirmed' (also when the link is used twice), 'expired' (older than 7 days) or 'invalid'.
create function public.waitlist_confirm(p_token_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  found_row public.waitlist_signups;
begin
  select * into found_row from public.waitlist_signups where token_hash = p_token_hash for update;
  if not found then return 'invalid'; end if;
  if found_row.status = 'confirmed' then return 'confirmed'; end if;
  if found_row.token_sent_at < now() - interval '7 days' then return 'expired'; end if;
  update public.waitlist_signups set status = 'confirmed', confirmed_at = now() where id = found_row.id;
  return 'confirmed';
end;
$$;

-- Unsubscribing deletes the row: the email and name are gone, and signing up again starts from pending.
create function public.waitlist_unsubscribe(p_id uuid)
returns void
language sql security definer set search_path = ''
as $$ delete from public.waitlist_signups where id = p_id $$;

create function public.prune_waitlist()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.waitlist_signups
   where status = 'pending' and coalesce(token_sent_at, created_at) < now() - interval '30 days';
  delete from public.waitlist_attempts where attempted_at < now() - interval '1 day';
$$;

revoke execute on function public.waitlist_join(text, text, text) from public, anon, authenticated;
revoke execute on function public.waitlist_mark_sent(uuid, bigint, text, text) from public, anon, authenticated;
revoke execute on function public.waitlist_confirm(text) from public, anon, authenticated;
revoke execute on function public.waitlist_unsubscribe(uuid) from public, anon, authenticated;
revoke execute on function public.prune_waitlist() from public, anon, authenticated;
grant execute on function public.waitlist_join(text, text, text) to service_role;
grant execute on function public.waitlist_mark_sent(uuid, bigint, text, text) to service_role;
grant execute on function public.waitlist_confirm(text) to service_role;
grant execute on function public.waitlist_unsubscribe(uuid) to service_role;
grant execute on function public.prune_waitlist() to service_role;

select cron.schedule('prune-waitlist', '17 4 * * *', 'select public.prune_waitlist()');
