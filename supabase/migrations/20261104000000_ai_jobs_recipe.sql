-- The first real AI job kind (#59): `recipe` structures the recipe lines read from a photo, a PDF or a social post's caption
-- into a name, ingredients, steps and prep steps. Only a device that can't run Apple's on-device model queues one, and only
-- when a planner saves the dish. Its payload is those lines and the source link, nothing about the family.
-- A recipe job's result goes into a dish, so only a planner's device claims, completes or fails one: a member's or a kid's
-- device can't write a result that a planner's phone then saves into a meal.
-- The captured text is only needed until a device has run the job, so a job's payload is emptied ('{}') once it's done,
-- failed or expired: What Foon keeps says the recipe text is held briefly for a family device to process. The result (the
-- tidied recipe) stays until finished jobs are pruned 30 days on, by which time the meal has its own copy.

alter table public.ai_jobs drop constraint ai_jobs_kind_check;
alter table public.ai_jobs add constraint ai_jobs_kind_check check (kind in ('echo', 'recipe'));

-- As in 20261103210000, with the payload emptied on every step that ends a job, and recipe jobs worked by planners only.
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

  if new.status in ('claimed', 'done', 'failed') and old.kind = 'recipe'
     and not public.is_household_planner(old.household_id) then
    raise exception 'only a planner''s device works a recipe job' using errcode = '42501';
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

-- As in 20261103210000, skipping recipe jobs for a caller who isn't a planner, so their device takes the next job it may run
-- rather than failing on one it may not.
create or replace function public.claim_ai_job(job_kinds text[], only_job uuid default null)
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
    and (j.kind <> 'recipe' or public.is_household_planner(j.household_id))
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

-- An AI result is put into a dish only if nobody has saved the dish since the device read it (#59): an edit made in between
-- wins, and the device reads it again. save_meal itself is unchanged; this holds the meal's row while it checks, then calls
-- it, all in one transaction. 40001 means it changed; P0002, it's gone; save_meal's own checks (planners only) still apply.
create function public.save_meal_if_unchanged(
  target_meal uuid,
  expected_updated_at timestamptz,
  meal_name text,
  meal_servings smallint,
  meal_tags public.meal_tag[],
  meal_steps text[],
  meal_source_url text,
  made_by uuid,
  lines jsonb,
  sides jsonb default null,
  meal_cook_minutes smallint default null,
  meal_prep_steps jsonb default null
)
returns public.meals
language plpgsql security invoker set search_path = ''
as $$
declare
  current_version timestamptz;
begin
  -- Gone (P0002) or not a planner (42501) before the lock, which row-level security would otherwise turn into "not found".
  perform public.planner_meal_household(target_meal);
  select m.updated_at into current_version from public.meals m where m.id = target_meal for update;
  if not found then
    raise exception 'no such meal' using errcode = 'P0002';
  end if;
  if current_version is distinct from expected_updated_at then
    raise exception 'the meal changed since it was read' using errcode = '40001';
  end if;
  return public.save_meal(target_meal, meal_name, meal_servings, meal_tags, meal_steps, meal_source_url, made_by, lines,
                          sides, meal_cook_minutes, meal_prep_steps);
end;
$$;

revoke execute on function public.save_meal_if_unchanged(uuid, timestamptz, text, smallint, public.meal_tag[], text[], text,
  uuid, jsonb, jsonb, smallint, jsonb) from public, anon;
grant execute on function public.save_meal_if_unchanged(uuid, timestamptz, text, smallint, public.meal_tag[], text[], text,
  uuid, jsonb, jsonb, smallint, jsonb) to authenticated;
