-- Forwarded email receipts (#237), the email half of #61. Each household has a private address,
-- r-<token>@in.getfoon.com. An adult forwards a store's receipt email there from an address they added and confirmed.
-- Resend receives it and calls the receipt-inbox Edge Function, which checks the mail and turns it into plain lines,
-- then hands them to record_forwarded_receipt. The app matches those lines on the phone with the same matcher and
-- review screen as a photo, and deleting the row is how a receipt is confirmed or dismissed. Rows nobody reviews go
-- after 14 days.
--
-- What's kept:
--   receipt_inboxes     the household's address token (adults read it; it lets mail in only from confirmed senders)
--   receipt_senders     an adult's forwarding address as a sha256 and a hint ("c•••@gmail.com"), never the address
--   forwarded_receipts  the receipt's lines, when it came, and Resend's id for it (no sender, subject or headers)
--   receipt_sender_emails  when each adult was sent a confirmation link, for a day (the send limit)

-- An adult in the household (their own profile, not removed) or its owner, on a live session. 20261026155022_guardians
-- dropped the first helper of this name; forwarding is for adults, not only parents, so it comes back.
create function public.is_household_adult(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.session_is_active() and (
    exists (
      select 1 from public.members
      where household_id = target_household and user_id = (select auth.uid()) and age_group = 'adult'
        and status <> 'removed'
    ) or exists (
      select 1 from public.households where id = target_household and owner = (select auth.uid())
    )
  );
$$;

revoke execute on function public.is_household_adult(uuid) from public, anon;
grant execute on function public.is_household_adult(uuid) to authenticated;

-- Inbox --------------------------------------------------------------------------------------------------------------

create table public.receipt_inboxes (
  household_id uuid primary key references public.households (id) on delete cascade,
  -- 16 hex characters (64 random bits): the address is r-<token>@in.getfoon.com.
  token text not null unique check (token ~ '^[0-9a-f]{16}$'),
  created_at timestamptz not null default now()
);

alter table public.receipt_inboxes enable row level security;
revoke all on table public.receipt_inboxes from public, anon, authenticated;
grant select on public.receipt_inboxes to authenticated;
create policy "adults read their receipt inbox" on public.receipt_inboxes
  for select to authenticated using (public.is_household_adult(household_id));

-- The household's address token, made the first time an adult asks for it. Raises 42501 for anyone else.
create function public.receipt_inbox_token(target_household uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  inbox_token text;
begin
  if not public.is_household_adult(target_household) then
    raise exception 'only adults in the household see its receipt address' using errcode = '42501';
  end if;
  insert into public.receipt_inboxes (household_id, token)
    values (target_household, encode(extensions.gen_random_bytes(8), 'hex'))
    on conflict (household_id) do nothing;
  select token into inbox_token from public.receipt_inboxes where household_id = target_household;
  return inbox_token;
end;
$$;

-- A new address for the household: the old one stops working at once (mail to it is dropped). Adults only.
create function public.reset_receipt_inbox(target_household uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  fresh text := encode(extensions.gen_random_bytes(8), 'hex');
begin
  if not public.is_household_adult(target_household) then
    raise exception 'only adults in the household change its receipt address' using errcode = '42501';
  end if;
  insert into public.receipt_inboxes (household_id, token) values (target_household, fresh)
    on conflict (household_id) do update set token = excluded.token, created_at = now();
  return fresh;
end;
$$;

revoke execute on function public.receipt_inbox_token(uuid) from public, anon;
revoke execute on function public.reset_receipt_inbox(uuid) from public, anon;
grant execute on function public.receipt_inbox_token(uuid) to authenticated;
grant execute on function public.reset_receipt_inbox(uuid) to authenticated;

-- Senders ------------------------------------------------------------------------------------------------------------

-- Addresses an adult forwards receipts from. Most people sign in with Apple's hidden email, so the address their store
-- receipts go to is one Foon doesn't know: they add it, and Foon emails it a link to confirm it's theirs. Only the
-- sha256 of the lowercased address is kept, to compare with mail that comes in, plus a hint for the app to show.
create table public.receipt_senders (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  -- The account that added it; it goes with the account.
  user_id uuid not null references auth.users (id) on delete cascade,
  address_hash text not null check (address_hash ~ '^[0-9a-f]{64}$'),
  address_hint text not null check (char_length(address_hint) between 3 and 80),
  -- The sha256 of the confirmation link's token while it waits; cleared once confirmed.
  confirm_token_hash text unique check (confirm_token_hash ~ '^[0-9a-f]{64}$'),
  confirm_expires_at timestamptz,
  -- Confirmation emails sent for this row, at most 5.
  emails_sent smallint not null default 0,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint receipt_senders_household_address_key unique (household_id, address_hash),
  constraint receipt_senders_confirmed_or_waiting
    check ((confirmed_at is null) = (confirm_token_hash is not null))
);
create index receipt_senders_member_idx on public.receipt_senders (member_id);
create index receipt_senders_user_idx on public.receipt_senders (user_id);

alter table public.receipt_senders enable row level security;
revoke all on table public.receipt_senders from public, anon, authenticated;
-- Never the hash or the token: only what the app shows.
grant select (id, household_id, member_id, address_hint, confirmed_at, created_at) on public.receipt_senders
  to authenticated;
grant delete on public.receipt_senders to authenticated;
create policy "adults see who forwards receipts" on public.receipt_senders
  for select to authenticated using (public.is_household_adult(household_id));
create policy "adults remove their own forwarding addresses" on public.receipt_senders
  for delete to authenticated using (user_id = (select auth.uid()) and public.session_is_active());

-- One row per confirmation email, kept a day. Deleting a waiting address and adding it again starts its own count
-- over, so this is what stops an adult using Foon to email any address over and over: 10 links a day each.
create table public.receipt_sender_emails (
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index receipt_sender_emails_by_idx on public.receipt_sender_emails (user_id, created_at);
alter table public.receipt_sender_emails enable row level security;
revoke all on table public.receipt_sender_emails from public, anon, authenticated;

-- Confirmation links sent to this account in the past day, whatever the address.
create function public.receipt_sender_emails_today(account uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int from public.receipt_sender_emails
    where user_id = account and created_at > now() - interval '1 day';
$$;

revoke execute on function public.receipt_sender_emails_today(uuid) from public, anon, authenticated;

-- Adds a forwarding address for the caller (as the adult, with their JWT, from the receipt-inbox function, which then
-- emails the link). The address itself never reaches the database: the function sends its sha256 and hint, and the
-- sha256 of a new link token. Raises 28000 (not signed in) and 42501 (not an adult in the household). Returns
-- {outcome}: send (with id), confirmed (already confirmed here), taken (another adult here added it), too_many (5
-- addresses each), rate_limited (5 emails for one address, or 10 a day for one adult).
create function public.add_receipt_sender(target_household uuid, address_hash text, address_hint text, token_hash text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
  me uuid;
  added uuid;
  existing public.receipt_senders;
begin
  if caller is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  if not public.session_is_active() then
    raise exception 'session ended' using errcode = '42501';
  end if;
  select id into me from public.members
    where household_id = target_household and user_id = caller and age_group = 'adult' and status <> 'removed';
  if me is null then
    raise exception 'only adults in the household add forwarding addresses' using errcode = '42501';
  end if;
  if address_hash !~ '^[0-9a-f]{64}$' or token_hash !~ '^[0-9a-f]{64}$'
     or address_hint is null or char_length(address_hint) not between 3 and 80 then
    raise exception 'bad forwarding address' using errcode = '22023';
  end if;

  select * into existing from public.receipt_senders s
    where s.household_id = target_household and s.address_hash = add_receipt_sender.address_hash
    for update;
  if found then
    if existing.confirmed_at is not null then
      return jsonb_build_object('outcome', 'confirmed');
    elsif existing.user_id <> caller then
      return jsonb_build_object('outcome', 'taken');
    elsif existing.emails_sent >= 5 or public.receipt_sender_emails_today(caller) >= 10 then
      return jsonb_build_object('outcome', 'rate_limited');
    end if;
    insert into public.receipt_sender_emails (user_id) values (caller);
    update public.receipt_senders
      set confirm_token_hash = token_hash, confirm_expires_at = now() + interval '1 day',
          emails_sent = emails_sent + 1, member_id = me
      where id = existing.id;
    return jsonb_build_object('outcome', 'send', 'id', existing.id);
  end if;

  if (select count(*) from public.receipt_senders where user_id = caller and household_id = target_household) >= 5 then
    return jsonb_build_object('outcome', 'too_many');
  end if;
  if public.receipt_sender_emails_today(caller) >= 10 then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;
  insert into public.receipt_sender_emails (user_id) values (caller);
  insert into public.receipt_senders
    (household_id, member_id, user_id, address_hash, address_hint, confirm_token_hash, confirm_expires_at, emails_sent)
    values (target_household, me, caller, add_receipt_sender.address_hash, add_receipt_sender.address_hint, token_hash,
            now() + interval '1 day', 1)
    returning id into added;
  return jsonb_build_object('outcome', 'send', 'id', added);
end;
$$;

revoke execute on function public.add_receipt_sender(uuid, text, text, text) from public, anon;
grant execute on function public.add_receipt_sender(uuid, text, text, text) to authenticated;

-- The confirmation link's button (getfoon.com → receipt-inbox, service role). Returns confirmed, expired or unknown.
-- A link works once, for a day: confirming clears the token, so a second click is unknown.
create function public.confirm_receipt_sender(token_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  waiting public.receipt_senders;
begin
  if token_hash is null or token_hash !~ '^[0-9a-f]{64}$' then
    return 'unknown';
  end if;
  select * into waiting from public.receipt_senders s
    where s.confirm_token_hash = confirm_receipt_sender.token_hash for update;
  if not found then
    return 'unknown';
  elsif waiting.confirm_expires_at < now() then
    return 'expired';
  end if;
  update public.receipt_senders
    set confirmed_at = now(), confirm_token_hash = null, confirm_expires_at = null
    where id = waiting.id;
  return 'confirmed';
end;
$$;

revoke execute on function public.confirm_receipt_sender(text) from public, anon, authenticated;
grant execute on function public.confirm_receipt_sender(text) to service_role;

-- Forwarded receipts -------------------------------------------------------------------------------------------------

create table public.forwarded_receipts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  -- Resend's id for the email, so a webhook delivered twice stores it once.
  source_id text not null unique check (char_length(source_id) between 1 and 100),
  lines text[] not null check (cardinality(lines) between 1 and 400),
  received_at timestamptz not null default now()
);
create index forwarded_receipts_household_idx on public.forwarded_receipts (household_id, received_at);
create index forwarded_receipts_received_idx on public.forwarded_receipts (received_at);

alter table public.forwarded_receipts enable row level security;
revoke all on table public.forwarded_receipts from public, anon, authenticated;
grant select (id, household_id, lines, received_at) on public.forwarded_receipts to authenticated;
grant delete on public.forwarded_receipts to authenticated;
-- Anyone in the family reviews a receipt, kids too, as anyone can scan one or check things off.
create policy "members read forwarded receipts" on public.forwarded_receipts
  for select to authenticated using (public.is_household_member(household_id));
create policy "members clear forwarded receipts" on public.forwarded_receipts
  for delete to authenticated using (public.is_household_member(household_id));

-- Called by receipt-inbox (service role) once the mail has passed its checks. Returns stored, duplicate,
-- unknown_inbox, unknown_sender (no confirmed sender with that address, or its adult has left or isn't an adult
-- any more), over_limit, or bad_lines (empty, over 400, or a line over 200 characters).
create function public.record_forwarded_receipt(inbox_token text, sender_hash text, source_id text, lines text[])
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  target uuid;
begin
  select household_id into target from public.receipt_inboxes where token = inbox_token;
  if target is null then
    return 'unknown_inbox';
  end if;
  if not exists (
    select 1 from public.receipt_senders s
      join public.members m on m.id = s.member_id
      where s.household_id = target and s.address_hash = sender_hash and s.confirmed_at is not null
        and m.household_id = target and m.user_id = s.user_id and m.age_group = 'adult' and m.status <> 'removed'
  ) then
    return 'unknown_sender';
  end if;
  if lines is null or cardinality(lines) not between 1 and 400
     or exists (select 1 from unnest(lines) l where l is null or char_length(l) not between 1 and 200) then
    return 'bad_lines';
  end if;
  if exists (select 1 from public.forwarded_receipts f where f.source_id = record_forwarded_receipt.source_id) then
    return 'duplicate';
  end if;
  -- 20 a day per household, so even a confirmed sender's address that leaked can't flood the family's Lists.
  if (select count(*) from public.forwarded_receipts f
        where f.household_id = target and f.received_at > now() - interval '1 day')
     >= 20 then
    return 'over_limit';
  end if;
  insert into public.forwarded_receipts (household_id, source_id, lines)
    values (target, record_forwarded_receipt.source_id, record_forwarded_receipt.lines)
    on conflict on constraint forwarded_receipts_source_id_key do nothing;
  return case when found then 'stored' else 'duplicate' end;
end;
$$;

revoke execute on function public.record_forwarded_receipt(text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.record_forwarded_receipt(text, text, text, text[]) to service_role;

-- Daily: unreviewed receipts go after 14 days; links nobody clicked go a week after they lapse; an address whose adult
-- has left the household, or isn't an adult there any more, goes.
create function public.prune_forwarded_receipts()
returns void
language sql security definer set search_path = ''
as $$
  delete from public.forwarded_receipts where received_at < now() - interval '14 days';
  delete from public.receipt_sender_emails where created_at < now() - interval '1 day';
  delete from public.receipt_senders where confirmed_at is null and confirm_expires_at < now() - interval '7 days';
  delete from public.receipt_senders s where not exists (
    select 1 from public.members m
      where m.id = s.member_id and m.household_id = s.household_id and m.user_id = s.user_id
        and m.age_group = 'adult' and m.status <> 'removed');
$$;

revoke execute on function public.prune_forwarded_receipts() from public, anon, authenticated;

select cron.schedule('prune-forwarded-receipts', '41 4 * * *', 'select public.prune_forwarded_receipts()');

-- Exporting ------------------------------------------------------------------------------------------------------------

-- As 20261122000000_shopping_trips, plus forwarded receipts waiting for review and forwarding addresses (their hints;
-- never the hash). Named columns, since the caller can't read the others.
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
    'agreement_holds', (
      select coalesce(jsonb_agg(to_jsonb(h) order by h.held_at), '[]')
      from (select id, kind, member_id, consent_id, held_version, required_version, was_linked, held_at, released_at,
                   released_reason, relinked
            from public.agreement_holds where household_id = target_household) h),
    'parental_consent_requests', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]')
      from (select id, member_id, status, reason, email_source, text_version, token_sent_at, expires_at, decided_at,
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
                from public.ai_jobs j where household_id = target_household),
    'shopping_trips', (select coalesce(jsonb_agg(to_jsonb(t) - 'household_id' order by t.finished_at), '[]')
                       from public.shopping_trips t where household_id = target_household),
    'forwarded_receipts', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'lines', f.lines,
                                                                        'received_at', f.received_at)
                                                     order by f.received_at), '[]')
                           from public.forwarded_receipts f where f.household_id = target_household),
    'receipt_senders', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'member_id', s.member_id,
                                                                     'address_hint', s.address_hint,
                                                                     'confirmed_at', s.confirmed_at,
                                                                     'created_at', s.created_at)
                                                  order by s.created_at), '[]')
                        from public.receipt_senders s where s.household_id = target_household)
  );
end;
$$;

