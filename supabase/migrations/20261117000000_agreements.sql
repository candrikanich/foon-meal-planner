-- Versioned agreements, holds and logs (#277, PR A: database only). Plan: planning/m4-277-agreements-plan.md, with
-- Chris's answers of 2026-11-09. Over-cover, over-log, over-communicate: every agreement is logged per person (who,
-- when, which wording), and a changed wording is asked again.
--
-- Ships dormant. Every registry row has effective_at = null, so nothing is "in force", every agreement satisfies, and
-- no hold opens: nobody sees a difference until a later migration (PR D) sets effective_at. Two changes do show now:
-- set_member_allergies changes only what changed instead of deleting and re-adding everything, and nobody inserts into
-- consent_agreements directly (the functions log every agreement).
--
-- * agreement_versions: the registry. The newest version of a kind with effective_at <= now() is the one in force; an
--   agreement to an older one still counts unless a version after it requires agreeing again (a typo fix doesn't).
-- * consent_agreements becomes the per-person log: kind (household allergy data, an adult's own allergies, a kid's
--   parental consent), whose profile it's about, which consent cycle it belongs to, how (in the app or email plus) and
--   from which email request.
-- * consents stays the on/off gate. It's never revoked to force a re-agreement: revoking starts the 30-day erase and
--   un-names pushes. A hold is a separate record instead.
-- * agreement_holds: while the household's allergy agreement is outdated nobody adds allergies (existing ones keep
--   flagging); while a kid's parental consent is outdated the kid is signed out (unlinked, invites revoked), keeps their
--   profile and starts no erase clock, and every parent is told by push and, where their account has a verified email,
--   by email (one reminder after 7 days). A renewal by email plus links the kid's account back. A parent's No in the
--   renewal email keeps the kid held; nothing is revoked.
-- * account_agreements: each account's Terms and Privacy acceptances. Account-level, so no household_id (a documented
--   exception to household tenancy); no foreign key to auth.users, so it survives account deletion as proof.

-- Registry ----------------------------------------------------------------------------------------------------------------

create type public.agreement_kind as enum ('allergy_data', 'own_allergy_data', 'parental', 'terms', 'privacy');

create table public.agreement_versions (
  version text primary key check (char_length(btrim(version)) between 1 and 40),
  kind public.agreement_kind not null,
  -- Order within the kind: a higher ordinal is newer wording.
  ordinal int not null check (ordinal > 0),
  -- False for a fix that changes nothing promised (a typo): agreements to earlier versions still count.
  requires_reagreement boolean not null default true,
  -- Null: known (it can be agreed to) but not in force. The newest with effective_at <= now() is in force.
  effective_at timestamptz,
  -- What changed, in one plain sentence, for the prompt and the renewal email.
  summary text not null check (char_length(btrim(summary)) between 1 and 300),
  created_at timestamptz not null default now(),
  unique (kind, ordinal),
  -- For account_agreements' foreign key, so a Terms row can only name a Terms version.
  unique (version, kind)
);

alter table public.agreement_versions enable row level security;
revoke all on table public.agreement_versions from public, anon, authenticated;
grant select on public.agreement_versions to authenticated, service_role;

create policy "signed-in people read the wordings" on public.agreement_versions
  for select to authenticated
  using (true);

-- `sample-family-v1` isn't a row: it says nobody read the sentence, and counts only while the household is a sample.
insert into public.agreement_versions (version, kind, ordinal, summary) values
  ('allergy-data-v1', 'allergy_data', 1,
   'Foon keeps your family''s allergies to flag dishes, and a parent can turn allergy alerts off anytime, which erases them.'),
  ('allergy-data-v2', 'allergy_data', 2,
   'Foon now names who receives your family''s allergies (only your household and our hosting provider) and how a parent withdraws, which erases them all.'),
  ('own-allergy-v1', 'own_allergy_data', 1,
   'Adults who aren''t parents now agree for themselves before Foon keeps their own allergies.'),
  ('parental-invite-v1', 'parental', 1,
   'A parent agreed in the app to let their kid use Foon on their own device.'),
  ('parental-invite-v2', 'parental', 2,
   'The agreement now links the Terms of Use and Privacy Policy, and says no invite goes out without a parent''s yes.'),
  ('parental-invite-v3', 'parental', 3,
   'Foon now confirms a parent''s consent by email, and names the services that store and send your kid''s information.'),
  ('terms-draft-v1', 'terms', 1, 'Foon''s Terms of Use: the rules for using Foon, which every adult agrees to.'),
  ('privacy-draft-v1', 'privacy', 1, 'Foon''s Privacy Policy: what Foon keeps about your family, why, and for how long.');

-- The version in force for a kind, or null when none is.
create function public.current_agreement_version(k public.agreement_kind)
returns text
language sql stable security definer set search_path = ''
as $$
  select v.version from public.agreement_versions v
   where v.kind = k and v.effective_at <= now()
   order by v.ordinal desc
   limit 1;
$$;

-- Whether an agreement to `agreed` still counts. True when nothing of the kind is in force; false for a version the
-- registry doesn't know (once something is in force); otherwise true unless a version after it, up to the one in force,
-- requires agreeing again.
create function public.agreement_satisfies(agreed text, k public.agreement_kind)
returns boolean
language sql stable security definer set search_path = ''
as $$
  with in_force as (
    select v.ordinal from public.agreement_versions v
     where v.kind = k and v.effective_at <= now()
     order by v.ordinal desc
     limit 1
  ), mine as (
    select v.ordinal from public.agreement_versions v where v.kind = k and v.version = agreed
  )
  select case
    when not exists (select 1 from in_force) then true
    when not exists (select 1 from mine) then false
    else not exists (
      select 1 from public.agreement_versions v, in_force, mine
       where v.kind = k and v.ordinal > mine.ordinal and v.ordinal <= in_force.ordinal and v.requires_reagreement)
  end;
$$;

revoke execute on function public.current_agreement_version(public.agreement_kind) from public, anon;
revoke execute on function public.agreement_satisfies(text, public.agreement_kind) from public, anon;
grant execute on function public.current_agreement_version(public.agreement_kind) to authenticated, service_role;
grant execute on function public.agreement_satisfies(text, public.agreement_kind) to authenticated, service_role;

-- The per-person log ------------------------------------------------------------------------------------------------------

alter table public.consent_agreements
  add column kind public.agreement_kind not null default 'allergy_data'
    check (kind in ('allergy_data', 'own_allergy_data', 'parental')),
  -- The kid (parental) or the adult (own_allergy_data); null for the household's allergy agreement.
  add column member_id uuid,
  -- The consent cycle the agreement belongs to: agreeing again after a withdrawal starts a new one.
  add column consent_id uuid references public.consents (id),
  add column method public.consent_method not null default 'in_app',
  -- The parental_consent_requests row it came from. No foreign key: requests are purged 30 days after they end.
  add column request_id uuid,
  add constraint consent_agreements_member_fkey foreign key (member_id, household_id)
    references public.members (id, household_id),
  add constraint consent_agreements_member_matches_kind check ((kind = 'allergy_data') = (member_id is null));

