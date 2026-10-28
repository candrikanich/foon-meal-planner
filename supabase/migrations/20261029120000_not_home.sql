-- "Wasn't home" on the after-dinner card (#42, part 2). Attendance is otherwise a planner's to set; this lets someone
-- say they weren't home on a night that's happened, for themselves or (passing the phone) for a profile nobody has
-- claimed, within the last week. Security definer, with the same who-may-react rule as reactions.
create function public.set_not_home(target_night uuid, target_member uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  night public.plan_nights;
begin
  select * into night from public.plan_nights where id = target_night;
  if night.id is null or not public.is_household_member(night.household_id) then
    raise exception 'no night %', target_night using errcode = 'P0002';
  end if;
  if not public.may_react_for(target_member)
     or not exists (select 1 from public.members where id = target_member and household_id = night.household_id) then
    raise exception 'people say for themselves (or for a profile nobody has claimed)' using errcode = '42501';
  end if;
  if night.date > public.household_today(night.household_id) then
    raise exception 'that dinner hasn''t happened yet' using errcode = '22023';
  end if;
  -- The after-dinner card's reach, like the overnight job: older attendance is history.
  if night.date < public.household_today(night.household_id) - 7 then
    raise exception 'that dinner was too long ago' using errcode = '22023';
  end if;
  insert into public.night_attendance (household_id, plan_night_id, member_id, expected)
  values (night.household_id, night.id, target_member, false)
  on conflict (plan_night_id, member_id) do update set expected = false;
end;
$$;

revoke execute on function public.set_not_home(uuid, uuid) from public, anon;
grant execute on function public.set_not_home(uuid, uuid) to authenticated;

-- "We had something else" is for before anyone rates: once someone has, their rating stays with the dish they rated.
-- (Part 1's guard, re-created with that rule.)
create or replace function public.meal_logs_guard()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  night public.plan_nights;
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    select * into night from public.plan_nights where id = new.night_id;
    if night.date > public.household_today(new.household_id) then
      raise exception 'that dinner hasn''t happened yet' using errcode = '22023';
    end if;
    if night.meal_id is null and night.quick_pick is null then
      raise exception 'nothing was planned that night; swap in what you had first' using errcode = '22023';
    end if;
    new.verified := true;
    new.confirmed_by_member_id := public.my_member_id(new.household_id);
    return new;
  end if;
  if old.verified and not new.verified then
    raise exception 'a confirmed dinner stays confirmed' using errcode = '42501';
  end if;
  if (new.meal_id, new.quick_pick) is distinct from (old.meal_id, old.quick_pick)
     and exists (select 1 from public.reactions where meal_log_id = old.id) then
    raise exception 'someone already rated this dinner' using errcode = '42501';
  end if;
  new.confirmed_by_member_id := case when not old.verified and new.verified
                                     then public.my_member_id(new.household_id)
                                     else old.confirmed_by_member_id end;
  return new;
end;
$$;
