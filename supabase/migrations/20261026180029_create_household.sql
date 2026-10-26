-- create_household (#8): the household and its owner's profile in one transaction, so a failure
-- can't leave a household without the owner's profile. Runs as the caller under the existing RLS:
-- the insert policy enforces one household per person, and the member guard makes the owner's
-- own profile a guardian.

create function public.create_household(household_name text, household_emoji text, owner_first_name text)
returns public.households
language plpgsql security invoker set search_path = ''
as $$
declare
  created public.households;
begin
  insert into public.households (name, emoji)
  values (btrim(household_name), nullif(btrim(household_emoji), ''))
  returning * into created;

  insert into public.members (household_id, first_name, role, user_id)
  values (created.id, btrim(owner_first_name), 'planner', (select auth.uid()));

  return created;
end;
$$;

revoke execute on function public.create_household(text, text, text) from public, anon;
grant execute on function public.create_household(text, text, text) to authenticated;
