-- The day-of check-in (#41): "Home tonight?", from each person's phone, with no answer meaning home.
--
-- Planners own attendance, and this is the one way round that: anyone can say for themselves (or, passing the phone, for a
-- profile nobody has claimed) whether they'll be home tonight, and only tonight. It goes through answer_check_in, so the
-- column grants on night_attendance stay as they are and checked_in_at can't be written directly.
--
-- checked_in_at says the person answered, and `expected` holds what they said, so "said they won't be home" is
-- expected = false with checked_in_at set. That's what a planner's note on This Week reads, and server push can read the
-- same rows later. Any other change to `expected` clears it, since the row no longer says what they said.

alter table public.night_attendance add column checked_in_at timestamptz;

create function public.night_attendance_clear_check_in()
returns trigger
language plpgsql
as $$
begin
  if new.expected is distinct from old.expected and new.checked_in_at is not distinct from old.checked_in_at then
    new.checked_in_at := null;
  end if;
  return new;
end;
$$;

revoke execute on function public.night_attendance_clear_check_in() from public, anon, authenticated;

create trigger night_attendance_clear_check_in before update of expected on public.night_attendance
  for each row execute function public.night_attendance_clear_check_in();

create function public.answer_check_in(target_night uuid, target_member uuid, home boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
  held public.night_attendance;
begin
  select * into night from public.plan_nights where id = target_night;
  if night.id is null or not public.is_household_member(night.household_id) then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if not public.may_react_for(target_member)
     or not exists (select 1 from public.members where id = target_member and household_id = night.household_id) then
    raise exception 'people say for themselves (or for a profile nobody has claimed)' using errcode = '42501';
  end if;
  if night.date <> public.household_today(night.household_id) then
    raise exception 'the check-in is only for tonight' using errcode = '22023';
  end if;

  select * into held from public.night_attendance where plan_night_id = night.id and member_id = target_member for update;
  -- A planner has them out, and they didn't say so themselves: that's the planner's to change. Someone who said not home
  -- can change their mind.
  if home and held.id is not null and not held.expected and held.checked_in_at is null then
    raise exception 'a planner has them out tonight' using errcode = 'FD016';
  end if;

  insert into public.night_attendance (household_id, plan_night_id, member_id, expected, checked_in_at)
  values (night.household_id, night.id, target_member, home, clock_timestamp())
  on conflict (plan_night_id, member_id) do update set expected = excluded.expected, checked_in_at = excluded.checked_in_at;

  -- As with "Wasn't home": someone who isn't there didn't cook it, unless they've already been thanked. A late tap can land
  -- after the dinner's logged. A claim isn't touched: it goes on hold while they're out and stands again if they come back.
  if not home then
    update public.meal_logs l set cooked_by_member_id = null
    where l.night_id = night.id and l.cooked_by_member_id = target_member
      and not exists (select 1 from public.chef_thanks t where t.meal_log_id = l.id);
  end if;
end;
$$;

revoke execute on function public.answer_check_in(uuid, uuid, boolean) from public, anon;
grant execute on function public.answer_check_in(uuid, uuid, boolean) to authenticated;