-- One row per person, wording and consent cycle, instead of one per person and wording ever. Dropped before the
-- backfill: a parent who consented for two kids to one wording has two parental rows.
alter table public.consent_agreements drop constraint consent_agreements_one_per_wording;

-- Which consent each allergy agreement belongs to: the one active when it was given, else the active one.
update public.consent_agreements a
   set consent_id = coalesce(
     (select c.id from public.consents c
       where c.household_id = a.household_id and c.kind = 'allergy_data' and c.member_id is null
         and c.granted_at <= a.agreed_at and (c.revoked_at is null or a.agreed_at < c.revoked_at)
       order by c.granted_at desc
       limit 1),
     (select c.id from public.consents c
       where c.household_id = a.household_id and c.kind = 'allergy_data' and c.member_id is null
         and c.revoked_at is null))
 where a.kind = 'allergy_data' and a.consent_id is null;

-- Every parental consent so far was an agreement by the parent who gave it.
insert into public.consent_agreements (household_id, agreed_by, agreed_at, text_version, kind, member_id, consent_id,
                                       method, request_id)
select household_id, granted_by, granted_at, text_version, 'parental', member_id, id, method, request_id
from public.consents
where kind = 'parental';

create unique index consent_agreements_once_per_cycle on public.consent_agreements
  (household_id, consent_id, kind, member_id, agreed_by, text_version) nulls not distinct;
create index consent_agreements_consent_idx on public.consent_agreements (consent_id);
create index consent_agreements_member_idx on public.consent_agreements (member_id) where member_id is not null;
create index consent_agreements_request_idx on public.consent_agreements (request_id) where request_id is not null;

-- No build inserts directly any more: grant_allergy_consent, agree_to_own_allergies and activate_parental_consent log.
drop policy "guardians record their own agreement" on public.consent_agreements;
revoke insert on public.consent_agreements from authenticated;

-- Holds ---------------------------------------------------------------------------------------------------------------------

create table public.agreement_holds (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  kind public.agreement_kind not null check (kind in ('allergy_data', 'parental')),
  -- The kid, for a parental hold; null for the household's allergy hold.
  member_id uuid,
  consent_id uuid not null references public.consents (id),
  -- The newest wording agreed to in that consent cycle, and the one now in force.
  held_version text not null check (char_length(btrim(held_version)) between 1 and 40),
  required_version text not null check (char_length(btrim(required_version)) between 1 and 40),
  -- The kid's account, unlinked by the hold, so a renewal can link it back. Cleared when the hold ends; set null if the
  -- account is deleted meanwhile.
  held_user_id uuid references auth.users (id) on delete set null,
  -- Whether the kid had an account when the hold began: a renewal that can't link it back ends as account_gone.
  was_linked boolean not null default false,
  held_at timestamptz not null default now(),
  -- Renewal emails: the first round (to every parent with a verified email) and the one reminder 7 days later.
  emailed_at timestamptz,
  reminded_at timestamptz,
  released_at timestamptz,
  released_reason text check (released_reason in ('renewed', 'withdrawn', 'removed', 'account_gone')),
  -- For a renewed parental hold: whether the kid's account was linked back.
  relinked boolean,
  foreign key (member_id, household_id) references public.members (id, household_id) on delete cascade,
  check ((kind = 'parental') = (member_id is not null)),
  check ((released_at is null) = (released_reason is null))
);

create unique index agreement_holds_one_open on public.agreement_holds (household_id, kind, member_id)
  nulls not distinct where released_at is null;
create index agreement_holds_member_idx on public.agreement_holds (member_id) where member_id is not null;
create index agreement_holds_consent_idx on public.agreement_holds (consent_id);
create index agreement_holds_held_user_idx on public.agreement_holds (held_user_id) where held_user_id is not null;

alter table public.agreement_holds enable row level security;
revoke all on table public.agreement_holds from public, anon, authenticated;
-- Never the kid's account or the email bookkeeping. Nothing that enforces a hold reads this table.
grant select (id, household_id, kind, member_id, consent_id, held_version, required_version, was_linked, held_at,
              released_at, released_reason, relinked)
  on public.agreement_holds to authenticated;

create policy "parents read their household's holds" on public.agreement_holds
  for select to authenticated
  using (public.is_household_manager(household_id));

-- Renewal requests go through the same table, rate limits and emails as a first consent.
alter table public.parental_consent_requests
  add column reason text not null default 'invite' check (reason in ('invite', 'renewal')),
  add column hold_id uuid references public.agreement_holds (id) on delete set null;
create index parental_consent_requests_hold_idx on public.parental_consent_requests (hold_id) where hold_id is not null;
grant select (reason) on public.parental_consent_requests to authenticated;

-- Terms and Privacy ---------------------------------------------------------------------------------------------------------

create table public.account_agreements (
  id uuid primary key default gen_random_uuid(),
  -- No foreign key, like consents.granted_by: kept as proof after the account is deleted.
  user_id uuid not null default auth.uid(),
  kind public.agreement_kind not null check (kind in ('terms', 'privacy')),
  text_version text not null,
  agreed_at timestamptz not null default now(),
  context text not null check (context in ('create_household', 'join', 'next_launch', 'changed')),
  -- The app's version, for support ("Foon 1.4 (63)").
  client text check (char_length(client) <= 40),
  foreign key (text_version, kind) references public.agreement_versions (version, kind),
  unique (user_id, text_version)
);

alter table public.account_agreements enable row level security;
revoke all on table public.account_agreements from public, anon, authenticated;
grant select on public.account_agreements to authenticated;

-- Account-level, not household-owned: each account reads only its own, with a live session.
create policy "people read their own agreements" on public.account_agreements
  for select to authenticated
  using (user_id = (select auth.uid()) and public.session_is_active());

-- Whether agreements are current --------------------------------------------------------------------------------------------

-- The household's allergy agreement: an active consent whose wording, or a later agreement in the same cycle, still
-- satisfies. A sample family's consent counts while the household is still a sample. Answers only for the caller's own
-- household (or server code, where nobody is signed in).
create function public.household_allergy_agreement_current(target_household uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select ((select auth.uid()) is null or public.is_household_member(target_household)
          or public.is_household_planner(target_household))
     and exists (
       select 1 from public.consents c
        where c.household_id = target_household and c.kind = 'allergy_data' and c.member_id is null
          and c.revoked_at is null
          and (public.agreement_satisfies(c.text_version, 'allergy_data')
               or (c.text_version = 'sample-family-v1'
                   and exists (select 1 from public.households h
                                where h.id = target_household and h.settings -> 'sample' = 'true'::jsonb))
               or exists (select 1 from public.consent_agreements a
                           where a.consent_id = c.id and a.kind = 'allergy_data'
                             and public.agreement_satisfies(a.text_version, 'allergy_data'))));
$$;

-- An adult's own allergies: a parent's always count (they agree for the household); anyone else needs their own
-- agreement in the active consent cycle once a version is in force.
create function public.own_allergy_agreement_current(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.members m
     where m.id = target_member
       and ((select auth.uid()) is null or public.is_household_member(m.household_id))
       and (m.guardian
            or public.current_agreement_version('own_allergy_data') is null
            or exists (select 1 from public.consent_agreements a
                         join public.consents c on c.id = a.consent_id
                        where a.member_id = m.id and a.kind = 'own_allergy_data' and c.revoked_at is null
                          and public.agreement_satisfies(a.text_version, 'own_allergy_data'))));
$$;

-- A kid's parental consent: active, and its wording or a later agreement in the same cycle still satisfies. Unlike
-- has_parental_consent, which retention and push naming keep using, so a held kid starts no erase clock.
create function public.has_current_parental_consent(target_member uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.consents c
     where c.member_id = target_member and c.kind = 'parental' and c.revoked_at is null
       and (public.agreement_satisfies(c.text_version, 'parental')
            or exists (select 1 from public.consent_agreements a
                        where a.consent_id = c.id and a.kind = 'parental'
                          and public.agreement_satisfies(a.text_version, 'parental'))));
$$;

-- The consent a request gave (a first consent) or renewed (a renewal logs an agreement on the existing consent).
create function public.consent_for_request(target_request uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select c.id from public.consents c where c.request_id = target_request limit 1),
    (select a.consent_id from public.consent_agreements a where a.request_id = target_request limit 1));
