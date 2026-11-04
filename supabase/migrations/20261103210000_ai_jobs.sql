-- The household AI queue (#58). AI is a household resource: a phone that can't run Apple's on-device model submits a job, and
-- a capable device in the family claims it (right away if it submitted it, otherwise on app open, and in a background refresh
-- on iPhone), runs it on that device, and writes the result here for everyone. The non-AI result is already showing, so a job
-- nobody claims in time just expires and leaves it.
-- Payloads never hold allergy data: the app builds each kind's payload from fields that can't carry it (see AIJobRequest).
-- Members read their household's jobs, submit their own, and work them only through claim_ai_job, complete_ai_job and
-- fail_ai_job. Those run as the caller (security invoker), so RLS still scopes them; the guard trigger holds the rules for
-- any update, however it arrives:
-- * a claim takes a queued job, or a claimed one whose lease has lapsed, and never an expired one;
-- * only the member holding the claim completes or fails it;
-- * a job that's done, failed or expired stays that way.
-- Defaults: a claim's lease is 5 minutes (a model run takes seconds, and iOS ends a background refresh well before 5
-- minutes, after which another device can take it). A job expires 3 days after it's submitted. Finished jobs are pruned 30
-- days on: by then whatever used the result has its own copy.

create table public.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  -- One kind per job the app knows how to run. `echo` hands back its payload without the model: it lets the queue be
  -- checked end to end before the first real kind (#59) ships. No feature submits it.
  kind text not null check (kind in ('echo')),
  -- About a 4K-token model context's worth of text, with room for the JSON around it.
  payload jsonb not null check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 32768),
  status text not null default 'queued' check (status in ('queued', 'claimed', 'done', 'failed', 'expired')),
  -- Set null, not cascade: a job outlives nobody, and it's pruned anyway.
  created_by uuid references public.members (id) on delete set null,
  claimed_by uuid references public.members (id) on delete set null,
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  result jsonb check (result is null or (jsonb_typeof(result) = 'object' and octet_length(result::text) <= 32768)),
  error text check (error is null or char_length(error) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '3 days',
  constraint ai_jobs_claimed_has_lease check (status <> 'claimed' or (claimed_at is not null and lease_expires_at is not null)),
  constraint ai_jobs_done_has_result check (status <> 'done' or result is not null)
);

create index ai_jobs_open_idx on public.ai_jobs (household_id, created_at) where status in ('queued', 'claimed');
create index ai_jobs_created_by_idx on public.ai_jobs (created_by);
create index ai_jobs_claimed_by_idx on public.ai_jobs (claimed_by);

create trigger ai_jobs_set_updated_at before update on public.ai_jobs
  for each row execute function public.set_updated_at();

revoke all on public.ai_jobs from anon, authenticated;
grant select on public.ai_jobs to authenticated;
grant insert (household_id, kind, payload, created_by) on public.ai_jobs to authenticated;
-- The claim, complete and fail functions run as the caller, so the caller needs these; the guard trigger decides what's allowed.
grant update (status, claimed_by, result, error) on public.ai_jobs to authenticated;

alter table public.ai_jobs enable row level security;

create policy "members read ai jobs" on public.ai_jobs
  for select to authenticated using (public.is_household_member(household_id));
create policy "members submit ai jobs" on public.ai_jobs
  for insert to authenticated
  with check (public.is_household_member(household_id) and created_by = public.my_member_id(household_id));
create policy "members work ai jobs" on public.ai_jobs
  for update to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

-- Every update goes through here. The server's own (the hourly expiry, a profile being deleted) may expire a job, or clear
-- who submitted or claimed one, and nothing else.
create function public.ai_jobs_guard()
returns trigger
language plpgsql security invoker set search_path = ''
as $$
declare
  me uuid := public.my_member_id(old.household_id);
begin
  -- A profile's deletion setting who submitted or claimed it to null arrives here from the foreign key's own trigger,
  -- whatever state the job is in, so it's let through before the steps below.
  if pg_trigger_depth() > 1 and new.status = old.status and new.result is not distinct from old.result
     and new.error is not distinct from old.error and new.payload is not distinct from old.payload then
    return new;
  end if;

  if new.status = 'expired' then
    if new.result is distinct from old.result or new.error is distinct from old.error
       or new.claimed_by is distinct from old.claimed_by then
      raise exception 'expiring a job changes nothing else' using errcode = '22023';
    end if;
    if old.status not in ('queued', 'claimed') or now() < old.expires_at then
      raise exception 'only an open job past its time expires' using errcode = '22023';
    end if;
    return new;
  end if;

  if new.status = 'claimed' then
    if me is null or new.claimed_by is distinct from me then
      raise exception 'a job is claimed by the member claiming it' using errcode = '42501';
    end if;
    if now() >= old.expires_at then
      raise exception 'this job has expired' using errcode = '22023';
    end if;
    if not (old.status = 'queued' or (old.status = 'claimed' and old.lease_expires_at <= now())) then
      raise exception 'this job is already claimed' using errcode = '55P03';
    end if;
    new.claimed_at := now();
    new.lease_expires_at := now() + interval '5 minutes';
    new.result := null;
    new.error := null;
    return new;
  end if;

  if new.status in ('done', 'failed') then
    if old.status <> 'claimed' or me is null or old.claimed_by is distinct from me
       or new.claimed_by is distinct from old.claimed_by then
      raise exception 'only the member holding the claim finishes a job' using errcode = '42501';
    end if;
    if new.status = 'failed' then
      new.result := null;
    else
      new.error := null;
    end if;
    return new;
  end if;

  raise exception 'not a step a job can take' using errcode = '22023';
