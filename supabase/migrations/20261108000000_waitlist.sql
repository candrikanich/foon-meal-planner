-- Founding-family waitlist (#34). Adults only: an email and an optional first name, kept until the person unsubscribes.
-- Only the `waitlist` Edge Function (service role) touches these tables; the site never reads or writes them directly,
-- so there is no client grant and no policy. RLS is on as a second lock.
-- * Double opt-in: a signup is `pending` until its emailed link is opened. Only the SHA-256 of the token is stored.
-- * A pending signup older than 30 days is deleted, and so is an attempt record after a day (daily cron).
-- * Rate limits: 5 attempts per hour from one address (kept as a salted hash, never the address), and a signup's email
--   goes out at most once every 10 minutes. The answer never says whether the email was already here.

create extension if not exists citext with schema extensions;

create table public.waitlist_signups (
  id uuid primary key default gen_random_uuid(),
  email extensions.citext not null unique check (length(email) between 3 and 254),
  first_name text check (first_name is null or length(first_name) between 1 and 60),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'unsubscribed')),
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
  attempted_at timestamptz not null default now()
);
create index waitlist_attempts_ip_idx on public.waitlist_attempts (ip_hash, attempted_at);
alter table public.waitlist_attempts enable row level security;
revoke all on table public.waitlist_attempts from public, anon, authenticated;

-- Records an attempt and says what the function should do: 'rate_limited', 'send' (email the new token) or 'skip'
-- (already confirmed, or emailed moments ago: say nothing different to the person).
create function public.waitlist_join(p_email text, p_first_name text, p_token_hash text, p_ip_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  existing public.waitlist_signups;
begin
  if (select count(*) from public.waitlist_attempts
      where ip_hash = p_ip_hash and attempted_at > now() - interval '1 hour') >= 5 then
    return 'rate_limited';
  end if;
  insert into public.waitlist_attempts (ip_hash) values (p_ip_hash);

  select * into existing from public.waitlist_signups where email = p_email::extensions.citext for update;
  if not found then
    insert into public.waitlist_signups (email, first_name, token_hash, token_sent_at)
    values (p_email, nullif(trim(p_first_name), ''), p_token_hash, now());
    return 'send';
  end if;
  if existing.status = 'confirmed' or existing.token_sent_at > now() - interval '10 minutes' then
    return 'skip';
  end if;
  -- Pending, or came back after unsubscribing: a fresh link, and it has to be confirmed again.
  update public.waitlist_signups
     set status = 'pending', token_hash = p_token_hash, token_sent_at = now(), confirmed_at = null,
         first_name = coalesce(nullif(trim(p_first_name), ''), first_name)
   where id = existing.id;
  return 'send';
end;
$$;

-- 'confirmed' (also when the link is opened twice), 'expired' (older than 7 days) or 'invalid'.
create function public.waitlist_confirm(p_token_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  found_row public.waitlist_signups;
begin
  select * into found_row from public.waitlist_signups where token_hash = p_token_hash for update;
  if not found or found_row.status = 'unsubscribed' then return 'invalid'; end if;
  if found_row.status = 'confirmed' then return 'confirmed'; end if;
  if found_row.token_sent_at < now() - interval '7 days' then return 'expired'; end if;
  update public.waitlist_signups set status = 'confirmed', confirmed_at = now() where id = found_row.id;
  return 'confirmed';
end;
$$;

-- Unsubscribing keeps the row (so a later signup starts from pending, never a silent re-add) but drops the name and token.
create function public.waitlist_unsubscribe(p_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  update public.waitlist_signups
     set status = 'unsubscribed', first_name = null, token_hash = null, confirmed_at = null
   where id = p_id;
  return found;
end;
$$;

-- The unsubscribe link carries an HMAC of this id, so the function needs the id of an email it is about to send to.
create function public.waitlist_id_for(p_email text)
returns uuid
language sql security definer set search_path = ''
as $$ select id from public.waitlist_signups where email = p_email::extensions.citext $$;

create function public.prune_waitlist()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.waitlist_signups where status = 'pending' and created_at < now() - interval '30 days';
  delete from public.waitlist_attempts where attempted_at < now() - interval '1 day';
$$;

revoke execute on function public.waitlist_join(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.waitlist_confirm(text) from public, anon, authenticated;
revoke execute on function public.waitlist_unsubscribe(uuid) from public, anon, authenticated;
revoke execute on function public.waitlist_id_for(text) from public, anon, authenticated;
revoke execute on function public.prune_waitlist() from public, anon, authenticated;
grant execute on function public.waitlist_join(text, text, text, text) to service_role;
grant execute on function public.waitlist_confirm(text) to service_role;
grant execute on function public.waitlist_unsubscribe(uuid) to service_role;
grant execute on function public.waitlist_id_for(text) to service_role;
grant execute on function public.prune_waitlist() to service_role;

select cron.schedule('prune-waitlist', '17 4 * * *', 'select public.prune_waitlist()');
