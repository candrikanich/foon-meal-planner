-- Reactions feed planning and the library (#42, part 3).
-- 1. meal_history counts dinners as logged (confirmed or saved overnight), and approved-plan nights only where no
--    log exists (before logs, or until the overnight job catches up).
-- 2. meal_verdicts: each member's current verdict on each dish, their latest reaction to it. Visible to the family.
--    Removed members' verdicts don't count: they're never home, and they don't get half a vote to retire a dish.
-- 3. meal_likes: how often anyone rated a dish favorite or good, ever.
-- 4. The dislike rule's lasting half: once two people's current verdict on a dish is not_for_me, it's retired
--    (archived for good, still findable). The one-person half (skip nights they're home) is in Build my week.

create or replace view public.meal_history
with (security_invoker = true)
as
  select household_id, meal_id, count(*)::int as times_made, max(date) as last_made
  from (
    select l.household_id, l.meal_id, n.date
    from public.meal_logs l
    join public.plan_nights n on n.id = l.night_id
    where l.meal_id is not null
    union all
    select n.household_id, n.meal_id, n.date
    from public.plan_nights n
    join public.plans p on p.id = n.plan_id and p.household_id = n.household_id
    where n.meal_id is not null and p.approved_at is not null and n.date < current_date
      and not exists (select 1 from public.meal_logs l where l.night_id = n.id)
  ) eaten
  group by household_id, meal_id;

-- household_id leads the distinct on, so a household filter reaches the base tables (and their indexes).
create view public.meal_verdicts
with (security_invoker = true)
as
  select distinct on (r.household_id, r.member_id, l.meal_id)
         r.household_id, l.meal_id, r.member_id, r.reaction, n.date as reacted_on
  from public.reactions r
  join public.meal_logs l on l.id = r.meal_log_id
  join public.plan_nights n on n.id = l.night_id
  join public.members m on m.id = r.member_id
  where l.meal_id is not null and m.status <> 'removed'
  order by r.household_id, r.member_id, l.meal_id, n.date desc, r.updated_at desc;

create view public.meal_likes
with (security_invoker = true)
as
  select r.household_id, l.meal_id, count(*)::int as likes
  from public.reactions r
  join public.meal_logs l on l.id = r.meal_log_id
  where l.meal_id is not null and r.reaction in ('favorite', 'good')
  group by r.household_id, l.meal_id;

revoke all on public.meal_verdicts, public.meal_likes from anon, authenticated;
grant select on public.meal_verdicts, public.meal_likes to authenticated;

-- Two lasting dislikes retire the dish. Runs as the owner: members can't change a meal's status themselves.
create function public.reactions_retire_disliked()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  dish uuid;
begin
  select meal_id into dish from public.meal_logs where id = new.meal_log_id;
  if dish is null or new.reaction <> 'not_for_me' then
    return null;
  end if;
  -- Two people answering at the same moment take turns here, so both dislikes are counted.
  perform 1 from public.meals where id = dish for update;
  if (select count(*) from public.meal_verdicts v where v.meal_id = dish and v.reaction = 'not_for_me') >= 2 then
    update public.meals set status = 'retired' where id = dish and status <> 'retired';
  end if;
  return null;
end;
$$;

create trigger reactions_retire_disliked after insert or update of reaction on public.reactions
  for each row execute function public.reactions_retire_disliked();

-- New ratings are for the last week's dinners (part 1's guard, re-created with that reach), so nobody can retire a
-- dish by rating a dinner from months ago.
create or replace function public.reactions_guard()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if old.created_at < now() - interval '24 hours' then
      raise exception 'reactions lock after 24 hours' using errcode = '42501';
    end if;
    -- The last writer, so a rating a parent entered and a kid later changed counts as the kid's.
    new.entered_by_member_id := public.my_member_id(new.household_id);
    return new;
  end if;
  if not public.is_household_member(new.household_id) then
    raise exception 'not your household' using errcode = '42501';
  end if;
  -- The card's reach: a new rating is for a dinner in the last week, not one from months ago.
  if (select n.date from public.meal_logs l join public.plan_nights n on n.id = l.night_id where l.id = new.meal_log_id)
     < public.household_today(new.household_id) - 7 then
    raise exception 'that dinner was too long ago to rate' using errcode = '22023';
  end if;
  if (select meal_id from public.meal_logs where id = new.meal_log_id) is null then
    raise exception 'only dishes are rated, not quick picks' using errcode = '22023';
  end if;
  new.entered_by_member_id := public.my_member_id(new.household_id);
  return new;
end;
$$;

