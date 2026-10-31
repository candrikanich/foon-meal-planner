-- Each night keeps its own dinner time from when its week was made, so changing the household's did nothing to weeks already
-- started: reminders and "Start cooking at" stayed on the old time (#170). A change now moves tonight and every later night.
-- Past nights keep theirs, since their prompts and logs already used it. No screen sets one night's time yet; if one is added,
-- this needs a way to tell a night set by hand. A trigger, so every path that saves settings gets it.
create function public.households_move_dinner_time()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.settings ->> 'dinner_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    update public.plan_nights
    set dinner_time = (new.settings ->> 'dinner_time')::time
    where household_id = new.id and date >= public.household_today(new.id);
  end if;
  return null;
end;
$$;
revoke execute on function public.households_move_dinner_time() from public, anon, authenticated;

create trigger households_move_dinner_time
  after update of settings on public.households
  for each row
  when (new.settings ->> 'dinner_time' is distinct from old.settings ->> 'dinner_time')
  execute function public.households_move_dinner_time();

-- Households that changed it before this existed: their nights ahead catch up once.
update public.plan_nights n
set dinner_time = (h.settings ->> 'dinner_time')::time
from public.households h
where n.household_id = h.id
  and h.settings ->> 'dinner_time' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  and n.date >= public.household_today(h.id)
  and n.dinner_time is distinct from (h.settings ->> 'dinner_time')::time;
