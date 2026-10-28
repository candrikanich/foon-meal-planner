-- Account deletion and household export (#29).
--
-- delete_account_data(target_user) is what deleting an account does to the database. Only the delete-account
-- Edge Function calls it (service role), after revoking the Sign in with Apple token and removing the household's
-- photos, and before it deletes the auth user.
--   * The owner: the household and everything in it are erased. This is the one exception to "never hard-delete"
--     (docs/spec.md, Retention). Everyone else in it keeps their account and can start or join another household.
--   * An adult: their profile is removed and anonymized now, so their ratings and cook history stay as anonymous
--     history.
--   * A kid: their own account is unlinked; the profile their parent entered stays with the family.
-- Returns 'household_deleted', 'profile_anonymized', 'unlinked', or 'no_household'.
--
-- export_household(target_household) returns the household's data as JSON for planners. It leaves out account
-- ids, invite codes, and redeem attempts.

create function public.delete_account_data(target_user uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  owned uuid;
  profile public.members;
begin
  -- Rate-limit bookkeeping keyed by the account; nothing to keep once it's gone.
  delete from public.invite_redeem_attempts where user_id = target_user;

  select id into owned from public.households where owner = target_user;
  if owned is not null then
    delete from public.night_attendance where household_id = owned;
    delete from public.list_items where household_id = owned;
    delete from public.plan_nights where household_id = owned;
    delete from public.plans where household_id = owned;
    delete from public.traditions where household_id = owned;
    delete from public.meal_sides where household_id = owned;
    delete from public.meal_ingredients where household_id = owned;
    delete from public.meals where household_id = owned;
    delete from public.items where household_id = owned;
    delete from public.member_allergies where household_id = owned;
    delete from public.invites where household_id = owned;
    delete from public.consents where household_id = owned;
    delete from public.members where household_id = owned;
    delete from public.households where id = owned;
    return 'household_deleted';
  end if;

  select * into profile from public.members where user_id = target_user;
  if profile.id is null then
    return 'no_household';
  end if;

  if profile.age_group = 'kid' then
    update public.members set user_id = null, declared_age_band = null where id = profile.id;
    return 'unlinked';
  end if;

  delete from public.member_allergies where member_id = profile.id;
  update public.members
  set status = 'removed', removed_at = now(), first_name = 'Former member', avatar = null,
      attendance_defaults = '{}', notification_prefs = '{}', declared_age_band = null, anonymized_at = now()
  where id = profile.id;
  return 'profile_anonymized';
end;
$$;

revoke execute on function public.delete_account_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_account_data(uuid) to service_role;

create function public.export_household(target_household uuid)
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
                   from public.list_items l where household_id = target_household)
  );
end;
$$;

revoke execute on function public.export_household(uuid) from public, anon;
grant execute on function public.export_household(uuid) to authenticated;