end;
$$;

revoke execute on function public.ai_jobs_guard() from public, anon, authenticated;

create trigger ai_jobs_guard before update on public.ai_jobs
  for each row execute function public.ai_jobs_guard();

-- Submits a job as the caller. Runs under their RLS, like a direct insert.
create function public.submit_ai_job(target_household uuid, job_kind text, job_payload jsonb)
returns public.ai_jobs
language sql security invoker set search_path = ''
as $$
  insert into public.ai_jobs (household_id, kind, payload, created_by)
  values (target_household, job_kind, job_payload, public.my_member_id(target_household))
  returning *;
$$;

revoke execute on function public.submit_ai_job(uuid, text, jsonb) from public, anon;
grant execute on function public.submit_ai_job(uuid, text, jsonb) to authenticated;

-- Claims the oldest job of these kinds in the caller's household (RLS scopes it), or the one asked for. A device names only the
-- kinds it can run, so an older app never takes a job it doesn't know. `skip locked`: two devices claiming at once get
-- different jobs, never the same one. Empty when there's nothing to claim.
create function public.claim_ai_job(job_kinds text[], only_job uuid default null)
returns setof public.ai_jobs
language plpgsql security invoker set search_path = ''
as $$
declare
  picked public.ai_jobs;
begin
  select * into picked from public.ai_jobs j
  where j.kind = any (job_kinds)
    and (only_job is null or j.id = only_job)
    and j.expires_at > now()
    and (j.status = 'queued' or (j.status = 'claimed' and j.lease_expires_at <= now()))
  order by j.created_at
  limit 1
  for update skip locked;
  if picked.id is null then
    return;
  end if;

  update public.ai_jobs set status = 'claimed', claimed_by = public.my_member_id(picked.household_id)
  where id = picked.id
  returning * into picked;
  return next picked;
end;
$$;

revoke execute on function public.claim_ai_job(text[], uuid) from public, anon;
grant execute on function public.claim_ai_job(text[], uuid) to authenticated;

create function public.complete_ai_job(job uuid, job_result jsonb)
returns public.ai_jobs
language plpgsql security invoker set search_path = ''
as $$
declare
  finished public.ai_jobs;
begin
  update public.ai_jobs set status = 'done', result = job_result where id = job returning * into finished;
  if finished.id is null then
    raise exception 'no such job' using errcode = '42501';
  end if;
  return finished;
end;
$$;

revoke execute on function public.complete_ai_job(uuid, jsonb) from public, anon;
grant execute on function public.complete_ai_job(uuid, jsonb) to authenticated;

-- A failed job leaves the non-AI result showing, the same as one that expires.
create function public.fail_ai_job(job uuid, reason text)
returns public.ai_jobs
language plpgsql security invoker set search_path = ''
as $$
declare
  finished public.ai_jobs;
begin
  update public.ai_jobs set status = 'failed', error = left(coalesce(reason, ''), 500) where id = job
  returning * into finished;
  if finished.id is null then
    raise exception 'no such job' using errcode = '42501';
  end if;
  return finished;
end;
$$;

revoke execute on function public.fail_ai_job(uuid, text) from public, anon;
grant execute on function public.fail_ai_job(uuid, text) to authenticated;

-- Hourly: open jobs past their time expire, and finished ones go 30 days on.
create function public.expire_ai_jobs()
returns void
language sql security definer set search_path = ''
as $$
  update public.ai_jobs set status = 'expired' where status in ('queued', 'claimed') and expires_at <= now();
  delete from public.ai_jobs where status in ('done', 'failed', 'expired') and updated_at < now() - interval '30 days';
$$;

revoke execute on function public.expire_ai_jobs() from public, anon, authenticated;

select cron.schedule('expire-ai-jobs', '41 * * * *', 'select public.expire_ai_jobs()');

-- Delete household erases the household's jobs with everything else.
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
  delete from public.consent_agreements where household_id = target;
  delete from public.consents where household_id = target;
  delete from public.members where household_id = target;
  delete from public.households where id = target;
end;
$$;

-- The export holds what "What Foon keeps" lists, and that now includes the household's AI jobs.
create or replace function public.export_household(target_household uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
begin
  if not public.is_household_planner(target_household) then
    raise exception 'only planners export the household' using errcode = '42501';
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