$$;

-- The newest wording agreed to in a consent cycle.
create function public.latest_agreed_version(target_consent uuid, k public.agreement_kind)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select a.text_version from public.consent_agreements a
      where a.consent_id = target_consent and a.kind = k
      order by a.agreed_at desc, a.id
      limit 1),
    (select c.text_version from public.consents c where c.id = target_consent));
$$;

revoke execute on function public.household_allergy_agreement_current(uuid) from public, anon;
revoke execute on function public.own_allergy_agreement_current(uuid) from public, anon;
grant execute on function public.household_allergy_agreement_current(uuid) to authenticated, service_role;
grant execute on function public.own_allergy_agreement_current(uuid) to authenticated, service_role;
revoke execute on function public.has_current_parental_consent(uuid) from public, anon, authenticated;
revoke execute on function public.consent_for_request(uuid) from public, anon, authenticated;
revoke execute on function public.latest_agreed_version(uuid, public.agreement_kind) from public, anon, authenticated;

-- Ending a hold -------------------------------------------------------------------------------------------------------------

-- Ends an open hold. A renewed kid's account is linked back if it still exists and hasn't joined anywhere; otherwise
-- the hold ends as account_gone and a parent invites them again. The account id goes either way.
create function public.release_agreement_hold(target uuid, reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  hold public.agreement_holds;
  linked boolean := false;
begin
  select * into hold from public.agreement_holds where id = target and released_at is null for update;
  if hold.id is null then
    return;
  end if;
  if reason = 'renewed' and hold.kind = 'parental' and hold.held_user_id is not null then
    update public.members set user_id = hold.held_user_id
     where id = hold.member_id and user_id is null and status <> 'removed'
       and not exists (select 1 from public.members other where other.user_id = hold.held_user_id)
       and exists (select 1 from auth.users u where u.id = hold.held_user_id);
    linked := found;
  end if;
  update public.agreement_holds
     set released_at = now(),
         released_reason = case when reason = 'renewed' and hold.was_linked and not linked then 'account_gone'
                                else reason end,
         relinked = case when reason = 'renewed' and hold.kind = 'parental' then linked end,
         held_user_id = null
   where id = hold.id;
end;
$$;

revoke execute on function public.release_agreement_hold(uuid, text) from public, anon, authenticated;

-- Withdrawing either consent ends its hold. The withdrawal itself starts the 30-day clock, as it always did.
create function public.consents_close_agreement_holds()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.release_agreement_hold(h.id, 'withdrawn')
     from public.agreement_holds h where h.consent_id = new.id and h.released_at is null;
  return null;
end;
$$;

revoke execute on function public.consents_close_agreement_holds() from public, anon, authenticated;

create trigger consents_close_agreement_holds after update of revoked_at on public.consents
  for each row when (old.revoked_at is null and new.revoked_at is not null)
  execute function public.consents_close_agreement_holds();

-- Removing a kid ends their hold; nobody renews for someone who left.
create function public.members_close_agreement_holds()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.release_agreement_hold(h.id, 'removed')
     from public.agreement_holds h where h.member_id = new.id and h.released_at is null;
  return null;
end;
$$;

revoke execute on function public.members_close_agreement_holds() from public, anon, authenticated;

create trigger members_close_agreement_holds after update of status on public.members
  for each row when (new.status = 'removed' and old.status <> 'removed')
  execute function public.members_close_agreement_holds();

-- Push: a hold tells every parent -----------------------------------------------------------------------------------------

alter table public.notification_log drop constraint notification_log_type_check;
alter table public.notification_log add constraint notification_log_type_check check (type in (
  'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
  'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store',
  'not_home', 'rating_roundup', 'agreement_hold'));

alter table public.push_outbox drop constraint push_outbox_kind_check;
alter table public.push_outbox add constraint push_outbox_kind_check check (kind in (
  'time_to_plan', 'prep_reminder', 'after_dinner', 'day_of_check_in', 'requests_open', 'plan_set', 'no_plan_tonight',
  'tonight_poll', 'urgent_item', 'new_requests', 'weekly_recap', 'claim', 'request_planned', 'heading_to_store',
  'not_home', 'rating_roundup', 'agreement_hold'));

-- As store_run's (20261102210000_store_run.sql), with a held kid first: a parent has to act for the kid to get back in.
create or replace function public.push_kind_rank(row_kind text)
returns int
language sql immutable set search_path = ''
as $$
  select case row_kind
    when 'plan_set' then 0 when 'urgent_item' then 0 when 'heading_to_store' then 0 when 'agreement_hold' then 0
    when 'not_home' then 1 when 'claim' then 1
    when 'tonight_poll' then 2
    else 3
  end;
$$;

-- Applying holds (service role, hourly) -----------------------------------------------------------------------------------

-- Ends holds that no longer apply, then opens one for each kid whose parental consent and each household whose allergy
-- agreement is outdated. A held kid is unlinked (their devices and pushes go, as on a withdrawal) and their invites are
-- revoked; their consent stays active, so no erase clock starts and pushes keep their name. Every parent with a device
-- hears about it. Returns how many holds it opened.
create function public.apply_agreement_holds()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  open_hold record;
  candidate uuid;
  kid public.members;
  active public.consents;
  new_hold uuid;
  tz text;
  opened int := 0;
  allergy_opened int;
begin
  for open_hold in select h.id, h.kind, h.member_id, h.household_id, h.consent_id
                     from public.agreement_holds h where h.released_at is null loop
    if exists (select 1 from public.consents c where c.id = open_hold.consent_id and c.revoked_at is not null) then
      perform public.release_agreement_hold(open_hold.id, 'withdrawn');
    elsif open_hold.kind = 'parental' and public.has_current_parental_consent(open_hold.member_id) then
      perform pg_advisory_xact_lock(hashtextextended('parental_consent:' || open_hold.member_id::text, 0));
      perform public.release_agreement_hold(open_hold.id, 'renewed');
    elsif open_hold.kind = 'allergy_data' and public.household_allergy_agreement_current(open_hold.household_id) then
      perform public.release_agreement_hold(open_hold.id, 'renewed');
    end if;
  end loop;

  for candidate in select m.id from public.members m
                    where m.age_group = 'kid' and m.status <> 'removed'
                      and public.has_parental_consent(m.id) and not public.has_current_parental_consent(m.id)
                      and not exists (select 1 from public.agreement_holds h
                                       where h.member_id = m.id and h.kind = 'parental' and h.released_at is null) loop
    -- The same per-kid lock as activate_parental_consent, then everything again: a renewal may have just landed.
    perform pg_advisory_xact_lock(hashtextextended('parental_consent:' || candidate::text, 0));
    select * into kid from public.members where id = candidate for update;
    continue when kid.status = 'removed' or not public.has_parental_consent(kid.id)
                  or public.has_current_parental_consent(kid.id);
    select * into active from public.consents where member_id = kid.id and kind = 'parental' and revoked_at is null;

    new_hold := null;
    insert into public.agreement_holds (household_id, kind, member_id, consent_id, held_version, required_version,
                                        held_user_id, was_linked)
    values (kid.household_id, 'parental', kid.id, active.id, public.latest_agreed_version(active.id, 'parental'),
            public.current_agreement_version('parental'), kid.user_id, kid.user_id is not null)
    on conflict do nothing
    returning id into new_hold;
    continue when new_hold is null;

    -- Invites first, as on a withdrawal (consents_unlink_on_parental_revoke).
    update public.invites set revoked_at = now()
     where member_id = kid.id and redeemed_at is null and revoked_at is null;
    update public.members set user_id = null where id = kid.id and user_id is not null;

    -- After the unlink, whose trigger deletes every push about the kid.
    tz := public.household_time_zone(kid.household_id);
    insert into public.push_outbox (household_id, member_id, kind, about_member_id, args, not_before)
    select m.household_id, m.id, 'agreement_hold', kid.id, public.push_name_args(kid.id),
           public.push_not_before(tz, false, now())
      from public.members m
     where m.household_id = kid.household_id and m.guardian and m.status <> 'removed' and m.user_id is not null
       and exists (select 1 from public.push_devices d where d.member_id = m.id);
    opened := opened + 1;
  end loop;

  insert into public.agreement_holds (household_id, kind, consent_id, held_version, required_version)
  select c.household_id, 'allergy_data', c.id, public.latest_agreed_version(c.id, 'allergy_data'),
         public.current_agreement_version('allergy_data')
    from public.consents c
   where c.kind = 'allergy_data' and c.member_id is null and c.revoked_at is null
     and not public.household_allergy_agreement_current(c.household_id)
  on conflict do nothing;
  get diagnostics allergy_opened = row_count;

  return opened + allergy_opened;
end;
$$;

revoke execute on function public.apply_agreement_holds() from public, anon, authenticated;
grant execute on function public.apply_agreement_holds() to service_role;

select cron.schedule('apply-agreement-holds', '11 * * * *', 'select public.apply_agreement_holds()');

-- Allergies -----------------------------------------------------------------------------------------------------------------

-- As consent_agreements' (20261031020000), now security definer because nobody inserts into consent_agreements
-- directly; the parent check is the same one. Only a registered wording (or the sample family's) is accepted, every
-- agreement is logged in its consent cycle, and an agreement to the wording in force ends the household's allergy hold.
create or replace function public.grant_allergy_consent(target_household uuid, wording text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  active uuid;
begin
  if not public.is_household_manager(target_household) then
    raise exception 'only parents decide about allergy data' using errcode = '42501';
  end if;
  if wording is distinct from 'sample-family-v1'
     and not exists (select 1 from public.agreement_versions where version = wording and kind = 'allergy_data') then
    raise exception 'unknown allergy wording %', wording using errcode = '22023';
  end if;
  insert into public.consents (household_id, kind, granted_by, text_version)
  values (target_household, 'allergy_data', (select auth.uid()), wording)
  on conflict (household_id, kind, member_id) where revoked_at is null do nothing;
  select id into active from public.consents
   where household_id = target_household and kind = 'allergy_data' and member_id is null and revoked_at is null;
  insert into public.consent_agreements (household_id, agreed_by, text_version, kind, consent_id, method)
  values (target_household, (select auth.uid()), wording, 'allergy_data', active, 'in_app')
  on conflict do nothing;
  if public.household_allergy_agreement_current(target_household) then
    perform public.release_agreement_hold(h.id, 'renewed')
       from public.agreement_holds h
      where h.household_id = target_household and h.kind = 'allergy_data' and h.released_at is null;
  end if;
end;
$$;

-- An adult who isn't a parent agrees to keep their own allergies. A parent's agreement covers the household; this one
-- is the adult's own say.
create function public.agree_to_own_allergies(target_member uuid, wording text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  me public.members;
  active uuid;
begin
  select * into me from public.members where id = target_member;
  if me.id is null or not public.is_own_adult_profile(target_member) then
    raise exception 'only you agree for your own allergies' using errcode = '42501';
  end if;
  select id into active from public.consents
   where household_id = me.household_id and kind = 'allergy_data' and member_id is null and revoked_at is null;
  if active is null then
    raise exception 'the household has not agreed to keep allergy data' using errcode = '42501';
  end if;
  if not exists (select 1 from public.agreement_versions where version = wording and kind = 'own_allergy_data') then
    raise exception 'unknown wording %', wording using errcode = '22023';
  end if;
  insert into public.consent_agreements (household_id, agreed_by, text_version, kind, member_id, consent_id, method)
  values (me.household_id, (select auth.uid()), wording, 'own_allergy_data', me.id, active, 'in_app')
  on conflict do nothing;
end;
$$;

revoke execute on function public.agree_to_own_allergies(uuid, text) from public, anon;
grant execute on function public.agree_to_own_allergies(uuid, text) to authenticated;

-- As edit_own_allergies' (20261115000000), changing only what changed: an unchanged save and removals touch nothing
-- else, so they work while an agreement is outdated, and a row someone kept keeps its id. Adding needs the household's
-- agreement to be current (hint agreement_outdated) and, on your own profile, your own (hint own_agreement_needed).
create or replace function public.set_member_allergies(target_member uuid, allergens public.allergen[], custom text[])
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  household uuid;
  keeps_something boolean;
  adds_something boolean;
begin
  select household_id into household from public.members where id = target_member;
  if household is null then
    raise exception 'no member %', target_member using errcode = 'P0002';
  end if;
  keeps_something := exists (select 1 from unnest(allergens) as wanted(allergen) where wanted.allergen <> 'custom')
                     or exists (select 1 from unnest(custom) as wanted(value) where btrim(wanted.value) <> '');
  if not public.is_household_manager(household) and not public.is_own_adult_profile(target_member) then
    raise exception 'only parents set allergies' using errcode = '42501';
  end if;
  -- Keeping something needs consent. Clearing keeps nothing, so it doesn't.
  if keeps_something and not public.has_active_consent(household, 'allergy_data') then
    raise exception 'the household has not agreed to keep allergy data' using errcode = '42501';
  end if;

  adds_something :=
    exists (select 1 from unnest(allergens) as wanted(allergen)
             where wanted.allergen <> 'custom'
               and not exists (select 1 from public.member_allergies a
                                where a.member_id = target_member and a.category = wanted.allergen))
    or exists (select 1 from unnest(custom) as wanted(value)
                where btrim(wanted.value) <> ''
                  and not exists (select 1 from public.member_allergies a
                                   where a.member_id = target_member and a.category = 'custom'
                                     and a.custom_text = btrim(wanted.value)));
  if adds_something and not public.household_allergy_agreement_current(household) then
    raise exception 'a parent needs to agree to the new allergy wording first'
      using errcode = '42501', hint = 'agreement_outdated';
  end if;
  if adds_something
     and exists (select 1 from public.members where id = target_member and user_id = (select auth.uid()))
     and not public.own_allergy_agreement_current(target_member) then
    raise exception 'agree to keep your own allergies first' using errcode = '42501', hint = 'own_agreement_needed';
  end if;

  delete from public.member_allergies a
   where a.member_id = target_member
     and not coalesce(
       case when a.category = 'custom'
            then a.custom_text in (select btrim(wanted.value) from unnest(custom) as wanted(value)
                                    where btrim(wanted.value) <> '')
            else a.category in (select wanted.allergen from unnest(allergens) as wanted(allergen))
       end, false);

  insert into public.member_allergies (household_id, member_id, category)
  select distinct household, target_member, wanted.allergen
    from unnest(allergens) as wanted(allergen)
   where wanted.allergen <> 'custom'
     and not exists (select 1 from public.member_allergies a
                      where a.member_id = target_member and a.category = wanted.allergen);

  insert into public.member_allergies (household_id, member_id, category, custom_text)
  select distinct household, target_member, 'custom'::public.allergen, btrim(wanted.value)
    from unnest(custom) as wanted(value)
   where btrim(wanted.value) <> ''
     and not exists (select 1 from public.member_allergies a
                      where a.member_id = target_member and a.category = 'custom'
                        and a.custom_text = btrim(wanted.value));
end;
$$;

-- As people_roles_consent's (20261026145314), plus the two agreement checks, and on a change of category or text too, so
-- a direct write can't add an allergy past a hold. Someone outside the household gets the policy's refusal, not a hint.
create or replace function public.member_allergies_lock_consent()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;
  end if;
  perform 1 from public.consents
  where household_id = new.household_id and kind = 'allergy_data' and member_id is null and revoked_at is null
  for share;
  if not found then
    raise exception 'allergy data needs the household''s consent' using errcode = '42501';
  end if;
  if public.is_household_member(new.household_id) or public.is_household_planner(new.household_id) then
    if not public.household_allergy_agreement_current(new.household_id) then
      raise exception 'a parent needs to agree to the new allergy wording first'
        using errcode = '42501', hint = 'agreement_outdated';
    end if;
    if exists (select 1 from public.members where id = new.member_id and user_id = (select auth.uid()))
       and not public.own_allergy_agreement_current(new.member_id) then
      raise exception 'agree to keep your own allergies first' using errcode = '42501', hint = 'own_agreement_needed';
    end if;
  end if;
  return new;
end;
$$;

drop trigger member_allergies_lock_consent on public.member_allergies;
create trigger member_allergies_lock_consent
  before insert or update of category, custom_text on public.member_allergies
  for each row execute function public.member_allergies_lock_consent();

-- Terms and Privacy ---------------------------------------------------------------------------------------------------------

-- Logs this account's acceptance of both. Any registered version of the right kind is accepted, so an older app showing
-- older text still logs what it showed.
create function public.accept_agreements(terms text, privacy text, context text, client text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  if not exists (select 1 from public.agreement_versions where version = terms and kind = 'terms')
     or not exists (select 1 from public.agreement_versions where version = privacy and kind = 'privacy') then
    raise exception 'unknown wording' using errcode = '22023';
  end if;
  if context is null or context not in ('create_household', 'join', 'next_launch', 'changed') then
    raise exception 'context is create_household, join, next_launch or changed' using errcode = '22023';
  end if;
  if char_length(client) > 40 then
    raise exception 'client is at most 40 characters' using errcode = '22023';
  end if;
  insert into public.account_agreements (user_id, kind, text_version, context, client)
  values (caller, 'terms', terms, context, client), (caller, 'privacy', privacy, context, client)
  on conflict (user_id, text_version) do nothing;
end;
$$;

revoke execute on function public.accept_agreements(text, text, text, text) from public, anon;
grant execute on function public.accept_agreements(text, text, text, text) to authenticated;

-- What the app needs to know -------------------------------------------------------------------------------------------------

create function public.account_agreement_status(account uuid, k public.agreement_kind)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'current', public.current_agreement_version(k),
    'agreed', (select a.text_version from public.account_agreements a
                 join public.agreement_versions v on v.version = a.text_version
                where a.user_id = account and a.kind = k
                order by v.ordinal desc
                limit 1),
    'satisfied', public.current_agreement_version(k) is null
                 or exists (select 1 from public.account_agreements a
                             where a.user_id = account and a.kind = k
                               and public.agreement_satisfies(a.text_version, k)),
    'summary', (select v.summary from public.agreement_versions v
                 where v.version = public.current_agreement_version(k)));
$$;

revoke execute on function public.account_agreement_status(uuid, public.agreement_kind) from public, anon, authenticated;

-- One read for the app (see the PR for the shape). Without a household (before creating or joining one): Terms and
-- Privacy only. 28000 without a live session; 42501 for a household that isn't the caller's.
create function public.my_agreements(target_household uuid default null)
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

revoke execute on function public.my_agreements(uuid) from public, anon;
grant execute on function public.my_agreements(uuid) to authenticated;

-- A held kid's own device: their account has no household now. Null when the account isn't held.
create function public.my_access_hold()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  caller uuid := (select auth.uid());
begin
  if caller is null or not public.session_is_active() then
    raise exception 'sign in first' using errcode = '28000';
  end if;
  if exists (select 1 from public.members where user_id = caller) then
    return null;
  end if;
  return (select jsonb_build_object('household_name', hh.name, 'first_name', m.first_name, 'held_at', h.held_at)
            from public.agreement_holds h
            join public.members m on m.id = h.member_id
            join public.households hh on hh.id = h.household_id
           where h.held_user_id = caller and h.released_at is null
           order by h.held_at desc
           limit 1);
end;
$$;

revoke execute on function public.my_access_hold() from public, anon;
grant execute on function public.my_access_hold() to authenticated;

-- Invites -----------------------------------------------------------------------------------------------------------------

-- As parental_consent_and_retention's (20261026205731), with the consent in force: a held kid isn't invited until a
-- parent renews.
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
  if member.age_group = 'kid' and not public.has_current_parental_consent(target_member) then
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

-- As delete_kid's (20261113000000), with the consent in force: an invite made before a hold can't be redeemed during it.
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
    if not found or not public.has_current_parental_consent(member.id) then
      return 'needs_consent';
    end if;
  end if;
  if (member.age_group = 'adult' and age_band in ('under_13', '13_15', '16_17'))
     or (member.age_group = 'kid' and age_band = 'adult') then
    return 'age_mismatch';
  end if;

  update public.members set user_id = caller, declared_age_band = age_band where id = invite.member_id;
  update public.invites set redeemed_at = now(), redeemed_by = caller where id = invite.id;
  insert into public.invite_redeem_attempts (user_id, succeeded) values (caller, true);
  return 'claimed';
end;
$function$;

-- Parental consent by email: renewals ------------------------------------------------------------------------------------

-- As email_plus_consent's (20261116000000), plus renewals: a kid whose consent is active but outdated is asked again
-- (reason 'renewal'; their account may still be linked if no hold has opened yet). The send outcome adds reason and
-- text_version (the parental wording in force, null while none is), so the Edge Function can refuse to send a wording
-- that isn't the one in force.
create or replace function public.request_parental_consent(target_member uuid, email_address text default null)
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

  if open_request.id is null then
    insert into public.parental_consent_requests (household_id, member_id, requested_by, email_source, typed_email,
                                                  pending_email_hash, send_reserved_at, reason, hold_id)
    values (kid.household_id, kid.id, caller, source,
            case when source = 'typed' then address end, public.consent_email_hash(address), now(), request_reason,
            (select h.id from public.agreement_holds h
              where h.member_id = kid.id and h.kind = 'parental' and h.released_at is null))
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

  return jsonb_build_object('outcome', 'send', 'request_id', open_request.id, 'send_id', send_id,
                            'email', address, 'email_source', source, 'first_name', kid.first_name,
                            'reason', request_reason, 'text_version', public.current_agreement_version('parental'));
end;
$$;

-- As email_plus_consent's, plus: the wording emailed must be registered and satisfy what's in force (22023 otherwise),
-- and a renewal leaves other parents' renewal links live, since every parent is asked; the first to agree wins.
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
  if not exists (select 1 from public.agreement_versions where version = p_text_version and kind = 'parental')
     or not public.agreement_satisfies(p_text_version, 'parental') then
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
  end if;
  return true;
end;
$$;

-- As email_plus_consent's, with the consent in force: an outdated one can still be renewed, and a renewal's kid may
-- still be linked while no hold has opened.
create or replace function public.parental_consent_still_valid(request public.parental_consent_requests)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  kid public.members;
begin
  if public.has_current_parental_consent(request.member_id) then
    perform public.end_parental_consent_request(request.id, 'cancelled');
    return 'already_consented';
  end if;
  if request.expires_at is null or request.expires_at < now() then
    perform public.end_parental_consent_request(request.id, 'expired');
    return 'expired';
  end if;
  select * into kid from public.members where id = request.member_id;
  if kid.age_group <> 'kid' or kid.status = 'removed'
     or (kid.user_id is not null and not public.has_parental_consent(kid.id))
     or not public.is_parent_in(request.household_id, request.requested_by) then
    perform public.end_parental_consent_request(request.id, 'cancelled');
    return 'expired';
  end if;
  return null;
end;
$$;

-- As email_plus_consent's, with the consent a request gave or renewed, and the consent in force.
create or replace function public.parental_consent_settled(request public.parental_consent_requests)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when request.status = 'confirmed' then
      case when exists (select 1 from public.consents c
                         where c.id = public.consent_for_request(request.id) and c.revoked_at is null)
           then 'confirmed' else 'withdrawn' end
    when request.status = 'refused' then 'refused'
    when public.has_current_parental_consent(request.member_id) then 'already_consented'
    when request.status in ('cancelled', 'expired') or request.expires_at < now() then 'expired'
  end;
$$;

-- As email_plus_consent's. A renewal's pending page also gets reason, summary (what changed) and agreed_before (when a
-- parent last agreed); a first consent's answer is unchanged.
create or replace function public.parental_consent_lookup(p_token_hash text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
  active uuid;
begin
  select * into request from public.parental_consent_requests where token_hash = p_token_hash;
  if not found then return jsonb_build_object('outcome', 'invalid'); end if;
  if public.parental_consent_settled(request) is not null then
    return jsonb_build_object('outcome', public.parental_consent_settled(request));
  end if;
  if request.reason <> 'renewal' then
    return jsonb_build_object('outcome', 'pending', 'expires_at', request.expires_at,
                              'first_name', (select first_name from public.members where id = request.member_id));
  end if;
  select id into active from public.consents
   where member_id = request.member_id and kind = 'parental' and revoked_at is null;
  return jsonb_build_object(
    'outcome', 'pending', 'expires_at', request.expires_at, 'reason', 'renewal',
    'first_name', (select first_name from public.members where id = request.member_id),
    'summary', (select v.summary from public.agreement_versions v
                 where v.version = coalesce(request.text_version, public.current_agreement_version('parental'))),
    'agreed_before', coalesce((select max(a.agreed_at) from public.consent_agreements a
                                where a.consent_id = active and a.kind = 'parental'),
                              (select c.granted_at from public.consents c where c.id = active)));
end;
$$;

-- As email_plus_consent's. A kid with an active (outdated) consent is renewed: the agreement is logged on that consent,
-- no new consents row, and the hold ends, linking the kid's account back. Otherwise a new consent, as before, now also
-- logged. Either way the other open requests for the kid end.
create or replace function public.activate_parental_consent(p_request_id uuid, p_withdraw_token_hash text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  request public.parental_consent_requests;
  ended text;
  other uuid;
  kid uuid;
  active uuid;
begin
  -- One activation per kid at a time, so two parents' activations serialize instead of deadlocking.
  select member_id into kid from public.parental_consent_requests where id = p_request_id;
  if kid is null then return 'expired'; end if;
  perform pg_advisory_xact_lock(hashtextextended('parental_consent:' || kid::text, 0));
  select * into request from public.parental_consent_requests where id = p_request_id for update;
  if not found then return 'expired'; end if;
  -- Another parent's activation cancels this request in the same transaction, so report what it came to.
  if request.status <> 'consented' then
    return coalesce(public.parental_consent_settled(request), 'expired');
  end if;
  -- The link may lapse while email 2 is on its way; the parent agreed in time.
  if request.expires_at < now() then
    update public.parental_consent_requests set expires_at = now() + interval '1 minute' where id = request.id
    returning * into request;
  end if;
  ended := public.parental_consent_still_valid(request);
  if ended is not null then return ended; end if;

  select id into active from public.consents
   where member_id = request.member_id and kind = 'parental' and revoked_at is null;
  if active is null then
    insert into public.consents (household_id, member_id, kind, granted_by, granted_at, text_version, method,
                                 confirmed_at, request_id)
    values (request.household_id, request.member_id, 'parental', request.requested_by, request.decided_at,
            request.text_version, 'email_plus', now(), request.id)
    on conflict do nothing
    returning id into active;
  end if;
  if active is not null then
    insert into public.consent_agreements (household_id, agreed_by, agreed_at, text_version, kind, member_id,
                                           consent_id, method, request_id)
    values (request.household_id, request.requested_by, request.decided_at, request.text_version, 'parental',
            request.member_id, active, 'email_plus', request.id)
    on conflict do nothing;
  end if;
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
  if public.has_current_parental_consent(request.member_id) then
    perform public.release_agreement_hold(h.id, 'renewed')
       from public.agreement_holds h
      where h.member_id = request.member_id and h.kind = 'parental' and h.released_at is null;
  end if;
  return 'confirmed';
end;
$$;

-- As email_plus_consent's, for the consent the request gave or renewed.
create or replace function public.parental_consent_withdraw_lookup(p_token_hash text)
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
  if not exists (select 1 from public.consents
                  where id = public.consent_for_request(request.id) and revoked_at is null) then
    return jsonb_build_object('outcome', 'withdrawn');
  end if;
  return jsonb_build_object('outcome', 'active',
                            'first_name', (select first_name from public.members where id = request.member_id));
end;
$$;

create or replace function public.withdraw_parental_consent(p_token_hash text)
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
  update public.consents set revoked_at = now()
   where id = public.consent_for_request(request.id) and revoked_at is null;
  return 'withdrawn';
end;
$$;

-- Renewal emails (service role) ---------------------------------------------------------------------------------------------

-- Who a held kid's hold still owes an email in its current round, and whether that round is the reminder. Round one
-- starts when the hold opens and stays open a day after its first send, to retry a failed send or reach a parent who
-- was over the overall cap; the reminder opens 7 days after the first send, for a day. Every parent with a verified
-- account email; a parent with none is told in the app only. Not a parent whose renewal link was just sent or is being
-- sent, or who already agreed and waits for the confirming email.
create function public.consent_renewal_recipients(target public.agreement_holds)
returns table (account uuid, address text, reminder boolean)
language sql stable security definer set search_path = ''
as $$
  with this_round as (
    select coalesce(target.emailed_at < now() - interval '7 days', false) as reminder,
           case when target.emailed_at < now() - interval '7 days' then target.emailed_at + interval '7 days'
                else target.held_at end as starts
     where target.kind = 'parental' and target.released_at is null
       and (target.emailed_at is null or target.emailed_at > now() - interval '1 day'
            or (target.emailed_at < now() - interval '7 days'
                and (target.reminded_at is null or target.reminded_at > now() - interval '1 day')))
  ), parents as (
    select m.user_id as account from public.members m
     where m.household_id = target.household_id and m.guardian and m.status <> 'removed' and m.user_id is not null
    union
    select h.owner from public.households h where h.id = target.household_id and h.owner is not null
  )
  select p.account, public.verified_account_email(p.account), this_round.reminder
    from parents p cross join this_round
   where public.verified_account_email(p.account) is not null
     and not exists (
       select 1 from public.parental_consent_requests r
        where r.member_id = target.member_id and r.requested_by = p.account
          and ((r.hold_id = target.id and r.created_at >= this_round.starts)
               or r.status = 'consented'
               or r.send_reserved_at > now() - interval '5 minutes'
               or r.token_sent_at > now() - interval '10 minutes'));
$$;

revoke execute on function public.consent_renewal_recipients(public.agreement_holds) from public, anon, authenticated;

-- Reserves renewal emails for up to `batch_size` parents and returns them, oldest hold first:
--   [{"request_id", "send_id", "email", "first_name", "reminder", "held_version", "required_version", "summary",
--     "agreed_at"}]
-- For each: email, then parental_consent_mark_sent; or parental_consent_release_send if it didn't go out (the parent
-- is tried again on the next run while the round is open). Only the 200-an-hour overall cap applies; the per-parent
-- and per-household limits are for sends a parent asks for. An older open request from the same parent is cancelled:
-- the new link replaces it.
create function public.claim_consent_renewal_emails(batch_size int)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  hold public.agreement_holds;
  recipient record;
  kid_name text;
  agreed timestamptz;
  new_request uuid;
  new_send bigint;
  stale uuid;
  claimed jsonb := '[]'::jsonb;
begin
  -- The same lock as request_parental_consent, so the overall cap counts both.
  perform pg_advisory_xact_lock(hashtext('request_parental_consent'));
  <<holds>>
  for hold in select * from public.agreement_holds h
               where h.kind = 'parental' and h.released_at is null
               order by h.held_at
               for update skip locked loop
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
      if recipient.reminder then
        update public.agreement_holds set reminded_at = coalesce(reminded_at, now()) where id = hold.id;
      else
        update public.agreement_holds set emailed_at = coalesce(emailed_at, now()) where id = hold.id;
      end if;
      claimed := claimed || jsonb_build_array(jsonb_build_object(
        'request_id', new_request, 'send_id', new_send, 'email', recipient.address, 'first_name', kid_name,
        'reminder', recipient.reminder, 'held_version', hold.held_version,
        'required_version', hold.required_version,
        'summary', (select v.summary from public.agreement_versions v where v.version = hold.required_version),
        'agreed_at', agreed));
    end loop;
  end loop;
  return claimed;
end;
$$;

revoke execute on function public.claim_consent_renewal_emails(int) from public, anon, authenticated;
grant execute on function public.claim_consent_renewal_emails(int) to service_role;

-- Pokes the parental-consent Edge Function's renewal mode when some hold owes an email. Returns whether it did, for
-- tests. Does nothing until Vault has both consent_function_url and consent_cron_secret (as kick_push_sender).
create function public.kick_consent_renewals()
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  function_url text;
  cron_secret text;
begin
  if not exists (
    select 1 from public.agreement_holds h
     where h.kind = 'parental' and h.released_at is null
       and exists (select 1 from public.consent_renewal_recipients(h))
  ) then
    return false;
  end if;

  select decrypted_secret into function_url from vault.decrypted_secrets where name = 'consent_function_url';
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name = 'consent_cron_secret';
  if coalesce(function_url, '') = '' or coalesce(cron_secret, '') = '' then
    return false;
  end if;

  perform net.http_post(
    url := function_url || case when position('?' in function_url) > 0 then '&' else '?' end || 'renewals=1',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-consent-cron-secret', cron_secret),
    timeout_milliseconds := 55000
  );
  return true;
end;
$$;

revoke execute on function public.kick_consent_renewals() from public, anon, authenticated;

select cron.schedule('kick-consent-renewals', '*/15 * * * *', 'select public.kick_consent_renewals()');

-- Deleting and exporting ----------------------------------------------------------------------------------------------------

-- As delete_kid's (20261113000000), plus the kid's agreements, holds and Terms/Privacy record, and a held kid's account:
-- unlinked by the hold, it's still theirs, unless it has since joined a family (then it's someone else's to delete).
create or replace function public.delete_kid(target_member uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  household uuid;
  kid public.members;
  held_account uuid;
  account uuid;
begin
  select household_id into household from public.members where id = target_member;
  if household is null then
    raise exception 'they''re no longer in the family' using errcode = 'P0002';
  end if;
  -- Before the row: a device's reminder write holds this while it takes its own locks, the same order as
  -- delete_account_data and erase_household.
  perform pg_advisory_xact_lock(public.notification_log_lock(household));
  -- Locking the profile makes any write that points at it (a rating, a vote, a swap's plan change) wait for this and then
  -- fail, so nothing new can name them after their rows are gone and block the delete.
  select * into kid from public.members where id = target_member for update;
  if kid.id is null then
    raise exception 'they''re no longer in the family' using errcode = 'P0002';
  end if;
  if not public.is_household_manager(kid.household_id) then
    raise exception 'only a parent in their family deletes a kid' using errcode = '42501';
  end if;
  if kid.age_group <> 'kid' then
    raise exception 'only a kid''s profile is deleted this way' using errcode = '22023';
  end if;
  select h.held_user_id into held_account from public.agreement_holds h
   where h.member_id = kid.id and h.kind = 'parental' and h.released_at is null;

  -- After dinner. Deleting a reaction takes its hidden comment with it (cascade).
  delete from public.reactions where member_id = kid.id;
  update public.reactions set entered_by_member_id = null where entered_by_member_id = kid.id;
  -- Thanks for a dinner they cooked are about them, whoever sent them.
  delete from public.chef_thanks
  where from_member_id = kid.id or meal_log_id in (select id from public.meal_logs where cooked_by_member_id = kid.id);
  update public.meal_logs set cooked_by_member_id = null where cooked_by_member_id = kid.id;
  update public.meal_logs set confirmed_by_member_id = null where confirmed_by_member_id = kid.id;
  update public.meals set made_by_member_id = null where made_by_member_id = kid.id;
  -- A note they wrote about someone else is still their words.
  delete from public.serving_notes where member_id = kid.id or written_by_member_id = kid.id;

  -- Everyone's say.
  delete from public.request_plus_ones
  where member_id = kid.id or request_id in (select id from public.requests where requested_by_member_id = kid.id);
  update public.request_plus_ones set entered_by_member_id = null where entered_by_member_id = kid.id;
  -- Their own words on a request they entered for someone else go too; the request stays that person's.
  update public.requests set entered_by_member_id = null, note = null where entered_by_member_id = kid.id;
  delete from public.requests where requested_by_member_id = kid.id;
  delete from public.night_claims where member_id = kid.id;
  update public.night_claims set entered_by_member_id = null where entered_by_member_id = kid.id;
  delete from public.poll_votes where member_id = kid.id;
  update public.poll_votes set entered_by_member_id = null where entered_by_member_id = kid.id;
  update public.polls set started_by = null where started_by = kid.id;

  -- The week.
  delete from public.night_attendance where member_id = kid.id;
  delete from public.plan_changes where actor_member_id = kid.id;
  update public.attendance_templates set schedules = schedules - kid.id::text
  where household_id = kid.household_id and schedules ? kid.id::text;
  update public.households
  set settings = jsonb_set(settings, '{dinner_jobs,left_out}', (settings -> 'dinner_jobs' -> 'left_out') - kid.id::text)
  where id = kid.household_id and jsonb_typeof(settings -> 'dinner_jobs' -> 'left_out') = 'array'
    and settings -> 'dinner_jobs' -> 'left_out' ? kid.id::text;
  -- Lines stay with the family's list (see above); they just stop naming them.
  update public.list_items set checked_by = null where checked_by = kid.id;
  update public.list_items set urgent_by = null where urgent_by = kid.id;
  delete from public.store_runs where started_by = kid.id;

  -- Reminders. A digest is also a planner's once-a-day mark, so it stays, no longer naming them, as for a withdrawn kid.
  delete from public.notification_log where member_id = kid.id;
  update public.push_outbox set args = args - 'name', about_member_id = null
  where kind = 'new_requests' and about_member_id = kid.id;
  delete from public.push_outbox where member_id = kid.id or about_member_id = kid.id;
  delete from public.push_devices where member_id = kid.id;

  -- Who they are.
  delete from public.member_allergies where member_id = kid.id;
  delete from public.invites where member_id = kid.id;
  -- The parent asked for everything about the kid to go, and the record of consent is about the kid (#278; a Review note
  -- for counsel in retention.md). Agreements and holds first: they point at the consents.
  delete from public.agreement_holds where member_id = kid.id;
  delete from public.consent_agreements where member_id = kid.id;
  delete from public.consents where member_id = kid.id;
  delete from public.members where id = kid.id;

  -- Their sign-in. Sessions end with it, so the kid's phone loses access on its next request. An account on a kid's
  -- profile is taken to be the kid's: one account joins one household, and claiming a kid's invite is choosing to be
  -- that kid. One claimed by someone who said they're an adult (only possible before redeem_invite refused it) is only
  -- unlinked: fail closed on an account. A held kid's account counts while it hasn't joined a family since.
  account := kid.user_id;
  if account is null and held_account is not null
     and not exists (select 1 from public.members where user_id = held_account) then
    account := held_account;
  end if;
  if account is not null and kid.declared_age_band is distinct from 'adult' then
    delete from public.invite_redeem_attempts where user_id = account;
    delete from public.account_agreements where user_id = account;
    delete from auth.users where id = account;
  end if;
end;
$$;

-- As entitlement's (20261107000000), plus the household's holds, before the consents they point at.
create or replace function public.erase_household(target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- Before any row: a device's write holds this while it takes its own locks, so one in flight finishes first, and a later one
  -- waits and is then refused.
  perform pg_advisory_xact_lock(public.notification_log_lock(target));
  -- Holds the nights first, so a Swap in flight can't log a new entry after the log's been emptied and fail the erase.
  perform 1 from public.plan_nights where household_id = target for update;
  delete from public.subscription_events where household_id = target;
  delete from public.household_subscriptions where household_id = target;
  delete from public.ai_jobs where household_id = target;
  delete from public.poll_votes where household_id = target;
  delete from public.polls where household_id = target;
  delete from public.notification_log where household_id = target;
  delete from public.plan_changes where household_id = target;
  delete from public.night_claims where household_id = target;
  delete from public.attendance_templates where household_id = target;
  delete from public.request_plus_ones where household_id = target;
  delete from public.requests where household_id = target;
  delete from public.serving_notes where household_id = target;
  delete from public.chef_thanks where household_id = target;
  delete from public.reactions where household_id = target;
  delete from public.meal_logs where household_id = target;
  delete from public.night_attendance where household_id = target;
  delete from public.list_items where household_id = target;
  delete from public.plan_nights where household_id = target;
  delete from public.freezer_stash where household_id = target;
  delete from public.plans where household_id = target;
  delete from public.traditions where household_id = target;
  delete from public.meal_sides where household_id = target;
  delete from public.meal_ingredients where household_id = target;
  delete from public.meals where household_id = target;
  delete from public.items where household_id = target;
  delete from public.member_allergies where household_id = target;
  delete from public.invites where household_id = target;
  delete from public.agreement_holds where household_id = target;
  delete from public.consent_agreements where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;

-- As email_plus_consent's (20261116000000), plus the holds (never the kid's account or the email bookkeeping) and why
-- each consent request was sent.
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
                from public.ai_jobs j where household_id = target_household)
  );
end;
$$;
