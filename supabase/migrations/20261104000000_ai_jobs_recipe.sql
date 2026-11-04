-- The first real AI job kind (#59): `recipe` structures text captured from a photo, a PDF or a social post's caption into a
-- name, ingredients, steps and prep steps. Its payload is that text and the source link, nothing about the family.
-- The captured text is only needed until a device has run the job, so a job's payload is emptied ('{}') once it's done,
-- failed or expired: What Foon keeps says the recipe text is held briefly for a family device to process. The result (the
-- tidied recipe) stays until finished jobs are pruned 30 days on, by which time the meal has its own copy.

alter table public.ai_jobs drop constraint ai_jobs_kind_check;
alter table public.ai_jobs add constraint ai_jobs_kind_check check (kind in ('echo', 'recipe'));

-- As in 20261103210000, with the payload emptied on every step that ends a job.
create or replace function public.ai_jobs_guard()
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
    new.payload := '{}';
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
    new.payload := '{}';
    return new;
  end if;

  raise exception 'not a step a job can take' using errcode = '22023';
end;
$$;

revoke execute on function public.ai_jobs_guard() from public, anon, authenticated;

-- Jobs already finished on staging (echo only) lose their payloads too. The guard allows no such step, so it's off for this.
alter table public.ai_jobs disable trigger ai_jobs_guard;
update public.ai_jobs set payload = '{}' where status in ('done', 'failed', 'expired') and payload <> '{}';
alter table public.ai_jobs enable trigger ai_jobs_guard;
